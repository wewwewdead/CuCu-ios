import CoreGraphics
import Foundation
import UIKit

/// Layout contract for the structured profile builder. Legacy/freeform
/// documents have no profile roles, so every helper exits without touching
/// them unless the document is explicitly structured.
enum StructuredProfileLayout {
    static let horizontalMargin: Double = 16
    static let heroHeight: Double = 320
    static let dividerTopSpacing: Double = 8
    static let dividerHeight: Double = 30
    static let cardSpacing: Double = 16
    static let cardDefaultHeight: Double = 184
    static let cardMinimumHeight: Double = 120
    static let bottomPadding: Double = 64

    static func isStructured(_ document: ProfileDocument) -> Bool {
        // Hero is the only required system node. The fixed divider is
        // a legacy companion — older drafts ship with one, but new
        // structured documents (post `structuredProfileBlank` rewrite)
        // do not, and `normalize` handles both shapes.
        roleID(.profileHero, in: document) != nil
    }

    static func isEmptyCanvas(_ document: ProfileDocument) -> Bool {
        document.nodes.isEmpty && document.pages.allSatisfy { $0.rootChildrenIDs.isEmpty }
    }

    static func primaryPageIndex(in document: ProfileDocument) -> Int? {
        guard let heroID = roleID(.profileHero, in: document) else { return nil }
        return document.pageContaining(heroID)
    }

    static func roleID(_ role: CanvasNodeRole, in document: ProfileDocument) -> UUID? {
        document.nodes.first(where: { $0.value.role == role })?.key
    }

    static func sectionCardAncestor(containing id: UUID, in document: ProfileDocument) -> UUID? {
        var current: UUID? = id
        while let nodeID = current {
            guard let node = document.nodes[nodeID] else { return nil }
            if node.role == .sectionCard { return nodeID }
            current = document.parent(of: nodeID)
        }
        return nil
    }

    static func isInSystemProfileSubtree(_ id: UUID, in document: ProfileDocument) -> Bool {
        guard let node = document.nodes[id] else { return false }
        if node.role?.isSystemOwned == true { return true }
        var current = document.parent(of: id)
        while let parentID = current {
            guard let parent = document.nodes[parentID] else { break }
            if parent.role?.isSystemOwned == true { return true }
            current = document.parent(of: parentID)
        }
        return false
    }

    static func resizeBehavior(for id: UUID, in document: ProfileDocument) -> CanvasResizeBehavior {
        guard let node = document.nodes[id] else { return .freeform }
        if isInSystemProfileSubtree(id, in: document) { return .locked }
        if node.role == .sectionCard { return .verticalOnly }
        // Content-bearing leaf primitives are auto-fitted by the
        // structured layout (or by their own intrinsic geometry) and
        // shouldn't be canvas-resizable. Dragging a corner handle
        // here previously stretched the element's frame, and with
        // `imageFit = .fill` an image element re-cropped to the new
        // bounds — visually that reads as "the photo moved inside
        // the container", which surprises users. Lock these types so
        // the only canvas affordance is selection + drag-to-reorder
        // at the top level; size edits go through the inspector's
        // Layout tab.
        switch node.type {
        case .image, .gallery, .carousel, .divider, .link:
            return .locked
        case .container, .text, .icon, .note:
            break
        }
        return node.resizeBehavior ?? .freeform
    }

    static func canMove(_ id: UUID, in document: ProfileDocument) -> Bool {
        resizeBehavior(for: id, in: document) == .freeform
    }

    static func canDelete(_ id: UUID, in document: ProfileDocument) -> Bool {
        !isInSystemProfileSubtree(id, in: document)
    }

    static func canDuplicate(_ id: UUID, in document: ProfileDocument) -> Bool {
        !isInSystemProfileSubtree(id, in: document)
    }

    static func canReorder(_ id: UUID, in document: ProfileDocument) -> Bool {
        guard !isInSystemProfileSubtree(id, in: document) else { return false }
        guard document.nodes[id]?.role == .sectionCard else { return true }
        return document.parent(of: id) != nil
    }

