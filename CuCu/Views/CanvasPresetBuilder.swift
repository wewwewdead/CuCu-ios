import CoreGraphics
import Foundation
import SwiftUI

/// Pure-function namespace for the section-preset construction code
/// that previously lived inside `ProfileCanvasBuilderView`. No stored
/// state — each function takes everything it needs as a parameter so
/// the same call from a unit test would produce the same tree.
///
/// `addSectionPreset` and `insertPresetTree` are mutations and live
/// here because the spec calls for them in the preset-builder block;
/// they take the document/selection bindings as parameters and so
/// remain free of instance state.
@MainActor
enum CanvasPresetBuilder {
    /// Lightweight tree describing a preset: a parent `CanvasNode`
    /// plus the recursive children that should be inserted under it.
    struct PresetNodeTree {
        var node: CanvasNode
        var children: [PresetNodeTree] = []
    }

    /// Top-level entry point. Builds the preset tree, inserts it under
    /// the selected container (or page root), updates selection,
    /// persists, and fires the soft haptic — matching the original
    /// inline behavior exactly.
    static func addSectionPreset(_ preset: CanvasSectionPreset,
                                 document: Binding<ProfileDocument>,
                                 selectedID: Binding<UUID?>,
                                 draft: ProfileDraft,
                                 store: DraftStore,
                                 rootPageIndex: Int) {
        let parentID: UUID? = {
            if let sid = selectedID.wrappedValue,
               document.wrappedValue.nodes[sid]?.type == .container {
                return sid
            }
            return nil
        }()
        let tree = makeSectionPreset(
            preset,
            parentID: parentID,
            document: document.wrappedValue,
            rootPageIndex: rootPageIndex
        )
        insertPresetTree(tree, under: parentID, onPage: rootPageIndex, into: &document.wrappedValue)
        selectedID.wrappedValue = tree.node.id
        store.updateDocument(draft, document: document.wrappedValue)
        CucuHaptics.soft()
    }

    /// Recursive insert that uses `ProfileDocument.insert` for each
    /// node so the parent index stays in sync as the tree is unrolled.
    static func insertPresetTree(_ tree: PresetNodeTree,
                                 under parentID: UUID?,
                                 onPage pageIndex: Int,
                                 into document: inout ProfileDocument) {
        document.insert(tree.node, under: parentID, onPage: pageIndex)
        for child in tree.children {
            insertPresetTree(child, under: tree.node.id, onPage: pageIndex, into: &document)
        }
    }

    static func makeSectionPreset(_ preset: CanvasSectionPreset,
                                  parentID: UUID?,
                                  document: ProfileDocument,
                                  rootPageIndex: Int = 0) -> PresetNodeTree {
        let width = presetWidth(parentID: parentID, document: document)
        let origin = presetOrigin(parentID: parentID, document: document, rootPageIndex: rootPageIndex)

        switch preset {
        case .hero:      return makeHeroPreset(origin: origin, width: width)
        case .interests: return makeInterestsPreset(origin: origin, width: width)
        case .wall:      return makeWallPreset(origin: origin, width: width)
        case .journal:   return makeJournalPreset(origin: origin, width: width)
        case .bulletin:  return makeBulletinPreset(origin: origin, width: width)
        }
    }

    static func presetWidth(parentID: UUID?, document: ProfileDocument) -> Double {
        if let parentID, let parent = document.nodes[parentID] {
            return max(220, min(parent.frame.width - 32, 326))
        }
        return 326
    }

    static func presetOrigin(parentID: UUID?, document: ProfileDocument, rootPageIndex: Int = 0) -> CGPoint {
        if parentID != nil {
            return CGPoint(x: 16, y: 16)
        }

        let pageIndex = document.pages.indices.contains(rootPageIndex) ? rootPageIndex : max(0, document.pages.count - 1)
        let bottom = document.children(of: nil, onPage: pageIndex)
            .compactMap { document.nodes[$0] }
            .map { $0.frame.y + $0.frame.height }
            .max() ?? 56
        return CGPoint(x: 32, y: max(80, bottom + 24))
    }

    // MARK: - Section presets

    private static func makeHeroPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let textX: Double = 124
        let rightWidth = max(128, width - textX - 16)
        let section = sectionContainer(
            name: "Hero Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 250),
            background: "#FFF7E6",
            border: "#E9C46A"
        )

