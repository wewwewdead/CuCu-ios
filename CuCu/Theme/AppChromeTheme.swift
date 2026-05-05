import SwiftUI

/// Per-device "what color paper is the room painted in" preference for
/// the three social-stack pages (Feed, Thread, Explore) and the tab bar
/// that bridges them. Distinct from `CucuTheme`, which only repaints
/// the canvas-builder pages — `AppChromeTheme` repaints the *app
/// chrome* around the user's content while leaving the cream
/// `cucuCard` surfaces alone, so each post row reads as a paper
/// artifact pinned onto the chosen backdrop.
///
/// The cream tokens (`cucuPaper`, `cucuCard`) are deliberately *not*
/// re-pointed: the Build tab, modal sheets, inspector panels, and the
/// floating cards inside feed rows depend on the editorial-cream
/// constant. Only the three social pages — and only their on-page
/// surfaces, not their card interiors — read from this type.
struct AppChromeTheme: Identifiable, Hashable, Sendable {
    /// Whether the theme reads as a light room or a dark one.
    /// Drives the tab-bar `colorScheme` override (so SwiftUI paints
    /// system glyphs in the right register) and chooses between
    /// `Color.black`-derived and `Color.white`-derived hairlines so a
    /// dark backdrop never tries to draw a black-on-black rule.
    enum Mood: String, Hashable, Sendable {
        case light, dark
    }

    let id: String
    let displayName: String
    /// Two-or-three-word descriptor shown under the swatch tile.
    /// Editorial flavor, not functional copy — "linen blank, cool
    /// undertone" rather than "off-white background".
    let tagline: String
    let mood: Mood
    /// The page color itself — what `Color.cucuPaper` used to be on
    /// these surfaces. Also used as the navigation/tab bar fill so
    /// the chrome reads as one continuous sheet of paper.
    let pageRGB: UInt32
    /// Primary text painted *directly* on the page (titles, the
    /// Compose pencil glyph, the active filter chip background).
    /// Inside cards, callers stay on `cucuInk` because the card itself
    /// is cream regardless of the chosen backdrop.
    let inkPrimaryRGB: UInt32
    /// One step quieter than primary — the editorial subtitle under
    /// the masthead title, the active row text inside chips.
    let inkMutedRGB: UInt32
    /// Two steps quieter — printer's-mark spec lines, "0 posts" hints,
    /// caption rows under thread parents.
    let inkFadedRGB: UInt32
    /// Hairline-rule opacity. Multiplied against `Color.black` on light
    /// themes and `Color.white` on dark so a dark backdrop renders the
    /// same separator as a faint highlight, not an invisible shadow.
    let ruleOpacity: Double
    /// Small accent — the tiny dot in spec-line bullets and the active
    /// tile's border in the picker. Reads as the room's "ink colour"
    /// for marks the user makes on the paper.
    let accentRGB: UInt32

    /// The cream-vs-dark surface that floats above the page — feed
    /// rows, builder chrome pills, skeleton placeholders. Light
    /// themes paint cream/white cards (one step brighter than the
    /// page); dark themes paint elevated dark surfaces (one step
    /// lighter than the page) so the card lifts off the room without
    /// fighting it.
    let cardRGB: UInt32
    /// Stroke around the card — opacity-only token, blended against
    /// either black (light themes) or white (dark themes) so a single
    /// `cardStrokeOpacity` value reads as a faint shadow on light
    /// themes and a faint highlight on dark themes.
    let cardStrokeOpacity: Double
    /// Primary text *inside* a card. Dark themes invert this to a
    /// cream so dark cards stay readable; light themes keep deep ink.
    let cardInkPrimaryRGB: UInt32
    /// One step quieter — handles, in-card subtitle, the time-ago row
    /// inside post headers.
    let cardInkMutedRGB: UInt32
    /// Two steps quieter — captions, "0 likes" hints, the spec-line
    /// glyphs along the bottom of a row.
    let cardInkFadedRGB: UInt32

