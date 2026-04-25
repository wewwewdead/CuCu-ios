import SwiftUI

/// Compact "selection chip" shown at the bottom of the canvas when a
/// node is selected but the full bottom bar isn't expanded. Just a
/// small pill with the type icon, the node's display name, and an
/// up-chevron — tapping anywhere on the pill expands into the full
/// `SelectionBottomBar`.
///
/// Purpose: when the user taps a node, the canvas should stay mostly
/// visible so they can drag / position it freely. The full bar only
/// shows when the user explicitly opts in.
struct CollapsedSelectionBar: View {
    let document: ProfileDocument
    let selectedID: UUID
    var onExpand: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let node = document.nodes[selectedID] {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    iconBadge(for: node)
                    Text(displayName(for: node))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10),
                        radius: 8, x: 0, y: 2)
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Display

    private func iconBadge(for node: CanvasNode) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(badgeColor(for: node).opacity(colorScheme == .dark ? 0.22 : 0.16))
            Image(systemName: iconName(for: node))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badgeColor(for: node))
        }
        .frame(width: 22, height: 22)
    }

    private func iconName(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "rectangle.on.rectangle"
        case .text:      return "textformat"
        case .image:     return "photo"
        }
    }

    private func badgeColor(for node: CanvasNode) -> Color {
        switch node.type {
        case .container: return .indigo
        case .text:      return .orange
        case .image:     return .blue
        }
    }

    private func typeLabel(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "Container"
        case .text:      return "Text"
        case .image:     return "Image"
        }
    }

    private func displayName(for node: CanvasNode) -> String {
        if let trimmed = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return typeLabel(for: node)
    }
}

/// Subtle scale + opacity nudge on press, paired with a light haptic.
/// Local copy so this view doesn't depend on `SelectionBottomBar`'s
/// private button style.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
