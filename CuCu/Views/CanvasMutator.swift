import Foundation
import SwiftData
import SwiftUI

/// All the document-mutation methods that previously lived as private
/// helpers on `ProfileCanvasBuilderView`, lifted into a single struct
/// so the view's `body` doesn't have to carry them.
///
/// The mutator is a value type that holds bindings into the view's
/// state; calling it from the view is identical in semantics to the
/// previous inline implementations. Each method preserves the same
/// persistence contract — every committed mutation calls
/// `store.updateDocument(...)` exactly once at the end, matching the
/// pre-extraction cadence.
@MainActor
struct CanvasMutator {
    let document: Binding<ProfileDocument>
    let selectedID: Binding<UUID?>
    let draft: ProfileDraft
    let store: DraftStore
    let context: ModelContext
    let rootPageIndex: Int

    /// Reads the AppStorage default-font key (written by
    /// `applyTheme`). Used by `addNode(.text)` so newly-created text
    /// adopts the most recently-applied theme's display font. Returns
    /// `.system` when the key isn't set or the stored raw value
    /// doesn't decode to a known case (e.g. a future font case
    /// stored on a newer build, then read on an older binary —
    /// matches the forward-compat fallback in `NodeFontFamily.init(from:)`).
    static var themeDefaultFont: NodeFontFamily {
        let raw = UserDefaults.standard.string(forKey: CucuTheme.defaultFontStorageKey)
        return raw.flatMap { NodeFontFamily(rawValue: $0) } ?? .system
    }

    // MARK: - Add

