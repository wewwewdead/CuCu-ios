import SwiftUI
import UIKit

/// Compact "selection chip" shown at the bottom of the canvas when a
/// node is selected but the full bottom bar isn't expanded. The main
/// chip expands into `SelectionBottomBar`; the trailing menu exposes
/// common selection actions without covering the canvas.
///
/// Purpose: when the user taps a node, the canvas should stay mostly
/// visible so they can drag / position it freely. The full bar only
/// shows when the user explicitly opts in.
struct CollapsedSelectionBar: View {
    let document: ProfileDocument
    let selectedID: UUID
    var onExpand: () -> Void
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onBringToFront: () -> Void
    var onSendBackward: () -> Void
    var onLayers: () -> Void
    var onDelete: () -> Void

    var body: some View {
        if let node = document.nodes[selectedID] {
            HStack(spacing: 4) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        CucuIconBadge(
                            kind: kind(for: node),
                            symbol: iconName(for: node),
                            size: 24,
                            iconSize: 11
                        )
                        Text(displayName(for: node))
                            .font(.cucuSerif(14, weight: .semibold))
                            .foregroundStyle(Color.cucuInk)
                            .lineLimit(1)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Color.cucuInkSoft)
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(CucuPressableButtonStyle())

                Rectangle()
                    .fill(Color.cucuInk.opacity(0.18))
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 2)

                contextMenu
            }
            .padding(.trailing, 4)
            .background(Capsule().fill(Color.cucuCard))
            .overlay(Capsule().strokeBorder(Color.cucuInk, lineWidth: 1))
            .shadow(color: Color.cucuInk.opacity(0.18), radius: 10, x: 0, y: 4)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var contextMenu: some View {
        Menu {
            Button {
                tapHaptic(); onEdit()
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button {
                tapHaptic(); onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(!canDuplicateSelection)
            Button {
                tapHaptic(); onBringToFront()
            } label: {
                Label("Bring Front", systemImage: "square.stack.3d.up")
            }
            .disabled(!canReorderSelection)
            Button {
                tapHaptic(); onSendBackward()
            } label: {
                Label("Send Back", systemImage: "square.stack.3d.down.right")
            }
            .disabled(!canReorderSelection)
            Button {
                tapHaptic(); onLayers()
            } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
            }
            Divider()
            Button(role: .destructive) {
                tapHaptic(); onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canDeleteSelection)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Selection actions")
    }

    private var canDeleteSelection: Bool {
        StructuredProfileLayout.canDelete(selectedID, in: document)
    }

    private var canDuplicateSelection: Bool {
        StructuredProfileLayout.canDuplicate(selectedID, in: document)
    }

    private var canReorderSelection: Bool {
        StructuredProfileLayout.canReorder(selectedID, in: document)
    }

    // MARK: - Display

    private func kind(for node: CanvasNode) -> CucuNodeKind {
        switch node.type {
        case .container: return .container
        case .text:      return .text
        case .image:     return .image
        case .icon:      return .icon
        case .divider:   return .divider
        case .link:      return .link
        case .gallery:   return .gallery
        case .carousel:  return .carousel
        case .note:      return .note
        }
    }

    private func iconName(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "rectangle.on.rectangle"
        case .text:      return "textformat"
        case .image:     return "photo"
        case .icon:      return "star.fill"
        case .divider:   return "minus"
        case .link:      return "link"
        case .gallery:   return "rectangle.grid.2x2"
        case .carousel:  return "rectangle.stack"
        case .note:      return "note.text"
        }
    }

    private func typeLabel(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "Container"
        case .text:      return "Text"
        case .image:     return "Image"
        case .icon:      return "Icon"
        case .divider:   return "Divider"
        case .link:      return "Link"
        case .gallery:   return "Gallery"
        case .carousel:  return "Carousel"
        case .note:      return "Note"
        }
    }

    private func displayName(for node: CanvasNode) -> String {
        if let trimmed = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return typeLabel(for: node)
    }

    private func tapHaptic() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred(intensity: 0.6)
    }
}

extension CollapsedSelectionBar: Equatable {
    /// The chip body reads `document.nodes[selectedID]`'s display
    /// name + type — so an unchanged selection over an unchanged
    /// document is a no-op render. Closures aren't compared (they
    /// capture references that stay current).
    static func == (lhs: CollapsedSelectionBar, rhs: CollapsedSelectionBar) -> Bool {
        lhs.selectedID == rhs.selectedID && lhs.document == rhs.document
    }
}