    var pageColor: Color    { Color(appChromeRGB: pageRGB) }
    var inkPrimary: Color   { Color(appChromeRGB: inkPrimaryRGB) }
    var inkMuted: Color     { Color(appChromeRGB: inkMutedRGB) }
    var inkFaded: Color     { Color(appChromeRGB: inkFadedRGB) }
    var accent: Color       { Color(appChromeRGB: accentRGB) }

    var cardColor: Color        { Color(appChromeRGB: cardRGB) }
    var cardInkPrimary: Color   { Color(appChromeRGB: cardInkPrimaryRGB) }
    var cardInkMuted: Color     { Color(appChromeRGB: cardInkMutedRGB) }
    var cardInkFaded: Color     { Color(appChromeRGB: cardInkFadedRGB) }

    /// Card stroke colour — flips polarity by mood the same way
    /// `rule` does for the on-page hairline.
    var cardStroke: Color {
        mood == .dark
            ? Color.white.opacity(cardStrokeOpacity)
            : Color.black.opacity(cardStrokeOpacity)
    }

    /// Hairline rule color — flips polarity by mood so the same
    /// `ruleOpacity` value reads as a faint shadow on light themes and
    /// a faint highlight on dark themes.
    var rule: Color {
        mood == .dark
            ? Color.white.opacity(ruleOpacity)
            : Color.black.opacity(ruleOpacity)
    }

    var isDark: Bool { mood == .dark }

    /// `colorScheme` to inject when the theme is active. SwiftUI uses
    /// this to pick light- or dark-flavored variants of system glyphs
    /// (the tab bar icons, the navigation back chevron) so a midnight
    /// backdrop doesn't end up with black system glyphs that vanish.
    var preferredColorScheme: ColorScheme {
        mood == .dark ? .dark : .light
    }
}

