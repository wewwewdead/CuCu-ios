import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Refined-minimalist primitives
//
// Companion design system to the editorial-cream tokens in
// `CucuDesignSystem.swift`. The editorial style still owns the
// canvas builder, inspectors, and modal sheets that read as
// content-creation surfaces. The refined-minimalist primitives
// below own the *social chrome* (Account, Theme picker, Explore,
// Feed masthead): clean snow page, deep ink labels, hairline
// dividers, custom black-on toggle, gold favourite star, soft
// pale-grey pill button.
//
// Theme-aware: every primitive reads from `AppChromeStore.shared.theme`
// so a user on `bone` or `midnight` still sees their chosen room.
// Snow (the default theme) is what the reference image looks like.

// MARK: Section label

/// Small grey label that sits above a refined section. No tracking,
/// no monospace, no italics — just a quiet sentence-case header in
/// the chrome's faded ink, sized so it stays in the row's optical
/// hierarchy without competing for attention.
struct CucuRefinedSectionLabel: View {
    let text: String
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Text(text)
            .font(.cucuSans(13, weight: .regular))
            .foregroundStyle(chrome.theme.inkFaded)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Section header that supports inline bold emphasis — the reference
/// image uses this pattern in "All your custom spaces, perfectly
/// **curated by you**." Pass the prefix and the bold suffix
/// separately; both render in the chrome's faded ink so the bold
/// reads as weight emphasis, not a colour shift.
struct CucuRefinedSectionTitle: View {
    let prefix: String
    let bold: String
    let suffix: String
    @State private var chrome = AppChromeStore.shared

    init(_ prefix: String, bold: String, suffix: String = "") {
        self.prefix = prefix
        self.bold = bold
        self.suffix = suffix
    }

    var body: some View {
        (
            Text(prefix).font(.cucuSans(13, weight: .regular))
            + Text(bold).font(.cucuSans(13, weight: .bold))
            + Text(suffix).font(.cucuSans(13, weight: .regular))
        )
        .foregroundStyle(chrome.theme.inkFaded)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(2)
    }
}

// MARK: Favourite star

/// Outline → filled gold star with a bounce on toggle. Single warm
/// accent in the refined system; no other gold lives on these
/// surfaces, so a starred row reads as the user's own pick.
struct CucuFavoriteStar: View {
    @Binding var isFavorited: Bool
    var size: CGFloat = 22

    @State private var bouncing: Bool = false
    @State private var chrome = AppChromeStore.shared

    /// Warm gold pulled to feel daylit on snow paper without going
    /// neon — sits one step below pure yellow so it doesn't fight
    /// the deep ink labels around it.
    private static let gold = Color(red: 0xF6 / 255, green: 0xC4 / 255, blue: 0x4A / 255)

    var body: some View {
        Button {
            CucuHaptics.selection()
            isFavorited.toggle()
            // One-shot anticipation pop. Bouncing flag flips on, the
            // .scaleEffect spring lifts to 1.18, then a 140ms delay
            // releases it back. The spring response handles the easing
            // both directions so it reads as a single bounce, not a
            // step.
            bouncing = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 140_000_000)
                bouncing = false
            }
        } label: {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isFavorited ? Self.gold : chrome.theme.inkFaded)
                .scaleEffect(bouncing ? 1.18 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: bouncing)
                .animation(.easeOut(duration: 0.18), value: isFavorited)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorited ? "Unfavorite" : "Favorite")
    }
}

// MARK: Refined toggle

/// Custom black-on / grey-off toggle that matches the reference
/// image's iOS-style switch with a deliberate ink palette. Tracks at
/// 50×30, thumb at 26pt — close enough to system that muscle memory
/// works, distinct enough that the chrome doesn't get hijacked by
/// the system green.
///
/// Theme-aware: the "on" track uses `chrome.theme.inkPrimary` so a
/// dark theme paints a cream-on-coal toggle, and the off track uses
/// a low-opacity ink against the page so the off state sits flat
/// instead of glowing.
struct CucuRefinedToggle: View {
    @Binding var isOn: Bool
    @State private var chrome = AppChromeStore.shared

    private let trackWidth: CGFloat = 50
    private let trackHeight: CGFloat = 30
    private let thumbSize: CGFloat = 26
    private let thumbInset: CGFloat = 2

    var body: some View {
        Button {
            CucuHaptics.soft()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(trackFill)
                    .frame(width: trackWidth, height: trackHeight)
                    .overlay(
                        Capsule()
                            .strokeBorder(trackStroke, lineWidth: 1)
                    )
                Circle()
                    .fill(thumbFill)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.black.opacity(isOn ? 0.0 : 0.10), radius: 1.5, x: 0, y: 1)
                    .padding(thumbInset)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel("Toggle")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    /// On = chrome's primary ink (deep on light, cream on dark).
    /// Off = a quiet step of the same ink so the off state reads as
    /// "not lit" rather than a different control entirely.
    private var trackFill: Color {
        isOn
            ? chrome.theme.inkPrimary
            : (chrome.theme.isDark
                ? Color.white.opacity(0.14)
                : Color.black.opacity(0.10))
    }

    private var trackStroke: Color {
        isOn ? Color.clear : chrome.theme.rule
    }

    /// Off-thumb: page color (so it reads as the unlit hole).
    /// On-thumb: pure white with a hint of inset shadow so it floats
    /// against the ink track.
    private var thumbFill: Color {
        isOn ? Color.white : chrome.theme.pageColor
    }
}

// MARK: List row

/// Flexible refined list row. The leading slot takes any view —
/// commonly a 36pt avatar, a colour block, or a system glyph. The
/// title sits in bold Lexend, with optional subtitle copy below in
/// faded ink. Trailing slot takes any view — typically the
/// star + toggle pairing from the reference image.
///
/// Why generic on Leading + Trailing instead of opinionated structs:
/// the same row chrome serves Account (system glyph + chevron),
/// Theme picker (swatch tile + radio mark), and a spaces-style
/// management screen (avatar + star + toggle). Forcing one shape
/// would have forked into three near-duplicates.
struct CucuRefinedListRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    var onTap: (() -> Void)? = nil

