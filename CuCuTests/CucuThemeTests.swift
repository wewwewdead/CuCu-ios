//
//  CucuThemeTests.swift
//  CuCuTests
//
//  Locks the theme-apply contract from the design handoff:
//  - paints every page's bg / pattern
//  - resets per-image effect knobs (opacity / blur / vignette)
//  - leaves backgroundImagePath alone
//  - leaves existing node styles alone
//  - writes the AppStorage default-font key
//
//  Tests exercise the pure `CucuTheme.apply(to:defaults:)` helper so
//  no SwiftData / mutator plumbing is needed. The `CanvasMutator.applyTheme`
//  wrapper is a thin store + haptic shell over this same call.
//

import Testing
import CoreGraphics
import Foundation
@testable import CuCu

private func makeTextNode(font: NodeFontFamily) -> CanvasNode {
    var node = CanvasNode(
        type: .text,
        frame: NodeFrame(x: 0, y: 0, width: 200, height: 40),
        content: NodeContent(text: "hello")
    )
    node.style.fontFamily = font
    return node
}

/// Document with three pages so the apply walks more than just
/// the root, and one text node on page 0 so the "doesn't mutate
/// node styles" assertion has something to bite.
private func makeMultipageDocument(textFont: NodeFontFamily = .caveat) -> ProfileDocument {
    var doc = ProfileDocument()
    doc.pages.append(PageStyle(height: 1000, backgroundHex: "#FFFFFF"))
    doc.pages.append(PageStyle(height: 1000, backgroundHex: "#000000"))

    let node = makeTextNode(font: textFont)
    doc.insert(node, under: nil, onPage: 0)
    return doc
}

/// Suite-scoped UserDefaults so tests don't bleed into each other or
/// the device's `.standard` defaults. Each test passes a fresh
/// instance keyed on a random suite name and removes it on completion.
private func ephemeralDefaults() -> UserDefaults {
    let suite = "CucuThemeTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

struct CucuThemeApplyTests {

    @Test func applyThemeReplacesAllPageBackgrounds() throws {
        var doc = makeMultipageDocument()
        let theme = CucuTheme.presets.first { $0.id == "peachCottage" }!
        let defaults = ephemeralDefaults()

        theme.apply(to: &doc, defaults: defaults)

        #expect(doc.pages.count >= 2)
        for page in doc.pages {
            #expect(page.backgroundHex == theme.pageBackgroundHex)
            #expect(page.backgroundPatternKey == theme.pageBackgroundPatternKey)
        }
    }

    @Test func applyThemeResetsImageEffectKnobs() throws {
        var doc = makeMultipageDocument()
        // Dial opacity / blur / vignette on each page so we can
        // confirm they all clear, not just the first.
        for index in doc.pages.indices {
            doc.pages[index].backgroundImageOpacity = 0.3
            doc.pages[index].backgroundBlur = 12
            doc.pages[index].backgroundVignette = 0.6
        }
        let theme = CucuTheme.presets.first { $0.id == "duskDiary" }!

        theme.apply(to: &doc, defaults: ephemeralDefaults())

        for page in doc.pages {
            #expect(page.backgroundImageOpacity == nil)
            #expect(page.backgroundBlur == nil)
            #expect(page.backgroundVignette == nil)
        }
    }

    @Test func applyThemePreservesBackgroundImagePath() throws {
        var doc = makeMultipageDocument()
        let preservedPath = "drafts/abc/page_background.jpg"
        for index in doc.pages.indices {
            doc.pages[index].backgroundImagePath = preservedPath
        }
        let theme = CucuTheme.presets.first { $0.id == "bubblegum" }!

        theme.apply(to: &doc, defaults: ephemeralDefaults())

        for page in doc.pages {
            #expect(page.backgroundImagePath == preservedPath)
            // …and the bg color / pattern *did* repaint, so the
            // preservation isn't masking a no-op apply.
            #expect(page.backgroundHex == theme.pageBackgroundHex)
            #expect(page.backgroundPatternKey == theme.pageBackgroundPatternKey)
        }
    }

    @Test func applyThemeDoesNotMutateNodeStyles() throws {
        // The text node uses `.caveat` — every theme's
        // `defaultDisplayFont` differs from `.caveat`, so a stray
        // walk-and-rewrite would visibly flip this value. Pinning
        // it to that specific case is the cheap way to keep the
        // assertion meaningful even if a future theme adds caveat.
        var doc = makeMultipageDocument(textFont: .caveat)
        let theme = CucuTheme.presets.first { $0.id == "paperPress" }!
        // Capture every node style upfront.
        let beforeStyles = doc.nodes.mapValues(\.style)

        theme.apply(to: &doc, defaults: ephemeralDefaults())

        for (id, style) in beforeStyles {
            #expect(doc.nodes[id]?.style == style,
                    "Theme apply must not rewrite node \(id)'s style")
        }
        // And the specific font we seeded survives unchanged —
        // belt-and-braces against an `==` that pretends to compare
        // but actually short-circuits on identity.
        let textNodes = doc.nodes.values.filter { $0.type == .text }
        #expect(textNodes.allSatisfy { $0.style.fontFamily == .caveat })
    }

    @Test func applyThemeUpdatesDefaultFontAppStorage() throws {
        var doc = makeMultipageDocument()
        let theme = CucuTheme.presets.first { $0.id == "duskDiary" }!
        let defaults = ephemeralDefaults()

        theme.apply(to: &doc, defaults: defaults)

        // Stored as the rawValue of the enum case; readers
        // (CanvasMutator.themeDefaultFont) reconstruct the enum.
        #expect(
            defaults.string(forKey: CucuTheme.defaultFontStorageKey)
                == theme.defaultDisplayFont.rawValue
        )
        // Sanity: the persisted string round-trips back to the
        // same case via the model's failable initializer.
        let raw = defaults.string(forKey: CucuTheme.defaultFontStorageKey)
        #expect(raw.flatMap(NodeFontFamily.init(rawValue:)) == theme.defaultDisplayFont)
    }
}
