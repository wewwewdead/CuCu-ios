import CoreGraphics
import Foundation

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
        roleID(.profileHero, in: document) != nil &&
        roleID(.fixedDivider, in: document) != nil
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
              let heroID = roleID(.profileHero, in: document),
              let dividerID = roleID(.fixedDivider, in: document) else { return }

        let pageWidth = document.pageWidth
        let cardWidth = max(160, pageWidth - horizontalMargin * 2)

        if var hero = document.nodes[heroID] {
            hero.frame = NodeFrame(x: 0, y: 0, width: pageWidth, height: heroHeight)
            hero.resizeBehavior = .locked
            hero.role = .profileHero
            document.nodes[heroID] = hero
        }

        normalizeHeroChildren(in: &document, heroID: heroID)

        let dividerY = heroHeight + dividerTopSpacing
        if var divider = document.nodes[dividerID] {
            divider.frame = NodeFrame(
                x: horizontalMargin,
                y: dividerY,
                width: cardWidth,
                height: dividerHeight
            )
            divider.role = .fixedDivider
            divider.resizeBehavior = .locked
            document.nodes[dividerID] = divider
        }

        var y = dividerY + dividerHeight + cardSpacing
        let rootIDs = document.pages[pageIndex].rootChildrenIDs
        let cards = rootIDs.filter { document.nodes[$0]?.role == .sectionCard }
        for cardID in cards {
            guard var card = document.nodes[cardID] else { continue }
            card.frame.x = horizontalMargin
            card.frame.y = y
            card.frame.width = cardWidth
            card.frame.height = max(cardMinimumHeight, card.frame.height)
            card.resizeBehavior = .verticalOnly
            document.nodes[cardID] = card
            y = card.frame.y + card.frame.height + cardSpacing
        }

        let others = rootIDs.filter { id in
            guard id != heroID, id != dividerID else { return false }
            return document.nodes[id]?.role != .sectionCard
        }
        document.pages[pageIndex].rootChildrenIDs = [heroID, dividerID] + cards + others
        document.pages[pageIndex].height = max(ProfileDocument.defaultPageHeight, y + bottomPadding)
        document.syncLegacyFieldsFromFirstPage()
    }

    private static func normalizeHeroChildren(in document: inout ProfileDocument, heroID: UUID) {
        let pageWidth = document.pageWidth
        let textWidth = max(160, pageWidth - 48)
        let frames: [CanvasNodeRole: NodeFrame] = [
            .profileAvatar: NodeFrame(x: 24, y: 84, width: 100, height: 100),
            .profileName: NodeFrame(x: 24, y: 196, width: textWidth, height: 40),
            .profileMeta: NodeFrame(x: 24, y: 236, width: textWidth, height: 24),
            .profileBio: NodeFrame(x: 24, y: 262, width: textWidth, height: 48),
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

    private static func dividerBottom(in document: ProfileDocument) -> Double {
        if let dividerID = roleID(.fixedDivider, in: document),
           let divider = document.nodes[dividerID] {
            return divider.frame.y + divider.frame.height
        }
        return heroHeight + dividerTopSpacing + dividerHeight
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

        let avatar = CanvasNode(
            type: .image,
            frame: NodeFrame(x: 24, y: 84, width: 100, height: 100),
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
            frame: NodeFrame(x: 24, y: 196, width: pageWidth - 48, height: 40),
            role: .profileName,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .fraunces,
                fontWeight: .bold,
                fontSize: 30,
                textColorHex: "#1A140E",
                textAlignment: .leading
            ),
            content: NodeContent(text: "Display Name")
        )

        let meta = CanvasNode(
            type: .text,
            frame: NodeFrame(x: 24, y: 236, width: pageWidth - 48, height: 24),
            role: .profileMeta,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .system,
                fontWeight: .semibold,
                fontSize: 14,
                textColorHex: "#7A6A58",
                textAlignment: .leading
            ),
            content: NodeContent(text: "@username")
        )

        let bio = CanvasNode(
            type: .text,
            frame: NodeFrame(x: 24, y: 262, width: pageWidth - 48, height: 48),
            role: .profileBio,
            resizeBehavior: .locked,
            style: NodeStyle(
                backgroundColorHex: nil,
                fontFamily: .system,
                fontWeight: .regular,
                fontSize: 15,
                textColorHex: "#3A3024",
                textAlignment: .leading,
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

        var divider = CanvasNode.defaultDivider(
            at: CGPoint(
                x: StructuredProfileLayout.horizontalMargin,
                y: StructuredProfileLayout.heroHeight + StructuredProfileLayout.dividerTopSpacing
            ),
            size: CGSize(
                width: pageWidth - StructuredProfileLayout.horizontalMargin * 2,
                height: StructuredProfileLayout.dividerHeight
            )
        )
        divider.name = "Profile Divider"
        divider.role = .fixedDivider
        divider.resizeBehavior = .locked

        let rootChildren = [hero.id, divider.id]
        let nodes = Dictionary(uniqueKeysWithValues: [
            (hero.id, hero),
            (avatar.id, avatar),
            (name.id, name),
            (meta.id, meta),
            (bio.id, bio),
            (divider.id, divider),
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