    @State private var chrome = AppChromeStore.shared

    var body: some View {
        let row = HStack(spacing: 14) {
            leading()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cucuSans(16, weight: .bold))
                    .foregroundStyle(chrome.theme.inkPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.cucuSans(13, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { row }
                .buttonStyle(CucuRefinedRowButtonStyle())
        } else {
            row
        }
    }
}

/// Soft press-down state for tappable list rows. A 0.6% scale +
/// page-tone fade reads as "the row acknowledged you" without
/// breaking the flat aesthetic.
struct CucuRefinedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: List divider

/// 1pt hairline using the chrome's mood-aware rule. Light themes
/// paint near-black at 12% opacity; dark themes flip polarity to
/// near-white so the rule reads as a faint highlight.
struct CucuRefinedDivider: View {
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Rectangle()
            .fill(chrome.theme.rule)
            .frame(height: 1)
    }
}

// MARK: Pill button

/// Full-width primary pill — soft pale-grey fill, bold black label.
/// Used for "Add a new space" / "Sign Out" / "Try again" style
/// affordances. Reads as the same flat surface as a row, just
/// extruded into a button shape.
struct CucuRefinedPillButton: View {
    let title: String
    let role: ButtonRole?
    let action: () -> Void

    @State private var chrome = AppChromeStore.shared

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.cucuSans(16, weight: .bold))
                .foregroundStyle(role == .destructive ? destructiveInk : chrome.theme.inkPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(fill)
                )
        }
        .buttonStyle(CucuRefinedPillButtonStyle())
    }

    /// A quieter step of the page ink, low-saturation so destructive
    /// reads as serious without going pure red against the calm
    /// chrome.
    private var destructiveInk: Color {
        Color(red: 178 / 255, green: 42 / 255, blue: 74 / 255) // cucuCherry
    }

    /// Pale neutral pulled per-mood: light themes get a near-page
    /// soft step (faintly cooler than the page so the pill sits on
    /// top); dark themes get a faint highlight so the pill reads as
    /// raised against the room.
    private var fill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }
}

private struct CucuRefinedPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: Avatar tile

/// Leading-slot avatar for refined rows. Three modes:
///   - `.image(url)` — circular cropped photo
///   - `.color(hex)` — solid pastel rounded square (the "Food
///     Lobby" / "FrothGoals" pattern from the reference)
///   - `.glyph(name)` — SF Symbol on the chrome's primary ink
///
/// 36pt to match the row's height. Don't pass a fixed frame; the
/// row already sizes the leading slot.
struct CucuRefinedAvatarTile: View {
    enum Source {
        case image(String?)
        case color(Color)
        case glyph(String)
    }

    let source: Source
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        switch source {
        case .image(let urlString):
            imageBody(urlString: urlString)
        case .color(let color):
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(width: 32, height: 32)
        case .glyph(let name):
            Image(systemName: name)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(chrome.theme.inkPrimary)
                .frame(width: 32, height: 32)
        }
    }

    @ViewBuilder
    private func imageBody(urlString: String?) -> some View {
        if let urlString,
           let url = CucuImageTransform.resized(urlString, square: 36) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                fallbackCircle
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
        } else {
            fallbackCircle
        }
    }

    private var fallbackCircle: some View {
        Circle()
            .fill(chrome.theme.cardColor)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(chrome.theme.inkFaded)
            )
            .frame(width: 32, height: 32)
    }
}

// MARK: Refined nav modifier

/// Centered Lexend bold nav title with a hairline below the bar.
/// Pair with a leading back-chevron toolbar item and (optionally) a
/// trailing single-icon affordance. Skips the mass of editorial
/// chrome the social pages had been carrying — no tracked spec
/// line, no Fraunces principal, no fleuron divider.
extension View {
    func cucuRefinedNav(_ title: String) -> some View {
        modifier(CucuRefinedNavModifier(title: title))
    }
}

private struct CucuRefinedNavModifier: ViewModifier {
    let title: String
    @State private var chrome = AppChromeStore.shared

    func body(content: Content) -> some View {
        let base = content
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.cucuSans(17, weight: .bold))
                        .foregroundStyle(chrome.theme.inkPrimary)
                }
            }
        #if os(iOS) || os(visionOS)
        base
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(chrome.theme.pageColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(chrome.theme.preferredColorScheme, for: .navigationBar)
        #else
        base
        #endif
    }
}

// MARK: Page backdrop

/// Full-bleed snow / theme page behind a refined surface. Use as
/// the outermost view in a `ZStack` so the toolbar, content, and
/// safe-area all sit on the same continuous sheet.
struct CucuRefinedPageBackdrop: View {
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        chrome.theme.pageColor
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.32), value: chrome.theme.id)
    }
}
