import CoreGraphics
import Foundation
import SwiftUI

/// Curated starting point a first-run user picks before they meet the
/// canvas editor. A template is *not* persisted on the document — like
/// `CucuTheme`, it's a one-shot setter that produces a seeded
/// `ProfileDocument` and then forgets its identity. The user can keep
/// editing freely after; nothing in the data model treats a templated
/// profile as different from a hand-built one.
///
/// All visuals are bundled (theme hexes + preset trees + SF Symbols)
/// so a fresh signed-out launch with no network can still pick any
/// vibe — important for the offline-first contract `RootView.BuildTab`
/// already enforces.
enum ProfileTemplate: String, CaseIterable, Identifiable {
    case kpopCard
    case animeIntro
    case softDiary
    case myspaceRoom
    case writerPage
    case gamerCard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kpopCard:    return "K-Pop Card"
        case .animeIntro:  return "Anime Intro"
        case .softDiary:   return "Soft Diary"
        case .myspaceRoom: return "MySpace Room"
        case .writerPage:  return "Writer Page"
        case .gamerCard:   return "Gamer Card"
        }
    }

    /// Short, emotional one-liner shown under the title on the picker
    /// card. Kept under ~60 chars so it never truncates on compact
    /// devices.
    var tagline: String {
        switch self {
        case .kpopCard:    return "Stan account energy. Fancams welcome."
        case .animeIntro:  return "Ratings, watchlists, late-night feels."
        case .softDiary:   return "Pages of small thoughts and quiet days."
        case .myspaceRoom: return "Top 8, blinkies, and a glittery wall."
        case .writerPage:  return "An editorial page for what you're writing."
        case .gamerCard:   return "Now playing, all-time, and the queue."
        }
    }

    /// SF Symbol for the picker card's hero glyph. Picked from the
    /// shared icon set so we don't ship per-template artwork in v1.
    var iconSymbol: String {
        switch self {
        case .kpopCard:    return "music.mic"
        case .animeIntro:  return "sparkles.tv"
        case .softDiary:   return "book.pages"
        case .myspaceRoom: return "heart.fill"
        case .writerPage:  return "text.book.closed"
        case .gamerCard:   return "gamecontroller.fill"
        }
    }

    /// Theme that paints the page chrome (background hex, pattern,
    /// default font for new text nodes). Templates piggyback on the
    /// existing `CucuTheme` catalog so the visual vocabulary stays
    /// consistent with the theme picker the user can change later.
    var theme: CucuTheme {
        switch self {
        case .kpopCard:    return CucuTheme.preset(id: "bubblegum")
        case .animeIntro:  return CucuTheme.preset(id: "duskDiary")
        case .softDiary:   return CucuTheme.preset(id: "peachCottage")
        case .myspaceRoom: return CucuTheme.preset(id: "butterZine")
        case .writerPage:  return CucuTheme.preset(id: "paperPress")
        case .gamerCard:   return CucuTheme.preset(id: "oceanRoom")
        }
    }

    /// Preview swatch shown on the template card. Pulled from the
    /// theme so the picker tile and the seeded canvas land on the
    /// exact same color the user previewed.
    var previewBackgroundHex: String { theme.pageBackgroundHex }
    var previewAccentHex: String { theme.accentHex }

    /// Hero copy that pre-fills the structured-profile header so the
    /// user sees a populated example rather than the generic
    /// "Display Name / @username / Short bio" placeholders. They can
    /// overwrite each field freely after.
    fileprivate var heroDisplayName: String {
        switch self {
        case .kpopCard:    return "your bias's biggest fan"
        case .animeIntro:  return "currently rewatching everything"
        case .softDiary:   return "a quiet little corner"
        case .myspaceRoom: return "online since forever"
        case .writerPage:  return "drafting in public"
        case .gamerCard:   return "main quest still in progress"
        }
    }

    fileprivate var heroBio: String {
        switch self {
        case .kpopCard:    return "comebacks, fancams, and group highs."
        case .animeIntro:  return "thoughts on every episode, eventually."
        case .softDiary:   return "small entries from a slow life."
        case .myspaceRoom: return "leave a comment in the wall below."
        case .writerPage:  return "stories, essays, and notes-in-progress."
        case .gamerCard:   return "co-op friendly. add me on the platforms below."
        }
    }

    fileprivate var heroMeta: String { "@yourname" }

    /// Section presets stacked under the hero, in order. Reuses the
    /// section trees from `CanvasPresetBuilder` so the canvas knows
    /// exactly how to lay them out — no template-specific layout
    /// path. Templates differ in *which* sections they include and
    /// in the page chrome, not in section geometry.
    fileprivate var sections: [CanvasSectionPreset] {
        switch self {
        case .kpopCard:    return [.interests, .journal]
        case .animeIntro:  return [.bulletin, .journal]
        case .softDiary:   return [.journal, .bulletin]
        case .myspaceRoom: return [.interests, .wall]
        case .writerPage:  return [.bulletin, .journal]
        case .gamerCard:   return [.interests, .bulletin]
        }
    }

    /// Build a fully-seeded `ProfileDocument` for this template. The
    /// document is structurally identical to anything the user could
    /// have built by hand: hero + section cards + page chrome. No
    /// remote assets, no local image paths — every default the user
    /// could remove later, removable; every default they could keep,
    /// kept.
    @MainActor
    func makeDocument(defaults: UserDefaults = .standard) -> ProfileDocument {
        var document = ProfileDocument.structuredProfileBlank

        // Page chrome first so adaptive hero text colors (computed by
        // `normalize`) sample the new background luminance, not the
        // blank's default cream.
        theme.apply(to: &document, defaults: defaults)

        applyHeroCopy(to: &document)

        // Section presets land under the hero in the order listed.
        // Each preset gets wrapped in a structured Section Card the
        // same way `CanvasPresetBuilder.addSectionPreset` does at the
        // root level — that path is the canonical "user added a
        // section card" shape, so a templated profile is
        // indistinguishable from a hand-built one once seeded.
        let pageIndex = StructuredProfileLayout.primaryPageIndex(in: document) ?? 0
        for preset in sections {
            insertSectionAtRoot(preset, into: &document, pageIndex: pageIndex)
        }

        StructuredProfileLayout.normalize(&document)
        return document
    }

    private func applyHeroCopy(in document: inout ProfileDocument, role: CanvasNodeRole, text: String) {
        guard let id = StructuredProfileLayout.roleID(role, in: document),
              var node = document.nodes[id] else { return }
        node.content.text = text
        node.content.removeInvalidTextStyleSpans(afterTextChange: text)
        document.nodes[id] = node
    }

    private func applyHeroCopy(to document: inout ProfileDocument) {
        applyHeroCopy(in: &document, role: .profileName, text: heroDisplayName)
        applyHeroCopy(in: &document, role: .profileMeta, text: heroMeta)
        applyHeroCopy(in: &document, role: .profileBio,  text: heroBio)
    }

    @MainActor
    private func insertSectionAtRoot(_ preset: CanvasSectionPreset,
                                     into document: inout ProfileDocument,
                                     pageIndex: Int) {
        var tree = CanvasPresetBuilder.makeSectionPreset(
            preset,
            parentID: nil,
            document: document,
            rootPageIndex: pageIndex
        )
        let cardHeight = max(StructuredProfileLayout.cardDefaultHeight, tree.node.frame.height)
        var card = StructuredProfileLayout.makeSectionCard(
            in: document,
            pageIndex: pageIndex,
            height: cardHeight,
            name: tree.node.name ?? preset.title
        )
        card.style = tree.node.style
        card.role = .sectionCard
        card.resizeBehavior = .verticalOnly
        tree.node = card
        CanvasPresetBuilder.insertPresetTree(tree, under: nil, onPage: pageIndex, into: &document)
    }
}

extension CucuTheme {
    /// Lookup helper used by `ProfileTemplate` so the template list
    /// declares its theme by stable id rather than holding a copy of
    /// the `CucuTheme` value. Falls back to the first preset when an
    /// id no longer exists (would only happen if a future cleanup
    /// removed an id this enum still references — preferable to
    /// crashing the picker on a missing dictionary key).
    static func preset(id: String) -> CucuTheme {
        presets.first(where: { $0.id == id }) ?? presets[0]
    }
}
