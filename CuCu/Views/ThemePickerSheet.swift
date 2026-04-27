import SwiftUI

/// Modal "pick a vibe" sheet — a 2-column grid of theme cards. Tapping
/// a card calls `mutator.applyTheme(...)` and dismisses; if the
/// current document already has any non-default page chrome a
/// `.confirmationDialog` interposes so the user is never silently
/// repainted over hand-tuned work.
///
/// TODO(v2): the desktop mockup also exposes a "Custom" theme builder
/// at the bottom of the picker (free-form bg colour + accent + font +
/// divider). Skipped for v1 — themes are a one-shot paint, and a
/// custom-builder sheet would reintroduce the persistence question
/// the architecture decision deferred.
struct ThemePickerSheet: View {
    let mutator: CanvasMutator
    let document: ProfileDocument

    @Environment(\.dismiss) private var dismiss
    /// Theme tapped while the document had non-default chrome — we
    /// stash it here so the confirmation dialog can fire `applyTheme`
    /// on user confirm. `nil` whenever no confirmation is in flight.
    @State private var pendingTheme: CucuTheme?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(CucuTheme.presets) { theme in
                        themeCard(theme)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color.cucuPaper.ignoresSafeArea())
            .cucuSheetTitle("Pick a vibe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.cucuPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Color.cucuInk)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.cucuSerif(16, weight: .bold))
                }
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationPresented,
            titleVisibility: .visible,
            presenting: pendingTheme
        ) { theme in
            Button("Apply", role: .destructive) {
                mutator.applyTheme(theme)
                pendingTheme = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                pendingTheme = nil
            }
        } message: { _ in
            Text("This will replace your page background and effects. Your nodes won't change.")
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func themeCard(_ theme: CucuTheme) -> some View {
        Button {
            tapped(theme)
        } label: {
            VStack(spacing: 0) {
                preview(for: theme)
                meta(for: theme)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cucuCardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.cucuInkRule, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(CucuPressableButtonStyle())
    }

    /// Top ~70% of the card — paints the theme's bg colour + pattern,
    /// then layers a tiny "aa" title in the theme's display font, a
    /// divider in the theme's accent, and two pill-shaped link rows.
    /// Mirrors the mockup's mini-preview composition (themes.jsx
    /// `ThemeChip`) but at phone-sized proportions.
    @ViewBuilder
    private func preview(for theme: CucuTheme) -> some View {
        let bg = Color(hex: theme.pageBackgroundHex)
        let accent = Color(hex: theme.accentHex)
        let pattern = CanvasBackgroundPattern(key: theme.pageBackgroundPatternKey)
        let textOnDark = isDark(theme.pageBackgroundHex)
        let inkOnTheme = textOnDark ? Color.white : Color.cucuInk
        return ZStack {
            bg
            if let pattern { pattern.overlay() }
            VStack(spacing: 8) {
                Text("aa")
                    .font(theme.defaultDisplayFont.swiftUIFont(size: 26, weight: .semibold))
                    .foregroundStyle(inkOnTheme)
                Rectangle()
                    .fill(accent)
                    .frame(width: 56, height: 1.4)
                HStack(spacing: 6) {
                    Capsule()
                        .stroke(accent, lineWidth: 1.4)
                        .frame(width: 38, height: 12)
                    Capsule()
                        .fill(accent)
                        .frame(width: 38, height: 12)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .aspectRatio(1.05, contentMode: .fit)
    }

    /// Bottom strip — theme display name in italic Fraunces, tagline
    /// in mono uppercase below.
    @ViewBuilder
    private func meta(for theme: CucuTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(theme.displayName)
                .font(.cucuEditorial(15, weight: .semibold, italic: true))
                .foregroundStyle(Color.cucuInk)
                .lineLimit(1)
            Text(theme.tagline.uppercased())
                .font(.cucuMono(8.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.cucuInkFaded)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.cucuCard)
        .overlay(
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - Confirmation gating

    private func tapped(_ theme: CucuTheme) {
        if currentDocumentNeedsConfirmation {
            pendingTheme = theme
        } else {
            mutator.applyTheme(theme)
            dismiss()
        }
    }

    /// Show the confirmation dialog when *any* page has chrome that
    /// would be overwritten by the apply. Fresh / blank documents
    /// skip the prompt — the spec calls for "starting point, not
    /// constraint", and a confirmation on a default-state doc adds
    /// noise without protecting anything.
    private var currentDocumentNeedsConfirmation: Bool {
        let defaultHex = ProfileDocument.defaultPageBackgroundHex
            .lowercased()
        for page in document.pages {
            if page.backgroundHex.lowercased() != defaultHex { return true }
            if let path = page.backgroundImagePath, !path.isEmpty { return true }
            if let key = page.backgroundPatternKey, !key.isEmpty { return true }
        }
        return false
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingTheme != nil },
            set: { if !$0 { pendingTheme = nil } }
        )
    }

    private var confirmationTitle: String {
        if let theme = pendingTheme {
            return "Apply \(theme.displayName)?"
        }
        return "Apply theme?"
    }

    /// True for hexes whose perceived luminance falls below ~0.5 —
    /// the picker swaps the preview's ink colour to white over those
    /// so "aa" stays legible on Dusk Diary's near-black background.
    private func isDark(_ hex: String) -> Bool {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6,
              let value = UInt32(trimmed, radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        // Rec. 709 luminance — eyeballed threshold; the seven
        // bundled themes split cleanly at 0.5.
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum < 0.5
    }
}
