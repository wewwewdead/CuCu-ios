import Foundation

/// Strips personal content from a `ProfileDocument` while preserving
/// the design — colors, fonts, layout, container structure, decorative
/// styling. Used by the "Use this style" growth loop on
/// `PublishedProfileView`: a remix of someone else's profile must
/// land in the new owner's editor empty of identity, ready to fill in.
///
/// **Personal vs decorative.** The split is conservative:
/// - **Personal** (cleared): the system-owned hero text + avatar,
///   every image's local/remote path, every link's URL/label, every
///   gallery's photo list, every note's body. This is anything a
///   visitor can identify as belonging to the original author.
/// - **Decorative** (kept): page background hex / blur / vignette /
///   pattern key, container backgrounds, every node's geometry, every
///   font/color/border token, divider styles, icon styles.
///
/// **Image paths.** Published documents have remote URLs (rewritten by
/// `PublishedDocumentTransformer` at publish time). Remix clears every
/// image-bearing field rather than copying those URLs into the new
/// local draft — copying a remote URL into a draft would let the
/// remixer's published profile inadvertently reference the original
/// author's CDN content, which is the kind of cross-account leak the
/// product safety contract avoids.
///
/// **Container backgrounds.** Same rule. A container with a photo
/// background is treated as personal. A container with only a
/// hex / gradient / pattern is treated as decorative — those stay.
///
/// The transformer is pure and synchronous; it never reads the network
/// and never touches `LocalCanvasAssetStore`. Output is a fresh
/// `ProfileDocument` with new top-level UUID; node UUIDs are
/// preserved so the structured-profile invariants (system roles,
/// child ordering) still hold.
enum RemixTransformer {
    /// Build a remix-ready local draft document from a published one.
    /// Caller is responsible for inserting it into a fresh
    /// `ProfileDraft` and routing the user to the editor.
    static func remix(from source: ProfileDocument) -> ProfileDocument {
        var copy = source
        copy.id = UUID()
        copy.heroAvatarURL = nil

        // Page-level chrome. Hex / blur / vignette / pattern are
        // decorative tokens — keep them so the page reads the same on
        // first paint. The user-uploaded background photo is
        // personal — strip it (and its image-only opacity slider).
        for index in copy.pages.indices {
            if let path = copy.pages[index].backgroundImagePath,
               !CanvasImageLoader.isBundled(path) {
                copy.pages[index].backgroundImagePath = nil
                copy.pages[index].backgroundImageOpacity = nil
            }
        }
        if let path = copy.pageBackgroundImagePath,
           !CanvasImageLoader.isBundled(path) {
            copy.pageBackgroundImagePath = nil
        }
        copy.syncLegacyFieldsFromFirstPage()

        // Section titles are structure; everything else in a section
        // card is user-authored copy. Capture title ids before
        // mutation so the sanitizer can keep the visible section
        // headings while clearing about/favorites/notes/link labels.
        let sectionTitleIDs = Set(
            QuickEditProfileMapper.sectionCardIDs(in: copy).compactMap {
                QuickEditProfileMapper.titleTextID(in: $0, document: copy)
            }
        )

        // Walk every node and either clear or keep based on role +
        // type. Mutating in place under a key snapshot avoids
        // dictionary iteration invalidation.
        for id in Array(copy.nodes.keys) {
            guard var node = copy.nodes[id] else { continue }
            sanitize(&node, preserveFreeformText: sectionTitleIDs.contains(id))
            copy.nodes[id] = node
        }

        // Re-normalize so adaptive hero text colors recompute against
        // the cleared/kept page background and so structural
        // contracts hold (hero geometry, section card stacking).
        StructuredProfileLayout.normalize(&copy)
        return copy
    }

    /// Mutate a single node in place — clearing personal payloads,
    /// keeping decorative styling. Per-type rules below; default is
    /// "leave alone" so a future node type ships without an
    /// accidental wipe of fields the remix path doesn't yet know
    /// about.
    private static func sanitize(_ node: inout CanvasNode, preserveFreeformText: Bool) {
        // Container backgrounds: photos are personal, gradients /
        // colors / blurs are decorative. Strip the image path + its
        // dependent effect knobs while leaving solid fills, gradient
        // tokens, and per-container blur/vignette intact.
        if let path = node.style.backgroundImagePath,
           !CanvasImageLoader.isBundled(path) {
            node.style.backgroundImagePath = nil
            node.style.backgroundBlur = nil
            node.style.backgroundVignette = nil
        }

        // Per-role hero clearing. The structured profile's hero
        // children always exist; clearing them puts the remix back at
        // the structuredProfileBlank's default copy so the new owner
        // sees the same "fill me in" prompt a brand-new user gets.
        switch node.role {
        case .profileName:
            setText(&node, to: "Display Name")
            return
        case .profileMeta:
            setText(&node, to: "@username")
            return
        case .profileBio:
            setText(&node, to: "Short bio, quote, status, or current thing.")
            return
        case .profileAvatar:
            // Avatar node is the structured photo slot. Clear the
            // image path so the avatar shows its placeholder
            // background, but keep the circle clip / border style.
            node.content.localImagePath = nil
            return
        default:
            break
        }

        // Per-type clearing for non-system nodes. The text on a
        // section-card title ("Wall", "Interests") is part of the
        // design vocabulary — keep those. Free-form text bodies
        // *inside* notes carry personal content, so the note body
        // does get scrubbed.
        switch node.type {
        case .image:
            // Standalone image nodes (gallery photos, decorative
            // pictures the user dropped on the canvas) are personal by
            // default. Bundled placeholders are app assets, not the
            // original author's remote/local files, so those survive.
            if let path = node.content.localImagePath,
               !CanvasImageLoader.isBundled(path) {
                node.content.localImagePath = nil
            }
        case .gallery:
            node.content.imagePaths = (node.content.imagePaths ?? []).filter {
                CanvasImageLoader.isBundled($0)
            }
        case .link:
            // Keep the link's variant style (pill/card/etc) but
            // strip the URL and replace the title with a generic
            // placeholder so the slot reads as "fill in your link"
            // rather than ghosting the original author's wording.
            node.content.url = ""
            setText(&node, to: "your link")
        case .note:
            node.content.noteTitle = "Notes"
            node.content.noteTimestamp = ""
            setText(&node, to: "Write a quick note here.")
        case .text:
            if !preserveFreeformText {
                setText(&node, to: "Add your details")
            }
        case .icon:
            node.content.url = nil
        case .container, .divider, .carousel:
            break
        }
    }

    /// Replace a node's `content.text` with a placeholder string and
    /// drop any inline style spans the original author had applied to
    /// it. The spans are addressed by UTF-16 offset/length so they
    /// would mis-render against the new (shorter or differently
    /// shaped) text.
    private static func setText(_ node: inout CanvasNode, to text: String) {
        node.content.text = text
        node.content.textStyleSpans = nil
    }
}