    static func nextCardFrame(in document: ProfileDocument, pageIndex: Int) -> NodeFrame {
        let pageIndex = safePageIndex(pageIndex, in: document)
        let width = max(160, document.pageWidth - horizontalMargin * 2)
        let baseY = dividerBottom(in: document) + cardSpacing
        let lastCardBottom = document.children(of: nil, onPage: pageIndex)
            .compactMap { id -> Double? in
                guard document.nodes[id]?.role == .sectionCard,
                      let frame = document.nodes[id]?.frame else { return nil }
                return frame.y + max(frame.height, cardMinimumHeight)
            }
            .max()
        return NodeFrame(
            x: horizontalMargin,
            y: max(baseY, (lastCardBottom.map { $0 + cardSpacing }) ?? baseY),
            width: width,
            height: cardDefaultHeight
        )
    }

    static func makeSectionCard(in document: ProfileDocument,
                                pageIndex: Int,
                                height: Double = cardDefaultHeight,
                                name: String = "Section Card") -> CanvasNode {
        var frame = nextCardFrame(in: document, pageIndex: pageIndex)
        frame.height = max(cardMinimumHeight, height)
        return CanvasNode(
            type: .container,
            name: name,
            frame: frame,
            role: .sectionCard,
            resizeBehavior: .verticalOnly,
            style: NodeStyle(
                backgroundColorHex: "#FFFFFF",
                cornerRadius: 18,
                borderWidth: 1,
                borderColorHex: "#E7DED1"
            )
        )
    }

    static func normalize(_ document: inout ProfileDocument) {
        guard isStructured(document) else { return }
        guard let pageIndex = primaryPageIndex(in: document),
              document.pages.indices.contains(pageIndex),
              let heroID = roleID(.profileHero, in: document) else { return }
        // Divider is optional — present in legacy drafts, absent in
        // freshly-reset documents. Treat it as a maybe throughout.
        let dividerID = roleID(.fixedDivider, in: document)

        let pageWidth = document.pageWidth
        let cardWidth = max(160, pageWidth - horizontalMargin * 2)

        if var hero = document.nodes[heroID] {
            hero.frame = NodeFrame(x: 0, y: 0, width: pageWidth, height: heroHeight)
            hero.resizeBehavior = .locked
            hero.role = .profileHero
            document.nodes[heroID] = hero
        }

        normalizeHeroChildren(in: &document, heroID: heroID)
        applyAdaptiveHeroTextColors(in: &document, pageIndex: pageIndex, heroID: heroID)

        // Cards stack below the hero, with the divider squeezed in
        // between when one exists. Without a divider, the cards start
        // a single `cardSpacing` past the hero's bottom edge.
        let firstCardY: Double
        if let dividerID, var divider = document.nodes[dividerID] {
            let dividerY = heroHeight + dividerTopSpacing
            divider.frame = NodeFrame(
                x: horizontalMargin,
                y: dividerY,
                width: cardWidth,
                height: dividerHeight
            )
            divider.role = .fixedDivider
            divider.resizeBehavior = .locked
            document.nodes[dividerID] = divider
            firstCardY = dividerY + dividerHeight + cardSpacing
        } else {
            firstCardY = heroHeight + cardSpacing
        }

        // Auto-stack every non-system top-level node — section cards
        // and user-added primitives alike — using the rootChildrenIDs
        // order as the canonical sequence. The canvas is a vertical
        // list: each child gets a fixed x and a y derived purely from
        // its position in the order, so a freeform drag has no
        // meaning at the page root. Drag-to-reorder mutates the
        // order, then this normalizer re-snaps everyone to their new
        // y. Cards still get the full card width + minimum height
        // contract; other types keep their authored dimensions so a
        // narrow divider stays narrow and a tall gallery stays tall.
        var y = firstCardY
        let rootIDs = document.pages[pageIndex].rootChildrenIDs
        let stackable = rootIDs.filter { id in
            guard id != heroID, id != dividerID else { return false }
            return document.nodes[id] != nil
        }
        for id in stackable {
            guard var node = document.nodes[id] else { continue }
            if node.role == .sectionCard {
                // Section cards always fill the column — they're the
                // structured profile's primary container, and the
                // user's content lives inside them.
                node.frame.x = horizontalMargin
                node.frame.y = y
                node.frame.width = cardWidth
                node.frame.height = max(cardMinimumHeight, node.frame.height)
                node.resizeBehavior = .verticalOnly
            } else {
                // Block-level types share the same column section
                // cards use — same `horizontalMargin` left edge,
                // same `cardWidth` extent. That keeps the canvas's
                // left rhythm consistent: hero copy, section cards,
                // dividers, galleries, carousels, links, plain text
                // all line up at the same vertical guide. Compact
                // visual primitives (icons, images) keep their
                // authored size and center horizontally so a small
                // accent doesn't get stretched into a banner.
                switch node.type {
                case .image, .icon:
                    let nodeWidth = min(node.frame.width, cardWidth)
                    node.frame.width = nodeWidth
                    node.frame.x = max(horizontalMargin, (pageWidth - nodeWidth) / 2)
                case .container, .text, .divider, .link, .gallery, .carousel, .note:
                    node.frame.x = horizontalMargin
                    node.frame.width = cardWidth
                }
                node.frame.y = y
            }
            document.nodes[id] = node
            y = node.frame.y + node.frame.height + cardSpacing
        }

        var orderedRoots: [UUID] = [heroID]
        if let dividerID { orderedRoots.append(dividerID) }
        orderedRoots.append(contentsOf: stackable)
        document.pages[pageIndex].rootChildrenIDs = orderedRoots
        document.pages[pageIndex].height = max(ProfileDocument.defaultPageHeight, y + bottomPadding)
        document.syncLegacyFieldsFromFirstPage()
    }