/// Self-contained hex literal helper. Kept private + distinctly named
/// from the project-wide `Color(hex: String)` so the chrome theme is
/// independent of file-include order during indexing — the same
/// pattern `CucuDesignSystem.swift` uses for its palette tokens.
private extension Color {
    init(appChromeRGB rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension AppChromeTheme {
    /// Default theme on first launch. Snow is intentionally NOT cream —
    /// the legacy `cucuPaper` warmth is preserved as the opt-in `bone`
    /// preset for users who liked it, but a fresh install lands on a
    /// clean modern white surface.
    static let snow = AppChromeTheme(
        id: "snow",
        displayName: "Snow",
        tagline: "clean, modern, untouched",
        mood: .light,
        pageRGB: 0xFAFAFA,
        inkPrimaryRGB: 0x1A140E,
        inkMutedRGB: 0x4A3F31,
        inkFadedRGB: 0x8C8067,
        ruleOpacity: 0.12,
        accentRGB: 0xB22A4A,
        cardRGB: 0xFFFFFF,
        cardStrokeOpacity: 0.10,
        cardInkPrimaryRGB: 0x14110D,
        cardInkMutedRGB: 0x4A3F31,
        cardInkFadedRGB: 0x8C8067
    )

    /// Eight curated paper stocks: five lights, three darks. Sized to
    /// fit a 2-column picker grid as four rows. Order is intentional —
    /// lightest to darkest reading top-to-bottom, left-to-right — so the
    /// tile grid reads like a tonal ramp.
    static let presets: [AppChromeTheme] = [
        snow,
        AppChromeTheme(
            id: "linen",
            displayName: "Linen",
            tagline: "cool, off-white, neutral",
            mood: .light,
            pageRGB: 0xECEEF1,
            inkPrimaryRGB: 0x1B1F26,
            inkMutedRGB: 0x3F4651,
            inkFadedRGB: 0x828893,
            ruleOpacity: 0.14,
            accentRGB: 0x3B6BCC,
            cardRGB: 0xF8FAFC,
            cardStrokeOpacity: 0.10,
            cardInkPrimaryRGB: 0x1B1F26,
            cardInkMutedRGB: 0x3F4651,
            cardInkFadedRGB: 0x828893
        ),
        AppChromeTheme(
            id: "sage",
            displayName: "Sage",
            tagline: "garden, breathing, daylight",
            mood: .light,
            pageRGB: 0xE1EAE0,
            inkPrimaryRGB: 0x1F2A20,
            inkMutedRGB: 0x3E5240,
            inkFadedRGB: 0x788275,
            ruleOpacity: 0.16,
            accentRGB: 0x4A7D4D,
            cardRGB: 0xF1F6EE,
            cardStrokeOpacity: 0.12,
            cardInkPrimaryRGB: 0x1F2A20,
            cardInkMutedRGB: 0x3E5240,
            cardInkFadedRGB: 0x788275
        ),
        AppChromeTheme(
            id: "lilac",
            displayName: "Lilac",
            tagline: "soft, dusk, romantic",
            mood: .light,
            pageRGB: 0xE8E2EE,
            inkPrimaryRGB: 0x23192C,
            inkMutedRGB: 0x4A3D58,
            inkFadedRGB: 0x857B91,
            ruleOpacity: 0.14,
            accentRGB: 0x7C4DBE,
            cardRGB: 0xF5F0F9,
            cardStrokeOpacity: 0.10,
            cardInkPrimaryRGB: 0x23192C,
            cardInkMutedRGB: 0x4A3D58,
            cardInkFadedRGB: 0x857B91
        ),
        AppChromeTheme(
            id: "bone",
            displayName: "Bone",
            tagline: "warm, classic, hand-bound",
            mood: .light,
            pageRGB: 0xF2F0E7,
            inkPrimaryRGB: 0x1A140E,
            inkMutedRGB: 0x4A3F31,
            inkFadedRGB: 0x8C8067,
            ruleOpacity: 0.12,
            accentRGB: 0xB22A4A,
            cardRGB: 0xFBF9F2,
            cardStrokeOpacity: 0.10,
            cardInkPrimaryRGB: 0x1A140E,
            cardInkMutedRGB: 0x4A3F31,
            cardInkFadedRGB: 0x8C8067
        ),
        AppChromeTheme(
            id: "slate",
            displayName: "Slate",
            tagline: "grounded, drafting room, dim",
            mood: .dark,
            pageRGB: 0x2A2E33,
            inkPrimaryRGB: 0xF4ECDB,
            inkMutedRGB: 0xC4BBA8,
            inkFadedRGB: 0x8E8775,
            ruleOpacity: 0.18,
            accentRGB: 0xE9A4B3,
            cardRGB: 0x383D44,
            cardStrokeOpacity: 0.20,
            cardInkPrimaryRGB: 0xF4ECDB,
            cardInkMutedRGB: 0xC4BBA8,
            cardInkFadedRGB: 0x9A9385
        ),
        AppChromeTheme(
            id: "midnight",
            displayName: "Midnight",
            tagline: "late hour, quiet, blue ink",
            mood: .dark,
            pageRGB: 0x15203F,
            inkPrimaryRGB: 0xF4ECDB,
            inkMutedRGB: 0xC7C0AE,
            inkFadedRGB: 0x8E8C82,
            ruleOpacity: 0.20,
            accentRGB: 0xE9A4B3,
            cardRGB: 0x1F2D52,
            cardStrokeOpacity: 0.22,
            cardInkPrimaryRGB: 0xF4ECDB,
            cardInkMutedRGB: 0xC7C0AE,
            cardInkFadedRGB: 0x9C9A8E
        ),
        AppChromeTheme(
            id: "coal",
            displayName: "Coal",
            tagline: "lights out, brutal contrast",
            mood: .dark,
            pageRGB: 0x0F0A07,
            inkPrimaryRGB: 0xFBF9F2,
            inkMutedRGB: 0xC8C2B5,
            inkFadedRGB: 0x8C8478,
            ruleOpacity: 0.22,
            accentRGB: 0xB22A4A,
            cardRGB: 0x1A1410,
            cardStrokeOpacity: 0.22,
            cardInkPrimaryRGB: 0xFBF9F2,
            cardInkMutedRGB: 0xC8C2B5,
            cardInkFadedRGB: 0x9A9286
        ),
    ]

    /// Resolve a stored id back to a preset, snapping unknown values to
    /// `snow` so a corrupted defaults blob (or a future preset id loaded
    /// by an older binary) still produces a renderable surface.
    static func preset(for id: String) -> AppChromeTheme {
        presets.first { $0.id == id } ?? snow
    }
}
