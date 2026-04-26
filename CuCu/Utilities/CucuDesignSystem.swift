import SwiftUI

// MARK: - Color tokens
//
// Editorial-scrapbook palette: warm bone paper, cream cards, deep ink ruling,
// dusty rose chips with burgundy text, deep moss for "on" states. All other
// app colors (canvas, user content, system tints) flow through unchanged —
// these tokens only style the editor chrome, modals, and inspector panels.

private extension Color {
    /// Self-contained hex literal helper for the palette below. Kept
    /// private + distinct from the project-wide `Color(hex: String)` so
    /// the design system can be dropped into any target without depending
    /// on the order of file inclusion / extension visibility.
    init(cucuRGB rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension Color {
    // Off-white surfaces with the faintest warm undertone — just enough so
    // the editor doesn't read clinical, but well past the aged-paper yellow
    // of earlier iterations. Cards float a hair brighter than paper so the
    // depth is still legible without leaning on heavy shadows.
    static let cucuPaper      = Color(cucuRGB: 0xF2F0E7)
    static let cucuPaperDeep  = Color(cucuRGB: 0xE7E3D6)
    static let cucuCard       = Color(cucuRGB: 0xFBF9F2)
    static let cucuCardSoft   = Color(cucuRGB: 0xEEEAE0)

    static let cucuInk        = Color(cucuRGB: 0x1A140E)
    static let cucuInkSoft    = Color(cucuRGB: 0x4A3F31)
    static let cucuInkFaded   = Color(cucuRGB: 0x8C8067)
    static let cucuInkRule    = Color.black.opacity(0.12)

    static let cucuMoss       = Color(cucuRGB: 0x4A7D4D)
    static let cucuMossSoft   = Color(cucuRGB: 0xD8E4C7)
    static let cucuRose       = Color(cucuRGB: 0xEFD9DA)
    static let cucuRoseStroke = Color(cucuRGB: 0xB67C83)
    static let cucuBurgundy   = Color(cucuRGB: 0x4A1722)
    static let cucuCherry     = Color(cucuRGB: 0xB22A4A)
    static let cucuCobalt     = Color(cucuRGB: 0x3B6BCC)
    static let cucuMatcha     = Color(cucuRGB: 0x9AB854)
    static let cucuMidnight   = Color(cucuRGB: 0x15203F)
    static let cucuShell      = Color(cucuRGB: 0xE9A4B3)
    static let cucuBone       = Color(cucuRGB: 0xF4ECDB)
    static let cucuCoal       = Color(cucuRGB: 0x0F0A07)
}

// MARK: - Fonts
//
// Lexend is the primary editor face — bundled under `CuCu/Fonts/` and
// registered at app launch by `CucuFontRegistration.registerBundledFonts()`.
// `cucuSerif` is kept as the API surface for "display / heading" (it carried
// italic semantics in earlier versions of this design system); on Lexend the
// `italic` flag is a no-op. Specs / numerals stay on the system monospaced
// face for textural contrast.

extension Font {
    static func cucuSerif(_ size: CGFloat, weight: Weight = .bold, italic: Bool = false) -> Font {
        cucuLexend(size, weight: weight)
    }

    static func cucuSans(_ size: CGFloat, weight: Weight = .regular) -> Font {
        cucuLexend(size, weight: weight)
    }

    static func cucuMono(_ size: CGFloat, weight: Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// Resolve a `Font.Weight` to the matching Lexend face name. If
    /// registration silently failed, `Font.custom` falls back to the
    /// system font so the UI never shows blank glyphs.
    private static func cucuLexend(_ size: CGFloat, weight: Weight) -> Font {
        let face: String
        switch weight {
        case .black, .heavy, .bold:        face = "Lexend-Bold"
        case .semibold:                    face = "Lexend-SemiBold"
        case .medium:                      face = "Lexend-Medium"
        default:                           face = "Lexend-Regular"
        }
        return Font.custom(face, size: size)
    }
}

// MARK: - Card / paper view modifiers

extension View {
    /// Cream card with a fine ink stroke and an inner hairline rule —
    /// the editor's standard floating surface (inspector, selection bar,
    /// `BlockOptionContent`, etc.).
    func cucuCard(
        corner: CGFloat = 18,
        innerRule: Bool = true,
        elevation: CucuElevation = .raised
    ) -> some View {
        modifier(CucuCardModifier(corner: corner, innerRule: innerRule, elevation: elevation))
    }

    /// Paper-toned Form / List backdrop shared by every modal sheet.
    /// Hides the default grouped-list gray, lays cream paper underneath,
    /// and tints toolbar buttons in deep ink.
    @ViewBuilder
    func cucuFormBackdrop() -> some View {
        let base = self
            .scrollContentBackground(.hidden)
            .background(Color.cucuPaper.ignoresSafeArea())
            .tint(Color.cucuInk)
        #if os(iOS) || os(visionOS)
        base
            .toolbarBackground(Color.cucuPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        base
        #endif
    }

    /// Replaces the navigation title with a Fraunces-italic principal item.
    /// Pair with `.cucuFormBackdrop()` on every sheet.
    func cucuSheetTitle(_ title: String) -> some View {
        self
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.cucuSerif(19, weight: .bold))
                        .foregroundStyle(Color.cucuInk)
                }
            }
    }

    /// Standardized "❦" fleuron divider — used between sections inside cards.
    func cucuFleuronInline() -> some View {
        VStack(spacing: 0) {
            self
            CucuFleuronDivider()
                .padding(.vertical, 4)
        }
    }
}

enum CucuElevation {
    case flat, raised, lifted

