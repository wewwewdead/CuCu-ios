import SwiftUI

/// Floating action bar at the bottom of the builder. Theme on the
/// left, primary "Add Block" call-to-action on the right. Refined-
/// minimalist surface: theme-aware fills, hairline strokes, soft
/// drop shadow tuned to the chrome mood.
struct EditorToolbar: View {
    let onAddBlock: () -> Void
    let onEditTheme: () -> Void

    @State private var chrome = AppChromeStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEditTheme) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(chrome.theme.inkPrimary)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(chrome.theme.cardColor))
                    .overlay(Circle().strokeBorder(chrome.theme.rule, lineWidth: 1))
                    .shadow(color: shadowColor, radius: 12, y: 5)
            }
            .buttonStyle(CucuPressableButtonStyle())
            .accessibilityLabel("Edit theme")

            Spacer(minLength: 0)

            Button(action: onAddBlock) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .heavy))
                    Text("Add Block")
                        .font(.cucuSans(16, weight: .bold))
                }
                .foregroundStyle(chrome.theme.pageColor)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Capsule(style: .continuous).fill(chrome.theme.inkPrimary))
                .shadow(color: shadowColor, radius: 16, y: 8)
            }
            .buttonStyle(CucuPressableButtonStyle())
        }
        .padding(.horizontal, 24)
    }

    private var shadowColor: Color {
        chrome.theme.isDark
            ? Color.black.opacity(0.45)
            : Color.black.opacity(0.18)
    }
}