    /// Recomputes the hero's name / @username / bio colors against
    /// the page's current visible background — the bg image when one
    /// is set, otherwise the page's `backgroundHex`. Light text on
    /// dark surfaces, ink text on light surfaces. Only mutates nodes
    /// whose `textColorAuto` flag is `true`; the inspector's color
    /// picker flips that flag off on a user pick so custom colors
    /// stay sticky from that point on.
    private static func applyAdaptiveHeroTextColors(in document: inout ProfileDocument,
                                                    pageIndex: Int,
                                                    heroID: UUID) {
        guard document.pages.indices.contains(pageIndex),
              let hero = document.nodes[heroID] else { return }
        let page = document.pages[pageIndex]
        let darkBg = isPageBackgroundDark(page: page)
        let palette = adaptiveHeroPalette(darkBg: darkBg)

        for childID in hero.childrenIDs {
            guard var child = document.nodes[childID],
                  child.style.textColorAuto == true else { continue }
            switch child.role {
            case .profileName: child.style.textColorHex = palette.primary
            case .profileMeta: child.style.textColorHex = palette.muted
            case .profileBio:  child.style.textColorHex = palette.secondary
            default:           continue
            }
            document.nodes[childID] = child
        }
    }

    /// Resolves a page's effective background tone for the contrast
    /// helper. Image-backed pages dominate the visible canvas, so we
    /// sample the image's average luminance instead of trusting the
    /// underlying `backgroundHex` (which is usually a stale fallback
    /// from before the user uploaded the photo). The sample uses a
    /// 1×1 CGContext draw — cheap, and `BackgroundLuminanceCache`
    /// memoizes the result keyed by path + mtime so repeated
    /// normalize passes don't re-decode the same file. If sampling
    /// fails (file missing, decode error), fall through to the hex
    /// — and as a last-resort default for an image we couldn't read,
    /// assume it's a photo (most uploads are mid-to-dark) and pick
    /// the light-text palette.
    ///
    /// Surface is internal (not file-private) so the canvas chrome
    /// can route through the same predicate when picking the edit
    /// mode's accent color — keeping a single source of truth for
    /// "is the visible page surface dark."
    static func isPageBackgroundDark(page: PageStyle) -> Bool {
        if let path = page.backgroundImagePath, !path.isEmpty {
            if let lum = BackgroundLuminanceCache.luminance(forImageAt: path) {
                return lum < 0.55
            }
            return true
        }
        return isHexColorDark(page.backgroundHex)
    }

