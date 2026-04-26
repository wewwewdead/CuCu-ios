import SwiftUI

/// Floating action bar at the bottom of the builder. Theme on the left, primary
/// "Add Block" call-to-action on the right — separated by a flexible spacer so
/// the bar reads as intentional rather than a row of equal-weight icons.
struct EditorToolbar: View {
    let onAddBlock: () -> Void
    let onEditTheme: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEditTheme) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.cucuCard))
                    .overlay(Circle().strokeBorder(Color.cucuInk, lineWidth: 1))
                    .shadow(color: Color.cucuInk.opacity(0.22), radius: 14, y: 6)
            }
            .buttonStyle(CucuPressableButtonStyle())
            .accessibilityLabel("Edit theme")

            Spacer(minLength: 0)

            Button(action: onAddBlock) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .heavy))
                    Text("Add Block")
                        .font(.cucuSerif(16, weight: .bold))
                }
                .foregroundStyle(Color.cucuCard)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Capsule(style: .continuous).fill(Color.cucuInk))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.cucuCherry, lineWidth: 0).padding(0))
                .shadow(color: Color.cucuInk.opacity(0.28), radius: 18, y: 9)
            }
            .buttonStyle(CucuPressableButtonStyle())
        }
        .padding(.horizontal, 24)
    }
}