        return PresetNodeTree(node: section, children: [
            imagePlaceholderTree(x: 16, y: 22, side: 92),
            textTree("Display Name", x: textX, y: 24, width: rightWidth, height: 34, size: 24, weight: .bold),
            textTree("Short bio about your vibe, projects, links, or current obsession.", x: textX, y: 66, width: rightWidth, height: 66, size: 14, color: "#3A3024"),
            textTree("profile badge", x: textX, y: 148, width: min(156, rightWidth), height: 34, size: 14, weight: .semibold, color: "#FFFFFF", background: "#D85C7A", cornerRadius: 17, alignment: .center),
            textTree("Make it yours", x: 16, y: 154, width: 92, height: 32, size: 13, weight: .medium, color: "#7C5B19", background: "#FFE9AD", cornerRadius: 16, alignment: .center)
        ])
    }

    private static func makeInterestsPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Interests Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 188),
            background: "#F1FBF7",
            border: "#8BD8BD"
        )
        let tags = ["music", "coding", "anime", "design", "retro", "friends"]
        let chipWidth = max(78, min(92, (width - 44) / 3))
        let chipHeight: Double = 32
        let chipGap: Double = 8
        let chipTrees = tags.enumerated().map { index, title in
            let row = Double(index / 3)
            let col = Double(index % 3)
            return textTree(
                title,
                x: 16 + col * (chipWidth + chipGap),
                y: 58 + row * (chipHeight + chipGap),
                width: chipWidth,
                height: chipHeight,
                size: 13,
                weight: .semibold,
                color: "#185A43",
                background: "#D8F3E8",
                cornerRadius: 16,
                alignment: .center
            )
        }

        return PresetNodeTree(node: section, children: [
            textTree("Interests", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#123B2D")
        ] + chipTrees)
    }

    private static func makeWallPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Wall Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 232),
            background: "#F5F1FF",
            border: "#B8A4F4"
        )
        let messageCard = containerTree(
            name: "Sample Message",
            frame: frame(16, 112, width - 32, 82),
            background: "#FFFFFF",
            cornerRadius: 12,
            border: "#E2DAFF",
            children: [
                textTree("Visitor", x: 12, y: 10, width: width - 56, height: 22, size: 14, weight: .bold, color: "#49327A"),
                textTree("Love this layout. The colors feel very you.", x: 12, y: 36, width: width - 56, height: 34, size: 13, color: "#3B3152")
            ]
        )

        return PresetNodeTree(node: section, children: [
            textTree("Wall", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#382062"),
            textTree("Leave a message...", x: 16, y: 58, width: width - 32, height: 38, size: 14, color: "#6D647C", background: "#FFFFFF", cornerRadius: 10),
            messageCard
        ])
    }

    private static func makeJournalPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Journal Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 298),
            background: "#FFF4F1",
            border: "#F2A38D"
        )
        let cardData = [
            ("Today I redesigned my profile", "A quick note about the new colors."),
            ("Favorite links this week", "Three things worth saving."),
            ("Small update", "Still building, still changing.")
        ]
        let cards = cardData.enumerated().map { index, item in
            let y = 58 + Double(index) * 72
            return containerTree(
                name: "Journal Card",
                frame: frame(16, y, width - 32, 62),
                background: "#FFFFFF",
                cornerRadius: 12,
                border: "#F6D1C7",
                children: [
                    textTree(item.0, x: 12, y: 8, width: width - 56, height: 24, size: 14, weight: .bold, color: "#693226"),
                    textTree(item.1, x: 12, y: 34, width: width - 56, height: 20, size: 12, color: "#7A5B54")
                ]
            )
        }

        return PresetNodeTree(node: section, children: [
            textTree("Latest Journals", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#60281E")
        ] + cards)
    }

    private static func makeBulletinPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Bulletin Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 178),
            background: "#EFF7FF",
            border: "#91BEEB"
        )

        return PresetNodeTree(node: section, children: [
            textTree("Bulletins", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#143C66"),
            textTree("Status update: changing the whole profile again because the old one did not pass the vibe check.", x: 16, y: 58, width: width - 32, height: 76, size: 14, color: "#1F3F5F", background: "#FFFFFF", cornerRadius: 12),
            textTree("local placeholder", x: 16, y: 142, width: 134, height: 24, size: 12, weight: .medium, color: "#2E5E91", background: "#D8EAFC", cornerRadius: 12, alignment: .center)
        ])
    }

    // MARK: - Tree builders

    private static func sectionContainer(name: String,
                                         frame: NodeFrame,
                                         background: String,
                                         border: String) -> CanvasNode {
        CanvasNode(
            type: .container,
            name: name,
            frame: frame,
            style: NodeStyle(
                backgroundColorHex: background,
                cornerRadius: 16,
                borderWidth: 1,
                borderColorHex: border
            )
        )
    }

    private static func containerTree(name: String,
                                      frame: NodeFrame,
                                      background: String,
                                      cornerRadius: Double,
                                      border: String,
                                      children: [PresetNodeTree]) -> PresetNodeTree {
        PresetNodeTree(
            node: CanvasNode(
                type: .container,
                name: name,
                frame: frame,
                style: NodeStyle(
                    backgroundColorHex: background,
                    cornerRadius: cornerRadius,
                    borderWidth: 1,
                    borderColorHex: border
                )
            ),
            children: children
        )
    }

    private static func textTree(_ text: String,
                                 x: Double,
                                 y: Double,
                                 width: Double,
                                 height: Double,
                                 size: Double,
                                 weight: NodeFontWeight = .regular,
                                 color: String = "#1C1C1E",
                                 background: String? = nil,
                                 cornerRadius: Double = 0,
                                 alignment: NodeTextAlignment = .leading) -> PresetNodeTree {
        PresetNodeTree(
            node: CanvasNode(
                type: .text,
                frame: frame(x, y, width, height),
                style: NodeStyle(
                    backgroundColorHex: background,
                    cornerRadius: cornerRadius,
                    borderWidth: 0,
                    borderColorHex: nil,
                    fontFamily: .system,
                    fontWeight: weight,
                    fontSize: size,
                    textColorHex: color,
                    textAlignment: alignment
                ),
                content: NodeContent(text: text)
            )
        )
    }

    private static func imagePlaceholderTree(x: Double, y: Double, side: Double) -> PresetNodeTree {
        PresetNodeTree(
            node: CanvasNode(
                type: .image,
                frame: frame(x, y, side, side),
                style: NodeStyle(
                    backgroundColorHex: "#F2F2F7",
                    cornerRadius: side / 2,
                    borderWidth: 2,
                    borderColorHex: "#FFFFFF",
                    imageFit: .fill,
                    clipShape: .circle
                ),
                content: NodeContent()
            )
        )
    }

    private static func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NodeFrame {
        NodeFrame(x: x, y: y, width: width, height: height)
    }
}