    /// Three text tones picked to read against a light or dark page —
    /// primary for the name, secondary for the bio, muted for the
    /// @username caption. Hexes match the cucu palette tokens
    /// (`cucuInk` / `cucuInkSoft` / `cucuInkFaded` on light, their
    /// cream-side counterparts on dark) so the auto pick lands inside
    /// the same color system the rest of the app uses.
    private static func adaptiveHeroPalette(darkBg: Bool)
        -> (primary: String, secondary: String, muted: String) {
        if darkBg {
            return (primary: "#FBF9F2",
                    secondary: "#E5DCC9",
                    muted: "#C9C0B0")
        }
        return (primary: "#1A140E",
                secondary: "#3A3024",
                muted: "#7A6A58")
    }

    /// Rec. 709 luminance check on a hex color. Mirrors the math the
    /// toolbar tint already uses (`focusedPageIsDark` in
    /// `ProfileCanvasBuilderView`) so a single threshold decides both
    /// the toolbar's color scheme and the hero's text contrast.
    private static func isHexColorDark(_ hex: String) -> Bool {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt32(trimmed.prefix(6), radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum < 0.5
    }

    private static func normalizeHeroChildren(in document: inout ProfileDocument, heroID: UUID) {
        let pageWidth = document.pageWidth
        // Hero content sits at `horizontalMargin` — the same gutter
        // section cards use — so the avatar's left edge, the
        // display name's left edge, and every block below the hero
        // share a single column. Hero text is left-aligned, not
        // centered. The avatar lives at the column's left edge too,
        // matching the Twitter/Instagram profile silhouette rather
        // than the LinkedIn-style centered medallion.
        let avatarSize: Double = 100
        let textWidth = max(160, pageWidth - horizontalMargin * 2)
        let leftX = horizontalMargin
        let frames: [CanvasNodeRole: NodeFrame] = [
            .profileAvatar: NodeFrame(x: leftX, y: 84, width: avatarSize, height: avatarSize),
            .profileName: NodeFrame(x: leftX, y: 196, width: textWidth, height: 40),
            .profileMeta: NodeFrame(x: leftX, y: 236, width: textWidth, height: 24),
            .profileBio: NodeFrame(x: leftX, y: 262, width: textWidth, height: 48),
        ]

        for (id, node) in document.nodes where node.role?.isSystemOwned == true {
            guard var next = document.nodes[id] else { continue }
            if let frame = next.role.flatMap({ frames[$0] }) {
                next.frame = frame
            }
            next.resizeBehavior = .locked
            document.nodes[id] = next
        }

        guard var hero = document.nodes[heroID] else { return }
        let roleOrder: [CanvasNodeRole] = [.profileAvatar, .profileName, .profileMeta, .profileBio]
        let orderedChildren = roleOrder.compactMap { role in
            hero.childrenIDs.first { document.nodes[$0]?.role == role }
        }
        let remaining = hero.childrenIDs.filter { id in
            guard let role = document.nodes[id]?.role else { return true }
            return !roleOrder.contains(role)
        }
        hero.childrenIDs = orderedChildren + remaining
        document.nodes[heroID] = hero
    }

    /// Y coordinate where section cards start stacking. With a divider
    /// in the document, that's the divider's bottom edge; without one,
    /// it's directly below the hero. Used by `nextCardFrame` so a
    /// fresh "Add Section" lands in the right slot regardless of which
    /// shape the document has.
    private static func dividerBottom(in document: ProfileDocument) -> Double {
        if let dividerID = roleID(.fixedDivider, in: document),
           let divider = document.nodes[dividerID] {
            return divider.frame.y + divider.frame.height
        }
        return heroHeight
    }

    private static func safePageIndex(_ requested: Int, in document: ProfileDocument) -> Int {
        if let primary = primaryPageIndex(in: document) { return primary }
        if document.pages.indices.contains(requested) { return requested }
        return 0
    }
}

extension ProfileDocument {
    static var structuredProfileBlank: ProfileDocument {
        let pageWidth = ProfileDocument.defaultPageWidth

        // Hero geometry mirrors `normalizeHeroChildren` so a fresh
        // doc and a normalize pass land on the same coordinates.
        // Avatar and text both sit at `horizontalMargin` — the same
        // gutter section cards use — so the hero shares a single
        // left-edge column with everything below it. Text is
        // left-aligned (Twitter/Instagram silhouette), not centered.
        let avatarSize: Double = 100
        let textWidth = max(160, pageWidth - StructuredProfileLayout.horizontalMargin * 2)
        let leftX = StructuredProfileLayout.horizontalMargin

        let avatar = CanvasNode(
            type: .image,
            frame: NodeFrame(x: leftX, y: 84, width: avatarSize, height: avatarSize),
            role: .profileAvatar,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: "#F2F2F7",
                cornerRadius: 50,
                borderWidth: 2,
                borderColorHex: "#FFFFFF",
                imageFit: .fill,
                clipShape: .circle
            )
        )

