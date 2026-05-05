import SwiftUI

/// Theme picker — pick the room the social pages (Feed, Thread,
/// Explore) sit on. Refined-minimalist surface: snow page,
/// hairline-divided rows, 40pt swatch + bold theme name + faded
/// tagline + radio mark on the trailing edge. Tap-to-apply is
/// instant; the sheet stays open so the user can step through
/// stocks against the live page underneath.
///
/// Drops the previous editorial chrome (Fraunces italic title,
/// "PAPER STOCK / №01" spec line, fleuron divider, cream tile
/// grid, mood pill) — the picker now reads as a list of refined
/// entries instead of a swatch tray.
struct AppChromeThemeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Read directly from the singleton so a tap on a row updates
    /// the live page underneath the sheet immediately.
    @State private var store = AppChromeStore.shared

    var body: some View {
        NavigationStack {
            ZStack {
                CucuRefinedPageBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CucuRefinedSectionLabel(text: "Themes")
                            .padding(.bottom, 8)
                        themeList
                        footer
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .cucuRefinedNav("Theme")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.cucuSans(15, weight: .semibold))
                        .foregroundStyle(store.theme.inkPrimary)
                }
            }
        }
    }

    /// One row per preset, hairline-separated. The first and last
    /// entries don't get a trailing rule so the list closes cleanly
    /// against the section label and footer above/below.
    private var themeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(AppChromeTheme.presets.enumerated()), id: \.element.id) { index, theme in
                ThemeRow(
                    theme: theme,
                    isSelected: store.theme.id == theme.id,
                    action: { store.setTheme(theme.id) }
                )
                if index < AppChromeTheme.presets.count - 1 {
                    CucuRefinedDivider()
                }
            }
        }
    }

    /// One-line footer crediting the live preview behavior. Faded
    /// ink, no glyph, sits flat against the page without any chip
    /// or border so it reads as a quiet handoff.
    private var footer: some View {
        Text("Tap to preview live underneath.")
            .font(.cucuSans(13, weight: .regular))
            .foregroundStyle(store.theme.inkFaded)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Theme row

/// Swatch tile (40×40 rounded square showing actual page colour
/// with a small ink-on-page mark) on the leading edge → bold theme
/// name → faded tagline → radio mark on the trailing edge.
private struct ThemeRow: View {
    let theme: AppChromeTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                swatch
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.displayName)
                        .font(.cucuSans(16, weight: .bold))
                        .foregroundStyle(chrome.theme.inkPrimary)
                    Text(theme.tagline)
                        .font(.cucuSans(13, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                radioMark
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(CucuRefinedRowButtonStyle())
        .accessibilityLabel("\(theme.displayName), \(theme.tagline)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 40pt swatch — the theme's actual page colour with a small
    /// ink mark in the upper-left so the user can read the polarity
    /// at a glance (light themes show deep ink, dark themes show
    /// cream ink). The accent dot in the lower-right ties the
    /// preview to the warm gold / burgundy / cobalt accent the
    /// theme uses for active marks.
    private var swatch: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.pageColor)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(theme.inkPrimary)
                        .frame(width: 14, height: 3)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(8)
        }
        .frame(width: 40, height: 40)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(chrome.theme.rule, lineWidth: 1)
        )
    }

    /// Radio mark — filled ink circle with a checkmark when active,
    /// empty outline when inactive. Stays in the chrome's primary
    /// ink so the active indicator inverts polarity with the theme
    /// (cream-on-coal on dark, ink-on-snow on light).
    private var radioMark: some View {
        Group {
            if isSelected {
                ZStack {
                    Circle().fill(chrome.theme.inkPrimary)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(chrome.theme.pageColor)
                }
                .frame(width: 22, height: 22)
                .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .strokeBorder(chrome.theme.inkFaded, lineWidth: 1.4)
                    .frame(width: 22, height: 22)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
    }
}
