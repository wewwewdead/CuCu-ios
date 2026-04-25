import SwiftUI
import UIKit

/// Contextual bar shown when a node is selected on the canvas.
///
/// Layout (top to bottom):
/// 1. **Top row** — `×` to deselect, the path as inline tab-style text
///    (faded ancestors + bold current, all tappable for navigation),
///    `🗑` to delete the selection.
/// 2. **Selected tile** — color-tinted icon badge + type name + summary,
///    with an `…` overflow menu for layer-order / duplicate. Tap the
///    tile to open the full property inspector.
/// 3. **Inside / At this level** — vertical list of pill rows. Each row
///    is a sibling or child node, tappable to switch the selection.
///
/// Aesthetic: clean iOS-native — white (or `.systemBackground`) card,
/// `secondarySystemFill` pill rows, tinted icon badges, simple sans
/// type, generous whitespace, subtle press scale + light haptic on
/// every tap.
struct SelectionBottomBar: View {
    let document: ProfileDocument
    let selectedID: UUID

    var onSelect: (UUID?) -> Void
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onBringToFront: () -> Void
    var onSendBackward: () -> Void
    var onDelete: () -> Void
    /// Collapse the bar back into a small chevron pill. Distinct from
    /// `onSelect(nil)` (which deselects entirely) — collapse keeps the
    /// node selected so the canvas's selection overlay / drag handles
    /// stay visible.
    var onCollapse: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let node = document.nodes[selectedID] {
            VStack(spacing: 10) {
                topRow(for: node)
                separator
                selectedTile(for: node)
                if hasItemsRow(for: node) {
                    itemsSection(for: node)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 14, x: 0, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Top row (X + path tabs + trash)

    private func topRow(for node: CanvasNode) -> some View {
        HStack(spacing: 6) {
            iconButton("chevron.down", tint: .secondary) {
                onCollapse()
            }
            .accessibilityLabel("Collapse")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    pathItem(label: "Page", isCurrent: false) { onSelect(nil) }
                    ForEach(ancestorIDsRootDownward, id: \.self) { id in
                        if let n = document.nodes[id] {
                            pathSeparator
                            pathItem(label: displayName(for: n), isCurrent: false) {
                                onSelect(id)
                            }
                        }
                    }
                    pathSeparator
                    pathItem(label: displayName(for: node), isCurrent: true) {}
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)

            iconButton("trash", tint: .secondary) {
                onDelete()
            }
            .accessibilityLabel("Delete selection")
        }
    }

    private func pathItem(label: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            tapHaptic()
            action()
        } label: {
            Text(label)
                .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary.opacity(0.75))
                // Bigger, well-defined touch target with a subtle pill so
                // the chip can't be confused with the selected tile below.
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isCurrent)
    }

    private var pathSeparator: some View {
        Text("·")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }

    private var separator: some View {
        Rectangle()
            .fill(.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, 2)
    }

    // MARK: - Selected tile