    var shadowRadius: CGFloat {
        switch self {
        case .flat:   return 0
        case .raised: return 14
        case .lifted: return 22
        }
    }
    var shadowY: CGFloat {
        switch self {
        case .flat:   return 0
        case .raised: return 6
        case .lifted: return 10
        }
    }
    var shadowOpacity: Double {
        switch self {
        case .flat:   return 0
        case .raised: return 0.18
        case .lifted: return 0.28
        }
    }
}

private struct CucuCardModifier: ViewModifier {
    let corner: CGFloat
    let innerRule: Bool
    let elevation: CucuElevation

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.cucuCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.cucuInk, lineWidth: 1)
            )
            .overlay(
                Group {
                    if innerRule {
                        RoundedRectangle(cornerRadius: max(0, corner - 6), style: .continuous)
                            .strokeBorder(Color.cucuInk.opacity(0.10), lineWidth: 1)
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
            )
            .shadow(
                color: Color.cucuInk.opacity(elevation.shadowOpacity),
                radius: elevation.shadowRadius,
                x: 0,
                y: elevation.shadowY
            )
    }
}

// MARK: - Fleuron divider

struct CucuFleuronDivider: View {
    var glyph: String = "❦"
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1)
            Text(glyph)
                .font(.cucuSerif(12, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1)
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Spec line (figure / numbering caption)

struct CucuSpecLine: View {
    let figure: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(Color.cucuCherry).frame(width: 5, height: 5)
                Text(figure.uppercased())
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color.cucuInkSoft)
            }
            Spacer()
            if let trailing {
                Text(trailing.uppercased())
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color.cucuInkSoft)
            }
        }
    }
}

// MARK: - Section header (for Form sections)

struct CucuSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.cucuSerif(14, weight: .bold))
            .foregroundStyle(Color.cucuInk)
            .textCase(nil)
    }
}

// MARK: - Editorial chip

struct CucuChip: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void = {}) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.cucuSerif(14, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(Color.cucuBurgundy)
            .background(Capsule().fill(Color.cucuRose))
            .overlay(Capsule().strokeBorder(Color.cucuRoseStroke, lineWidth: 1))
        }
        .buttonStyle(CucuPressableButtonStyle())
    }
}

// MARK: - Numeric value pill (slider readouts, padding/margin values)

struct CucuValuePill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.cucuMono(12, weight: .medium))
            .foregroundStyle(Color.cucuInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.cucuCard))
            .overlay(Capsule().strokeBorder(Color.cucuInk, lineWidth: 1))
    }
}

// MARK: - Bottom-bar / capsule pill (path chips, "At this level" rows)

struct CucuRowPill<Content: View>: View {
    let isCurrent: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isCurrent ? Color.cucuMossSoft : Color.cucuCardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(isCurrent ? 0.55 : 0.18), lineWidth: 1)
            )
    }
}

// MARK: - Pressable button style (used everywhere the user taps a chip)

struct CucuPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - Icon badge (per-node-type tinting)
//
// Maps the three node types to palette colors so the inspector, selection
// bar, and collapsed bar all show the same color for the same kind of node.
// Using a free function keeps the design system independent of the domain
// types — callers pass the type directly.

enum CucuNodeKind { case container, text, image, icon, divider, link, gallery, carousel }

extension Color {
    static func cucuBadgeTint(for kind: CucuNodeKind) -> Color {
        switch kind {
        case .container: return .cucuCobalt
        case .text:      return .cucuCherry
        case .image:     return .cucuMoss
        case .icon:      return .cucuShell
        case .divider:   return .cucuInkSoft
        case .link:      return .cucuMatcha
        case .gallery:   return .cucuMidnight
        // Reuse the rose family for carousel — it sits next to
        // gallery in the AddNodeSheet but reads as a different kind
        // of "multi-content" surface (paginated vs. tiled), and
        // rose is unused by the other type badges.
        case .carousel:  return .cucuRoseStroke
        }
    }
}

struct CucuIconBadge: View {
    let kind: CucuNodeKind
    let symbol: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cucuBadgeTint(for: kind))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color.cucuCard)
        }
        .frame(width: size, height: size)
    }
}