        let name = CanvasNode(
            type: .text,
            frame: NodeFrame(x: leftX, y: 196, width: textWidth, height: 40),
            role: .profileName,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .fraunces,
                fontWeight: .bold,
                fontSize: 30,
                textColorHex: "#1A140E",
                textAlignment: .leading,
                textColorAuto: true
            ),
            content: NodeContent(text: "Display Name")
        )

        let meta = CanvasNode(
            type: .text,
            frame: NodeFrame(x: leftX, y: 236, width: textWidth, height: 24),
            role: .profileMeta,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .system,
                fontWeight: .semibold,
                fontSize: 14,
                textColorHex: "#7A6A58",
                textAlignment: .leading,
                textColorAuto: true
            ),
            content: NodeContent(text: "@username")
        )

        let bio = CanvasNode(
            type: .text,
            frame: NodeFrame(x: leftX, y: 262, width: textWidth, height: 48),
            role: .profileBio,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .system,
                fontWeight: .regular,
                fontSize: 15,
                textColorHex: "#3A3024",
                textAlignment: .leading,
                textColorAuto: true,
                lineSpacing: 2
            ),
            content: NodeContent(text: "Short bio, quote, status, or current thing.")
        )

        let hero = CanvasNode(
            type: .container,
            name: "Profile Header",
            childrenIDs: [avatar.id, name.id, meta.id, bio.id],
            frame: NodeFrame(x: 0, y: 0, width: pageWidth, height: StructuredProfileLayout.heroHeight),
            role: .profileHero,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                cornerRadius: 0,
                borderWidth: 0,
                borderColorHex: nil
            )
        )

        // Profile reset and first-launch land here. The structured profile
        // baseline is intentionally just the hero — the user adds section
        // cards (and any other content) on top of that. Older drafts may
        // still carry a `fixedDivider` node and `normalize` keeps them
        // working, but new documents start without one.
        let rootChildren = [hero.id]
        let nodes = Dictionary(uniqueKeysWithValues: [
            (hero.id, hero),
            (avatar.id, avatar),
            (name.id, name),
            (meta.id, meta),
            (bio.id, bio),
        ])

        var document = ProfileDocument(
            pageWidth: pageWidth,
            pageHeight: ProfileDocument.defaultPageHeight,
            pageBackgroundHex: ProfileDocument.defaultPageBackgroundHex,
            rootChildrenIDs: rootChildren,
            pages: [
                PageStyle(
                    height: ProfileDocument.defaultPageHeight,
                    backgroundHex: ProfileDocument.defaultPageBackgroundHex,
                    rootChildrenIDs: rootChildren
                )
            ],
            nodes: nodes
        )
        StructuredProfileLayout.normalize(&document)
        return document
    }
}
