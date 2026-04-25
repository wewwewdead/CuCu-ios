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
                // `.regularMaterial` + a stronger shadow so the small palette
                // icon stays legible when the page background is a busy
                // image (thinMaterial wasn't enough contrast against photos).
                Image(systemName: "paintpalette")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
                    .foregroundStyle(.primary)
                    .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit theme")

            Spacer(minLength: 0)

            Button(action: onAddBlock) {
                Label("Add Block", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).stroke(.quaternary, lineWidth: 0.5))
                    .foregroundStyle(.primary)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }
}