    private func selectedTile(for node: CanvasNode) -> some View {
        HStack(spacing: 12) {
            iconBadge(for: node, size: 36, iconSize: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: node))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle(for: node))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Tap on the body of the tile (icon + text area) opens the
            // inspector. Scoped here — not on the entire row — so the
            // overflow `…` menu and the path chips above stay isolated.
            .contentShape(Rectangle())
            .onTapGesture {
                tapHaptic()
                onEdit()
            }
            Spacer(minLength: 4)
            tileMenu()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
    }

    private func tileMenu() -> some View {
        Menu {
            Button {
                tapHaptic(); onEdit()
            } label: { Label("Edit Properties", systemImage: "slider.horizontal.3") }
            Button {
                tapHaptic(); onDuplicate()
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button {
                tapHaptic(); onBringToFront()
            } label: { Label("Bring to Front", systemImage: "square.stack.3d.up") }
            Button {
                tapHaptic(); onSendBackward()
            } label: { Label("Send Backward", systemImage: "square.stack.3d.down.right") }
            Divider()
            Button(role: .destructive) {
                tapHaptic(); onDelete()
            } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
    }

    // MARK: - Inside / At this level

    private func hasItemsRow(for node: CanvasNode) -> Bool {
        if node.type == .container && !node.childrenIDs.isEmpty { return true }
        return !siblings(of: selectedID).filter { $0 != selectedID }.isEmpty
    }

    @ViewBuilder
    private func itemsSection(for node: CanvasNode) -> some View {
        let isContainerWithChildren = node.type == .container && !node.childrenIDs.isEmpty
        let ids: [UUID] = isContainerWithChildren
            ? node.childrenIDs
            : siblings(of: selectedID).filter { $0 != selectedID }
        let title = isContainerWithChildren ? "Inside" : "At this level"

        // Cap inline rows so the bar never dominates the screen. Up to
        // `inlineLimit` rows render directly in the VStack — bounded by
        // their natural height. Beyond that, switch to a ScrollView with
        // a hard `frame(height:)` so the bar stays a fixed size.
        // A plain ScrollView with no height bound would greedily fill
        // the entire safeAreaInset, which is what previously made the
        // bar take over the whole screen.
        let inlineLimit = 3
        let rowHeight: CGFloat = 52
        let scrollHeight: CGFloat = CGFloat(inlineLimit) * rowHeight + CGFloat(inlineLimit - 1) * 6

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ids.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)

            if ids.count <= inlineLimit {
                VStack(spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        if let related = document.nodes[id] {
                            itemRow(related, id: id)
                        }
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(ids, id: \.self) { id in
                            if let related = document.nodes[id] {
                                itemRow(related, id: id)
                            }
                        }
                    }
                }
                .frame(height: scrollHeight)
            }
        }
    }

    private func itemRow(_ node: CanvasNode, id: UUID) -> some View {
        Button {
            tapHaptic()
            onSelect(id)
        } label: {
            HStack(spacing: 12) {
                iconBadge(for: node, size: 30, iconSize: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: node))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(rowPreview(for: node))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(0.05))
            )
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func rowPreview(for node: CanvasNode) -> String {
        switch node.type {
        case .text:
            let preview = (node.content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Empty text" : preview
        case .container:
            let count = node.childrenIDs.count
            return count == 0 ? "Empty" : "\(count) item\(count == 1 ? "" : "s")"
        case .image:
            let hasImage = (node.content.localImagePath?.isEmpty == false)
            if !hasImage { return "No image" }
            let clip = node.style.clipShape ?? .rectangle
            return clip == .circle ? "Circle" : "Rectangle"
        }
    }

    private func siblings(of id: UUID) -> [UUID] {
        if let parentID = document.parent(of: id),
           let parent = document.nodes[parentID] {
            return parent.childrenIDs
        }
        return document.rootChildrenIDs
    }

    // MARK: - Tinted icon badge

    private func iconBadge(for node: CanvasNode, size: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(badgeColor(for: node).opacity(colorScheme == .dark ? 0.22 : 0.16))
            Image(systemName: iconName(for: node))
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(badgeColor(for: node))
        }
        .frame(width: size, height: size)
    }

    private func badgeColor(for node: CanvasNode) -> Color {
        switch node.type {
        case .container: return .indigo
        case .text:      return .orange
        case .image:     return .blue
        }
    }

    // MARK: - Small icon button (X / trash)

    private func iconButton(_ symbol: String, tint: HierarchicalShapeStyle, action: @escaping () -> Void) -> some View {
        Button {
            tapHaptic()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Tree helpers

    private var ancestorIDsRootDownward: [UUID] {
        var path: [UUID] = []
        var current: UUID? = document.parent(of: selectedID)
        while let id = current {
            path.insert(id, at: 0)
            current = document.parent(of: id)
        }
        return path
    }

    // MARK: - Type display

    private func iconName(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "rectangle.on.rectangle"
        case .text:      return "textformat"
        case .image:     return "photo"
        }
    }

    private func typeLabel(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "Container"
        case .text:      return "Text"
        case .image:     return "Image"
        }
    }

    /// Title shown to the user — the custom `name` if set, otherwise the
    /// generic type label. Used in the path chips, the selected tile,
    /// and the children rows so a renamed container reads consistently
    /// everywhere it appears.
    private func displayName(for node: CanvasNode) -> String {
        if let trimmed = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return typeLabel(for: node)
    }

    private func subtitle(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return childrenSummary(for: node)
        case .text:
            let preview = (node.content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Empty" : preview
        case .image: return imageSummary(for: node)
        }
    }

    private func childrenSummary(for node: CanvasNode) -> String {
        let total = node.childrenIDs.count
        if total == 0 { return "Empty container" }
        var counts: [NodeType: Int] = [:]
        for id in node.childrenIDs {
            if let child = document.nodes[id] {
                counts[child.type, default: 0] += 1
            }
        }
        var parts: [String] = []
        if let n = counts[.image], n > 0 { parts.append("\(n) image\(n == 1 ? "" : "s")") }
        if let n = counts[.text], n > 0 { parts.append("\(n) text\(n == 1 ? "" : "s")") }
        if let n = counts[.container], n > 0 { parts.append("\(n) container\(n == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func imageSummary(for node: CanvasNode) -> String {
        let hasImage = (node.content.localImagePath?.isEmpty == false)
        let clip = node.style.clipShape ?? .rectangle
        let fit = node.style.imageFit ?? .fill
        let clipName = clip == .circle ? "Circle" : "Rectangle"
        let fitName = fit == .fill ? "Fill" : "Fit"
        return hasImage ? "\(clipName) · \(fitName)" : "No image"
    }

    // MARK: - Haptics

    private func tapHaptic() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred(intensity: 0.6)
    }
}

// MARK: - Pressable button style

/// Subtle scale + opacity nudge on press for every chip / row / icon
/// button — pairs with the light haptic for a satisfying tactile feel.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