    /// Insert a brand-new node of `type` under the currently-selected
    /// container, or under the page root. `image` and `gallery` go
    /// through the dedicated bytes-bearing helpers below — those cases
    /// are noops here on purpose so the switch stays exhaustive.
    func addNode(of type: NodeType) {
        let parentID = parentForInsertion()
        let pageIndex = targetPageIndex(parentID: parentID)
        var node: CanvasNode
        if isStructuredRootInsertion(parentID: parentID) {
            guard type == .container else { return }
            node = StructuredProfileLayout.makeSectionCard(
                in: document.wrappedValue,
                pageIndex: pageIndex
            )
        } else {
            switch type {
            case .container:
                node = isCarousel(parentID)
                    ? carouselContainerItem(parentID: parentID)
                    : .defaultContainer()
            case .text:
                var draft = isCarousel(parentID)
                    ? carouselTextItem(parentID: parentID)
                    : CanvasNode.defaultText()
                // Seed the new node's font from the active theme's
                // default. Existing nodes are intentionally untouched
                // by `applyTheme`; this is the future-tense half of
                // that contract — fresh text adopts the theme face.
                draft.style.fontFamily = Self.themeDefaultFont
                node = draft
            case .image:     return
            case .icon:
                node = isCarousel(parentID)
                    ? carouselIconItem(parentID: parentID)
                    : .defaultIcon()
            case .divider:
                node = isCarousel(parentID)
                    ? CanvasNode.defaultDivider(
                        at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 120, height: 28)),
                        size: CGSize(width: 120, height: 28))
                    : .defaultDivider()
            case .link:
                node = isCarousel(parentID)
                    ? CanvasNode.defaultLink(at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 150, height: 48)),
                                             size: CGSize(width: 150, height: 48))
                    : .defaultLink()
            case .gallery:   return
            case .carousel:
                node = .defaultCarousel()
            }
        }
        applyAdaptivePlacement(to: &node, parentID: parentID, pageIndex: pageIndex)
        document.wrappedValue.insert(node, under: parentID, onPage: pageIndex)
        StructuredProfileLayout.normalize(&document.wrappedValue)
        selectedID.wrappedValue = node.id
        store.updateDocument(draft, document: document.wrappedValue)
        CucuHaptics.soft()
    }

    /// Save picked image bytes to disk and create an image node referencing
    /// that local path. If the save fails, no node is created — the user's
    /// canvas stays clean.
    @discardableResult
    func addImageNode(from data: Data) -> Bool {
        let parentID = parentForInsertion()
        guard !isStructuredRootInsertion(parentID: parentID) else { return false }
        let pageIndex = targetPageIndex(parentID: parentID)
        let nodeID = UUID()
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            var node = isCarousel(parentID)
                ? CanvasNode.defaultImage(
                    localImagePath: path,
                    at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 120, height: 96)),
                    size: CGSize(width: 120, height: 96)
                )
                : CanvasNode.defaultImage(localImagePath: path)
            node.id = nodeID
            applyAdaptivePlacement(to: &node, parentID: parentID, pageIndex: pageIndex)
            document.wrappedValue.insert(node, under: parentID, onPage: pageIndex)
            StructuredProfileLayout.normalize(&document.wrappedValue)
            selectedID.wrappedValue = nodeID
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.soft()
            return true
        } catch {
            // Save failed — no broken node is added. The add sheet keeps
            // itself open and shows the user a retryable error.
            return false
        }
    }

    /// Save picked image bytes to disk and create an avatar node — a
    /// circle-clipped image at a square frame so the result is a true
    /// profile-pic circle on first paint. Identical disk-save path as
    /// `addImageNode`; only the style differs.
    @discardableResult
    func addAvatarNode(from data: Data) -> Bool {
        let parentID = parentForInsertion()
        guard !isStructuredRootInsertion(parentID: parentID) else { return false }
        let pageIndex = targetPageIndex(parentID: parentID)
        let nodeID = UUID()
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            // Square frame + circle clip = profile-pic circle. The
            // size is intentionally smaller than `defaultImage`'s
            // 200pt because avatars typically read better at ~120pt.
            let avatarSize = isCarousel(parentID)
                ? CGSize(width: 88, height: 88)
                : CGSize(width: 120, height: 120)
            var node = CanvasNode.defaultImage(
                localImagePath: path,
                at: isCarousel(parentID)
                    ? nextCarouselItemOrigin(parentID: parentID, size: avatarSize)
                    : CGPoint(x: 32, y: 80),
                size: avatarSize
            )
            node.id = nodeID
            node.style.clipShape = .circle
            // Subtle white ring so the avatar separates from any
            // page background — same convention `imagePlaceholderTree`
            // uses inside the hero preset.
            node.style.borderColorHex = "#FFFFFF"
            node.style.borderWidth = 2
            applyAdaptivePlacement(to: &node, parentID: parentID, pageIndex: pageIndex)
            document.wrappedValue.insert(node, under: parentID, onPage: pageIndex)
            StructuredProfileLayout.normalize(&document.wrappedValue)
            selectedID.wrappedValue = nodeID
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.soft()
            return true
        } catch {
            return false
        }
    }

    /// Save each picked image's bytes to disk under fresh per-image
    /// UUIDs and create one gallery node referencing all of them. The
    /// gallery's own `id` is distinct from the image-asset UUIDs so the
    /// node and its assets don't collide. Skips bytes that fail to
    /// normalize — partial saves are better than zero-image galleries
    /// and the user can pick more from the inspector if they want.
    @discardableResult
    func addGalleryNode(from imageBytesList: [Data]) -> Bool {
        let parentID = parentForInsertion()
        guard !isStructuredRootInsertion(parentID: parentID) else { return false }
        let pageIndex = targetPageIndex(parentID: parentID)

        var savedPaths: [String] = []
        for bytes in imageBytesList {
            let assetID = UUID()
            do {
                let path = try LocalCanvasAssetStore.saveImage(
                    bytes,
                    draftID: draft.id,
                    nodeID: assetID
                )
                savedPaths.append(path)
            } catch {
                // Skip this image; keep the rest.
            }
        }
        guard !savedPaths.isEmpty else { return false }

        var node = isCarousel(parentID)
            ? CanvasNode.defaultGallery(
                imagePaths: savedPaths,
                at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 160, height: 104)),
                size: CGSize(width: 160, height: 104)
            )
            : CanvasNode.defaultGallery(imagePaths: savedPaths)
        applyAdaptivePlacement(to: &node, parentID: parentID, pageIndex: pageIndex)
        document.wrappedValue.insert(node, under: parentID, onPage: pageIndex)
        StructuredProfileLayout.normalize(&document.wrappedValue)
        selectedID.wrappedValue = node.id
        store.updateDocument(draft, document: document.wrappedValue)
        return true
    }

    /// Append more images to an existing gallery node (called from the
    /// property inspector). New images are saved under fresh UUIDs and
    /// appended to the node's `imagePaths`. Returns `false` if no
    /// bytes saved at all so the inspector can surface a single error.
    @discardableResult
    func appendGalleryImages(for nodeID: UUID, with imageBytesList: [Data]) -> Bool {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .gallery else { return false }

        var newPaths: [String] = []
        for bytes in imageBytesList {
            let assetID = UUID()
            do {
                // Gallery tiles render in small grid cells and at most go
                // to a lightbox at device width — they don't need the
                // full 1400pt block cap. Using `galleryImageMaxDimension`
                // (1200pt) here trims another ~30% off each saved file
                // and the per-image decode memory.
                let path = try LocalCanvasAssetStore.saveImage(
                    bytes,
                    draftID: draft.id,
                    nodeID: assetID,
                    maxDimension: ImageNormalizer.galleryImageMaxDimension
                )
                newPaths.append(path)
            } catch { }
        }
        guard !newPaths.isEmpty else { return false }

        var existing = node.content.imagePaths ?? []
        existing.append(contentsOf: newPaths)
        node.content.imagePaths = existing
        document.wrappedValue.nodes[nodeID] = node
        store.updateDocument(draft, document: document.wrappedValue)
        return true
    }

    /// Remove the image at `index` from a gallery node. The underlying
    /// file is deleted only if no other node still references the same
    /// path (mirrors `deleteUnreferencedAssetPaths`).
    func removeGalleryImage(for nodeID: UUID, at index: Int) {
        guard var node = document.wrappedValue.nodes[nodeID],
              node.type == .gallery,
              var paths = node.content.imagePaths,
              index >= 0, index < paths.count else { return }
        let removed = paths.remove(at: index)
        node.content.imagePaths = paths
        document.wrappedValue.nodes[nodeID] = node
        if !Self.assetPathIsReferenced(removed, in: document.wrappedValue) {
            LocalCanvasAssetStore.delete(relativePath: removed)
        }
        store.updateDocument(draft, document: document.wrappedValue)
    }

    /// Replace the image bytes for an existing image node. The new file is
    /// written under the node's own ID, so duplicated nodes that initially
    /// shared a path get their own file on first replacement (no clobbering
    /// the original's image).
    @discardableResult
    func replaceImage(for nodeID: UUID, with data: Data) -> Bool {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .image else { return false }
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.content.localImagePath = path
            document.wrappedValue.nodes[nodeID] = node
            // Same-path overwrite: the node's stored fields are
            // byte-identical to before (deterministic filename), so
            // SwiftUI's `==` would compare equal and skip re-render.
            // Bump the render revision to force structural inequality
            // so `updateUIView` fires and the canvas rebinds the new
            // bytes — see `ProfileDocument.renderRevision`.
            document.wrappedValue.renderRevision &+= 1
            store.updateDocument(draft, document: document.wrappedValue)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Carousel item placement

    private func isCarousel(_ parentID: UUID?) -> Bool {
        guard let parentID else { return false }
        return document.wrappedValue.nodes[parentID]?.type == .carousel
    }

    /// When a new child is inserted under a text node, position it
    /// just to the right of the rendered text instead of at the type's
    /// hard-coded default origin (which usually overlaps the text or
    /// falls outside the parent's bounds entirely). Returns `nil` when
    /// the parent isn't a text node — the caller falls back to the
    /// default origin in that case.
    ///
    /// Width is measured against the parent text's `font + content`,
    /// matching what `TextNodeView` will actually paint. Weight is
    /// pinned to `.regular` because the resolver's full weight bridge
    /// lives inside `TextNodeView` (private extension); the resulting
    /// width drift between weights is small enough that the placement
    /// still reads as "next to the text" — and the user can drag it.
    private func originForChildNextToText(parentID: UUID,
                                          childSize: CGSize) -> CGPoint? {
        guard let parent = document.wrappedValue.nodes[parentID],
              parent.type == .text else { return nil }

        let text = parent.content.text ?? ""
        let fontSize = CGFloat(parent.style.fontSize ?? 17)
        let family = parent.style.fontFamily ?? .system
        let font = family.uiFont(size: fontSize, weight: .regular)

        // `TextNodeView` paints with 4pt leading/trailing padding;
        // mirror that so the child clears the rendered glyphs.
        let textInsetX: CGFloat = 4
        let availableWidth = max(0, CGFloat(parent.frame.width) - textInsetX * 2)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: availableWidth,
                         height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font],
            context: nil
        )
        let renderedWidth = ceil(bounds.width)

        // Place the child a 6pt gap past the text. Cap to the parent's
        // right edge so the new child stays inside the text node's
        // frame — if the text already fills the bounds, the child
        // butts up against the trailing edge and the user can drag.
        let gap: CGFloat = 6
        let parentWidth = CGFloat(parent.frame.width)
        let parentHeight = CGFloat(parent.frame.height)
        let preferredX = textInsetX + renderedWidth + gap
        let maxX = max(0, parentWidth - childSize.width)
        let x = min(preferredX, maxX)
        let y = max(0, (parentHeight - childSize.height) / 2)
        return CGPoint(x: x, y: y)
    }

    /// Compute a fitted (origin, size) for a new child node added to
    /// the page root or inside a container. Centers horizontally,
    /// stacks vertically below existing siblings, **and shrinks the
    /// preferred size to fit the parent's available room** so a
    /// 240×160 container can host a 320-wide divider or a 200×200
    /// image without the child being clipped by `masksToBounds`.
    /// Returns nil for text or carousel parents — those have their
    /// own placement helpers (`originForChildNextToText`,
    /// `nextCarouselItemOrigin`).
    private func stackedFittedFrame(parentID: UUID?,
                                    onPage pageIndex: Int,
                                    preferredSize: CGSize) -> CGRect? {
        let parentWidth: CGFloat
        let parentHeight: CGFloat
        let siblingIDs: [UUID]
        let inset: CGFloat
        let topPadding: CGFloat
        let gap: CGFloat = 12
        let minWidth: CGFloat = 40
        let minHeight: CGFloat = 24

        if let parentID,
           let parent = document.wrappedValue.nodes[parentID],
           parent.type != .text,
           parent.type != .carousel {
            // Container, image, icon, divider, link, gallery — any
            // non-carousel parent gets fitted/centered placement.
            // Text uses `originForChildNextToText`; carousel uses
            // `nextCarouselItemOrigin` and is filtered earlier.
            parentWidth = CGFloat(parent.frame.width)
            parentHeight = CGFloat(parent.frame.height)
            siblingIDs = parent.childrenIDs
            inset = 8
            topPadding = 12
        } else if parentID == nil,
                  document.wrappedValue.pages.indices.contains(pageIndex) {
            parentWidth = CGFloat(document.wrappedValue.pageWidth)
            // Page is intentionally tall — no vertical clamp at root.
            parentHeight = .greatestFiniteMagnitude
            siblingIDs = document.wrappedValue.pages[pageIndex].rootChildrenIDs
            inset = 0
            topPadding = 32
        } else {
            return nil
        }

        let maxWidth = max(minWidth, parentWidth - inset * 2)
        let width = min(preferredSize.width, maxWidth)

        let maxBottom = siblingIDs.compactMap { id -> CGFloat? in
            guard let frame = document.wrappedValue.nodes[id]?.frame else { return nil }
            return CGFloat(frame.y + frame.height)
        }.max()
        let stackedY = (maxBottom.map { $0 + gap }) ?? topPadding

        // Cap y so a new child lands fully inside the parent even
        // when existing siblings have already filled it. Without this
        // the stacked y can exceed parentHeight and the new node is
        // clipped by `masksToBounds` the instant it's added.
        // `.greatestFiniteMagnitude` for root makes the cap a no-op
        // there — the page is intentionally unbounded vertically.
        let maxY = max(topPadding, parentHeight - minHeight - inset)
        let y = min(stackedY, maxY)

        let availableHeight = max(minHeight, parentHeight - y - inset)
        let height = min(preferredSize.height, availableHeight)

        let x = max(0, (parentWidth - width) / 2)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Post-creation placement for new nodes. Encapsulates the order
    /// that all five `add…` entry points share:
    ///   1. Carousel parent → keep the per-element helper's frame
    ///      (already laid out in carousel content space).
    ///   2. Text parent → drop the new child next to the rendered
    ///      glyphs (`originForChildNextToText`), preserving its size.
    ///   3. Container or page root → fit the size to the parent and
    ///      center / stack the origin (`stackedFittedFrame`).
    private func applyAdaptivePlacement(to node: inout CanvasNode,
                                        parentID: UUID?,
                                        pageIndex: Int) {
        if parentID == nil && node.role == .sectionCard { return }
        if isCarousel(parentID) { return }
        if let parentID,
           let origin = originForChildNextToText(
                parentID: parentID,
                childSize: CGSize(width: node.frame.width, height: node.frame.height)) {
            node.frame.x = Double(origin.x)
            node.frame.y = Double(origin.y)
            return
        }
        if let adapted = stackedFittedFrame(
            parentID: parentID,
            onPage: pageIndex,
            preferredSize: CGSize(width: node.frame.width, height: node.frame.height)) {
            node.frame.x = Double(adapted.origin.x)
            node.frame.y = Double(adapted.origin.y)
            node.frame.width = Double(adapted.size.width)
            node.frame.height = Double(adapted.size.height)
        }
    }

    private func nextCarouselItemOrigin(parentID: UUID?, size: CGSize) -> CGPoint {
        guard let parentID,
              let carousel = document.wrappedValue.nodes[parentID],
              carousel.type == .carousel else {
            return CGPoint(x: 32, y: 80)
        }

        let gap: Double = 12
        let leading: Double = 16
        let maxX = carousel.childrenIDs.compactMap { childID -> Double? in
            guard let maxX = document.wrappedValue.nodes[childID]?.frame.cgRect.maxX else {
                return nil
            }
            return Double(maxX)
        }.max()
        let x = (maxX.map { $0 + gap }) ?? leading
        let y = max(12, (carousel.frame.height - Double(size.height)) / 2)
        return CGPoint(x: x, y: y)
    }

    private func carouselTextItem(parentID: UUID?) -> CanvasNode {
        var node = CanvasNode.defaultText(
            at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 112, height: 44)),
            size: CGSize(width: 112, height: 44)
        )
        node.content.text = "Item"
        node.style.backgroundColorHex = "#FFFFFF"
        node.style.cornerRadius = 22
        node.style.borderWidth = 1
        node.style.borderColorHex = "#E5E5EA"
        node.style.fontWeight = .semibold
        node.style.fontSize = 16
        node.style.textAlignment = .center
        return node
    }

    private func carouselContainerItem(parentID: UUID?) -> CanvasNode {
        CanvasNode.defaultContainer(
            at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 144, height: 88)),
            size: CGSize(width: 144, height: 88)
        )
    }

    private func carouselIconItem(parentID: UUID?) -> CanvasNode {
        CanvasNode.defaultIcon(
            at: nextCarouselItemOrigin(parentID: parentID, size: CGSize(width: 72, height: 72)),
            size: CGSize(width: 72, height: 72)
        )
    }

    // MARK: - Container background

    /// Save picked bytes as the *container's* background image. Mirrors
    /// the page-background flow but writes to a per-node deterministic
    /// filename (`container_<UUID>.jpg`). Updates only the
    /// `style.backgroundImagePath` field; the rest of the node is
    /// untouched.
    @discardableResult
    func setContainerBackgroundImage(for nodeID: UUID, with data: Data) -> Bool {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .container else { return false }
        do {
            let path = try LocalCanvasAssetStore.saveContainerBackground(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.style.backgroundImagePath = path
            document.wrappedValue.nodes[nodeID] = node
            // Same-path overwrite — see `replaceImage` for context.
            document.wrappedValue.renderRevision &+= 1
            store.updateDocument(draft, document: document.wrappedValue)
            return true
        } catch {
            return false
        }
    }

    /// Remove the container's background image — delete the file and
    /// unset the path so the canvas renders just the color again.
    func clearContainerBackgroundImage(for nodeID: UUID) {
        guard var node = document.wrappedValue.nodes[nodeID], node.type == .container else { return }
        if let path = node.style.backgroundImagePath {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        node.style.backgroundImagePath = nil
        document.wrappedValue.nodes[nodeID] = node
        store.updateDocument(draft, document: document.wrappedValue)
    }

    // MARK: - Page background

    /// Save picked image bytes as a page background and update that page's
    /// `backgroundImagePath`. Filename is fixed per draft
    /// (`page_background.jpg`) so replacing always overwrites cleanly.
    ///
    /// When the upload represents a *new* image — first upload, a
    /// path change, or a same-path replace whose file mtime advanced
    /// — reset the per-image effect knobs (`backgroundImageOpacity`,
    /// `backgroundBlur`, `backgroundVignette`) to their defaults so a
    /// dialed-in 30% opacity from a prior photo doesn't silently
    /// apply to a freshly-uploaded one. `backgroundPatternKey` is
    /// *not* reset — it's a page-level decoration independent of the
    /// image.
    ///
    /// We stat the previous file pre-write rather than carrying mtime
    /// on `PageStyle`. The latter would force a Codable migration for
    /// a value the rest of the app doesn't read, and `LocalCanvasAssetStore`
    /// already exposes `modificationDate(_:)` for this exact purpose
    /// (the canvas's own bg-image cache uses it to bust on replace).
    @discardableResult
    func setPageBackgroundImage(_ data: Data, pageIndex: Int) -> Bool {
        do {
            guard let index = safePageIndex(pageIndex) else { return false }
            let previousPath = document.wrappedValue.pages[index].backgroundImagePath
            let previousMtime = LocalCanvasAssetStore.modificationDate(previousPath)
            let path = try LocalCanvasAssetStore.savePageBackground(
                data,
                draftID: draft.id,
                pageID: index == 0 ? nil : document.wrappedValue.pages[index].id
            )
            document.wrappedValue.pages[index].backgroundImagePath = path
            let currentMtime = LocalCanvasAssetStore.modificationDate(path)
            let pathChanged = path != previousPath
            let mtimeAdvanced = previousMtime != currentMtime
            if pathChanged || mtimeAdvanced {
                // `nil` carries the "use default" signal in `PageStyle`
                // — the canvas treats absent values as opacity 1, no
                // blur, no vignette. Setting nil rather than 1.0 / 0
                // keeps the JSON shape identical to a fresh draft.
                document.wrappedValue.pages[index].backgroundImageOpacity = nil
                document.wrappedValue.pages[index].backgroundBlur = nil
                document.wrappedValue.pages[index].backgroundVignette = nil
                // Force structural inequality on same-path replace —
                // see `replaceImage` for context. Without this, a
                // user who never dialed the effect knobs sees the
                // nil-resets above as a no-op and SwiftUI suppresses
                // the re-render even though the bytes on disk changed.
                document.wrappedValue.renderRevision &+= 1
            }
            document.wrappedValue.syncLegacyFieldsFromFirstPage()
            store.updateDocument(draft, document: document.wrappedValue)
            return true
        } catch {
            return false
        }
    }

    /// One-shot apply of a `CucuTheme`. Walks every page and writes
    /// `backgroundHex` + `backgroundPatternKey`; resets the per-image
    /// effect knobs (opacity, blur, vignette) so a previous theme's
    /// tuning doesn't bleed into this one — same logic as the
    /// image-swap reset in `setPageBackgroundImage`. The theme's
    /// `defaultDisplayFont` is written into a UserDefaults key shared
    /// with `@AppStorage(CucuTheme.defaultFontStorageKey)`, where
    /// new text-node creation will pick it up.
    ///
    /// Deliberately does **not** mutate `backgroundImagePath` (a
    /// theme is page chrome — if the user has a photo set, the
    /// theme's bg colour shows through transparent pixels and the
    /// pattern overlays the photo, which is the existing layered-
    /// canvas behaviour) and does **not** walk node styles to
    /// retro-apply the theme font (existing text keeps its current
    /// font; only future-tense nodes pick up the theme).
    func applyTheme(_ theme: CucuTheme) {
        theme.apply(to: &document.wrappedValue)
        store.updateDocument(draft, document: document.wrappedValue)
        CucuHaptics.success()
    }

    /// Clear the page background image — delete the file and unset the
    /// path so the canvas renders only the color again.
    func clearPageBackgroundImage(pageIndex: Int) {
        guard let index = safePageIndex(pageIndex) else { return }
        if let path = document.wrappedValue.pages[index].backgroundImagePath {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        document.wrappedValue.pages[index].backgroundImagePath = nil
        document.wrappedValue.syncLegacyFieldsFromFirstPage()
        store.updateDocument(draft, document: document.wrappedValue)
    }

    // MARK: - Selection-driven mutations

    func deleteSelected() {
        guard let id = selectedID.wrappedValue else { return }
        guard StructuredProfileLayout.canDelete(id, in: document.wrappedValue) else { return }
        let removedAssetPaths = Self.assetPaths(inSubtreeRootedAt: id, document: document.wrappedValue)
        document.wrappedValue.remove(id)
        deleteUnreferencedAssetPaths(removedAssetPaths)
        StructuredProfileLayout.normalize(&document.wrappedValue)
        selectedID.wrappedValue = nil
        store.updateDocument(draft, document: document.wrappedValue)
        CucuHaptics.delete()
    }

    func duplicateSelected() {
        guard let id = selectedID.wrappedValue else { return }
        guard StructuredProfileLayout.canDuplicate(id, in: document.wrappedValue) else { return }
        if let newID = document.wrappedValue.duplicate(id) {
            copyImageAssetsForDuplicatedSubtree(rootedAt: newID)
            StructuredProfileLayout.normalize(&document.wrappedValue)
            selectedID.wrappedValue = newID
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.duplicate()
        }
    }

    func bringSelectedToFront() {
        guard let id = selectedID.wrappedValue else { return }
        guard StructuredProfileLayout.canReorder(id, in: document.wrappedValue) else { return }
        document.wrappedValue.bringToFront(id)
        StructuredProfileLayout.normalize(&document.wrappedValue)
        store.updateDocument(draft, document: document.wrappedValue)
    }

    func sendSelectedBackward() {
        guard let id = selectedID.wrappedValue else { return }
        guard StructuredProfileLayout.canReorder(id, in: document.wrappedValue) else { return }
        document.wrappedValue.sendBackward(id)
        StructuredProfileLayout.normalize(&document.wrappedValue)
        store.updateDocument(draft, document: document.wrappedValue)
    }

    // MARK: - Templates

    func saveTemplate(named name: String) -> Bool {
        do {
            _ = try TemplateStore(context: context).createTemplate(
                name: name,
                document: document.wrappedValue
            )
            return true
        } catch {
            return false
        }
    }

    /// Apply a saved template to this draft. On success replaces the
    /// document and clears selection; the caller is responsible for
    /// resetting any view-only flags (legacyDraft / sheets) and firing
    /// the success haptic post-transition cues — see `onAppliedSuccess`.
    func applyTemplate(_ template: ProfileTemplate, onAppliedSuccess: () -> Void) -> Bool {
        do {
            let appliedDocument = try TemplateStore(context: context).apply(template, to: draft)
            document.wrappedValue = appliedDocument
            StructuredProfileLayout.normalize(&document.wrappedValue)
            selectedID.wrappedValue = nil
            store.updateDocument(draft, document: document.wrappedValue)
            CucuHaptics.success()
            onAppliedSuccess()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Asset housekeeping

    /// After a duplicate, the copied image nodes initially point at the
    /// original nodes' files because `ProfileDocument.duplicate` is a pure
    /// model clone. Give each copied image node its own deterministic asset
    /// path so later replace/delete operations stay node-local.
    func copyImageAssetsForDuplicatedSubtree(rootedAt rootID: UUID) {
        for nodeID in document.wrappedValue.subtree(rootedAt: rootID) {
            guard var node = document.wrappedValue.nodes[nodeID] else { continue }

            switch node.type {
            case .image:
                guard let currentPath = node.content.localImagePath,
                      !currentPath.isEmpty else { continue }
                do {
                    let copiedPath = try LocalCanvasAssetStore.copyImage(
                        from: currentPath,
                        draftID: draft.id,
                        nodeID: nodeID
                    )
                    node.content.localImagePath = copiedPath
                    document.wrappedValue.nodes[nodeID] = node
                } catch {
                    // If the source file is missing, keep the copied node's path
                    // as-is so the renderer shows its existing placeholder.
                }
            case .gallery:
                guard let currentPaths = node.content.imagePaths,
                      !currentPaths.isEmpty else { continue }
                // Each gallery image gets its own fresh asset UUID under
                // the new node so per-image replace/delete stays node-local.
                var copied: [String] = []
                for original in currentPaths {
                    let assetID = UUID()
                    do {
                        let path = try LocalCanvasAssetStore.copyImage(
                            from: original,
                            draftID: draft.id,
                            nodeID: assetID
                        )
                        copied.append(path)
                    } catch {
                        // Source missing — preserve the path so the
                        // gallery's count stays right; the renderer
                        // will show a placeholder for the missing tile.
                        copied.append(original)
                    }
                }
                node.content.imagePaths = copied
                document.wrappedValue.nodes[nodeID] = node
            default:
                break
            }
        }
    }

    static func assetPaths(inSubtreeRootedAt rootID: UUID, document: ProfileDocument) -> Set<String> {
        var paths: Set<String> = []
        for nodeID in document.subtree(rootedAt: rootID) {
            guard let node = document.nodes[nodeID] else { continue }
            if let path = node.content.localImagePath, !path.isEmpty {
                paths.insert(path)
            }
            if let path = node.style.backgroundImagePath, !path.isEmpty {
                paths.insert(path)
            }
            if let galleryPaths = node.content.imagePaths {
                for p in galleryPaths where !p.isEmpty { paths.insert(p) }
            }
        }
        return paths
    }

    func deleteUnreferencedAssetPaths(_ paths: Set<String>) {
        for path in paths where !Self.assetPathIsReferenced(path, in: document.wrappedValue) {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
    }

    static func assetPathIsReferenced(_ path: String, in document: ProfileDocument) -> Bool {
        if document.pages.contains(where: { $0.backgroundImagePath == path }) ||
            document.pageBackgroundImagePath == path {
            return true
        }
        return document.nodes.values.contains { node in
            if node.content.localImagePath == path { return true }
            if node.style.backgroundImagePath == path { return true }
            if let gallery = node.content.imagePaths, gallery.contains(path) { return true }
            return false
        }
    }

    // MARK: - Internals

    /// Where a new node lands:
    ///   • Selected `.container` / `.carousel` / `.text` → directly
    ///     into that node.
    ///   • Selected leaf inside a carousel → sibling item in that
    ///     carousel (otherwise dropping a new item on top of an
    ///     existing carousel child would visually leave the strip).
    ///   • Selected leaf elsewhere (image, icon, divider, link,
    ///     gallery) → nested inside that leaf, so users can drop a
    ///     badge icon on an image, an accent on an icon, etc.
    ///   • Nothing selected → page root.
    /// Mirrors the rule used for the AddNodeSheet's banner so the
    /// "Adding to:" hint matches reality. Pair this with the
    /// recursion arm in `CanvasEditorView.applyNode` so the canvas
    /// actually renders the new children.
    func parentForInsertion() -> UUID? {
        guard let sid = selectedID.wrappedValue,
              let node = document.wrappedValue.nodes[sid] else {
            return nil
        }
        if StructuredProfileLayout.isStructured(document.wrappedValue) {
            if StructuredProfileLayout.isInSystemProfileSubtree(sid, in: document.wrappedValue) {
                return nil
            }
            if node.type == .carousel {
                return sid
            }
            if let carouselID = carouselAncestor(containing: sid) {
                return carouselID
            }
            if node.role == .sectionCard {
                return sid
            }
            if node.type == .container,
               StructuredProfileLayout.sectionCardAncestor(containing: sid, in: document.wrappedValue) != nil {
                return sid
            }
            return StructuredProfileLayout.sectionCardAncestor(containing: sid, in: document.wrappedValue)
        }

        switch node.type {
        case .container, .carousel, .text:
            return sid
        default:
            // Inside a carousel? New items become carousel siblings.
            // Otherwise nest inside the selected leaf.
            return carouselAncestor(containing: sid) ?? sid
        }
    }

    private func safePageIndex(_ requestedIndex: Int) -> Int? {
        guard !document.wrappedValue.pages.isEmpty else { return nil }
        return document.wrappedValue.pages.indices.contains(requestedIndex) ? requestedIndex : 0
    }

    private func targetPageIndex(parentID: UUID?) -> Int {
        if let parentID, let pageIndex = document.wrappedValue.pageContaining(parentID) {
            return pageIndex
        }
        if StructuredProfileLayout.isStructured(document.wrappedValue),
           let primaryPageIndex = StructuredProfileLayout.primaryPageIndex(in: document.wrappedValue) {
            return primaryPageIndex
        }
        if let selectedID = selectedID.wrappedValue,
           let pageIndex = document.wrappedValue.pageContaining(selectedID) {
            return pageIndex
        }
        guard !document.wrappedValue.pages.isEmpty else { return 0 }
        return document.wrappedValue.pages.indices.contains(rootPageIndex)
            ? rootPageIndex
            : max(0, document.wrappedValue.pages.count - 1)
    }

    /// Return the carousel that owns `id`, or nil when the selected node
    /// is outside all carousels.
    private func carouselAncestor(containing id: UUID) -> UUID? {
        var current: UUID? = id
        while let nodeID = current,
              let parentID = document.wrappedValue.parent(of: nodeID) {
            if document.wrappedValue.nodes[parentID]?.type == .carousel {
                return parentID
            }
            current = parentID
        }
        return nil
    }

    private func isStructuredRootInsertion(parentID: UUID?) -> Bool {
        parentID == nil && StructuredProfileLayout.isStructured(document.wrappedValue)
    }
}
