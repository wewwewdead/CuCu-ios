import Foundation

/// Curated visual preset that the user picks from a sheet to repaint
/// the page chrome in one tap. Themes are a **one-shot setter**, not
/// a persisted document property — applying a theme writes into the
/// existing per-page fields (background hex / pattern key) and an
/// AppStorage default for newly-created text nodes, then forgets the
/// theme name. There is intentionally no `themeKey` on
/// `ProfileDocument` and no Codable migration: a theme is a starting
/// point, not a constraint, and persisting it would create the
/// "half-applied theme" UX problem we don't want to solve in v1.
///
/// The struct is deliberately not `Codable`. v1 ships with a
/// hard-coded preset list (see `presets`); a future v2 that wants
/// remote themes or persisted theme identity is a separate project
/// with its own schema migration.
struct CucuTheme: Identifiable, Hashable {
    let id: String
    let displayName: String
    let tagline: String
    /// Hex applied to every page's `backgroundHex` on apply.
    let pageBackgroundHex: String
    /// Pattern key written into `PageStyle.backgroundPatternKey`.
    /// `nil` means "no pattern" (Paper Press is the only such case).
    let pageBackgroundPatternKey: String?
    /// Default font for text nodes the user creates *after* applying
    /// the theme. Existing nodes are not touched.
    let defaultDisplayFont: NodeFontFamily
    /// Cherry / moss / cobalt — used by the picker tile preview as
    /// the divider stroke and link-pill border colour. Does not
    /// directly mutate any per-node colour on apply.
    let accentHex: String
    /// Raw value of a `NodeDividerStyleFamily` case. Used by the
    /// picker tile preview only — `applyTheme` does not retro-apply
    /// it to existing divider nodes (that would be a node-style
    /// rewrite, which the architecture decision excludes).
    let dividerStyle: String
}

extension CucuTheme {
    /// AppStorage key used by `ThemePickerSheet` and read by
    /// `CanvasMutator.addNode(.text)` to seed `NodeStyle.fontFamily`
    /// on freshly-created text nodes. Distinct from any document
    /// field — it's a device-level "next text node should use this
    /// face" preference.
    static let defaultFontStorageKey = "cucu.theme.defaultFont"

    /// Pure in-place apply — writes the theme's chrome onto every
    /// page of `document`, resets the per-image effect knobs, and
    /// records the theme's default font in `defaults` under
    /// `defaultFontStorageKey`. Independent of `CanvasMutator` so
    /// tests can exercise the contract without SwiftData / store
    /// plumbing; `CanvasMutator.applyTheme` wraps this with the
    /// persist + haptic side-effects.
    ///
    /// Deliberately does **not** mutate `backgroundImagePath` or
    /// any node style — see the architecture decision in the type
    /// header.
    func apply(to document: inout ProfileDocument,
               defaults: UserDefaults = .standard) {
        for index in document.pages.indices {
            document.pages[index].backgroundHex = pageBackgroundHex
            document.pages[index].backgroundPatternKey = pageBackgroundPatternKey
            document.pages[index].backgroundImageOpacity = nil
            document.pages[index].backgroundBlur = nil
            document.pages[index].backgroundVignette = nil
        }
        document.syncLegacyFieldsFromFirstPage()
        defaults.set(defaultDisplayFont.rawValue, forKey: CucuTheme.defaultFontStorageKey)
    }

    /// The seven curated themes from the design handoff
    /// (`themes.jsx`). Display names, taglines, and bg hexes are
    /// preserved verbatim; pattern keys map onto the existing
    /// `CanvasBackgroundPattern` cases (no substitutions needed —
    /// every pattern the mockup names exists in our enum); fonts
    /// map onto `NodeFontFamily` cases (`fraunces` was bundled in
    /// Phase 1, so all six display fonts the mockup references
    /// exist as native cases).
    static let presets: [CucuTheme] = [
        CucuTheme(
            id: "peachCottage",
            displayName: "Peach Cottage",
            tagline: "warm, soft, hand-stitched",
            pageBackgroundHex: "#F8E0D2",
            pageBackgroundPatternKey: "sparkles",
            defaultDisplayFont: .caprasimo,
            accentHex: "#B8324B",
            dividerStyle: "sparkleChain"
        ),
        CucuTheme(
            id: "mintGarden",
            displayName: "Mint Garden",
            tagline: "fresh, breezy, springtime",
            pageBackgroundHex: "#D8E9C9",
            pageBackgroundPatternKey: "meadow",
            defaultDisplayFont: .yesevaOne,
            accentHex: "#3F7A52",
            dividerStyle: "flowerChain"
        ),
        CucuTheme(
            id: "duskDiary",
            displayName: "Dusk Diary",
            tagline: "moody, midnight, intimate",
            pageBackgroundHex: "#221F2C",
            pageBackgroundPatternKey: "hazyDusk",
            defaultDisplayFont: .fraunces,
            accentHex: "#F5A6B5",
            dividerStyle: "starChain"
        ),
        CucuTheme(
            id: "butterZine",
            displayName: "Butter Zine",
            tagline: "punchy, photocopy, cut-and-paste",
            pageBackgroundHex: "#FBE9A8",
            pageBackgroundPatternKey: "paperGrid",
            defaultDisplayFont: .caprasimo,
            accentHex: "#1A140E",
            dividerStyle: "starChain"
        ),
        CucuTheme(
            id: "bubblegum",
            displayName: "Bubblegum",
            tagline: "sweet, candy, y2k",
            pageBackgroundHex: "#F5C9D4",
            pageBackgroundPatternKey: "hearts",
            defaultDisplayFont: .lobster,
            accentHex: "#B8324B",
            dividerStyle: "heartChain"
        ),
        CucuTheme(
            id: "paperPress",
            displayName: "Paper Press",
            tagline: "editorial, restrained, classic",
            pageBackgroundHex: "#FBF6E9",
            pageBackgroundPatternKey: nil,
            defaultDisplayFont: .yesevaOne,
            accentHex: "#1A140E",
            dividerStyle: "solid"
        ),
        CucuTheme(
            id: "oceanRoom",
            displayName: "Ocean Room",
            tagline: "cool, blue hour, watercolor",
            pageBackgroundHex: "#D9E5F5",
            pageBackgroundPatternKey: "sunset",
            defaultDisplayFont: .fraunces,
            accentHex: "#3A4D7C",
            dividerStyle: "sparkleChain"
        ),
    ]
}
