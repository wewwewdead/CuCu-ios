import SwiftUI
import UIKit

/// Contextual bar shown when a node is selected on the canvas.
///
/// Layout (top to bottom):
/// 1. **Top row** — `chevron.down` to collapse, the path as inline tab-style
///    text (faded ancestors + bold current, all tappable for navigation),
///    `🗑` to delete the selection.
/// 2. **Selected tile** — color-tinted icon badge + type name + summary,
///    with an `…` overflow menu for layer-order / duplicate. Tap the
///    tile to open the full property inspector.
/// 3. **Inside / At this level** — vertical list of pill rows. Each row
///    is a sibling or child node, tappable to switch the selection.
///
/// Aesthetic: editorial-scrapbook — cream paper card with deep ink stroke,
/// Fraunces italic labels, fleuron divider between sections, palette-tuned
/// node-type badges.
struct SelectionBottomBar: View {
    let document: ProfileDocument
    let selectedID: UUID

    var onSelect: (UUID?) -> Void
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onBringToFront: () -> Void
    var onSendBackward: () -> Void
    var onLayers: () -> Void
    var onDelete: () -> Void
    /// Collapse the bar back into a small chevron pill. Distinct from
    /// `onSelect(nil)` (which deselects entirely) — collapse keeps the
    /// node selected so the canvas's selection overlay / drag handles
    /// stay visible.
    var onCollapse: () -> Void

    var body: some View {
        if let node = document.nodes[selectedID] {
            VStack(spacing: 10) {
                topRow(for: node)
                CucuFleuronDivider()
                selectedTile(for: node)
                if hasItemsRow(for: node) {
                    itemsSection(for: node)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cucuCard(corner: 20, innerRule: false, elevation: .raised)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Top row (collapse + path tabs + trash)

    private func topRow(for node: CanvasNode) -> some View {
        HStack(spacing: 6) {
            iconButton("chevron.down") { onCollapse() }
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

            iconButton("trash") { onDelete() }
                .disabled(!canDeleteSelection)
                .accessibilityLabel("Delete selection")
        }
    }

    private func pathItem(label: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            tapHaptic()
            action()
        } label: {
            Text(label)
                .font(.cucuSerif(14, weight: isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? Color.cucuInk : Color.cucuInkFaded)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isCurrent ? Color.cucuMossSoft : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isCurrent ? Color.cucuInk.opacity(0.55) : Color.clear,
                                      lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(CucuPressableButtonStyle())
        .disabled(isCurrent)
    }

    private var pathSeparator: some View {
        Text("·")
            .font(.cucuSerif(14, weight: .regular))
            .foregroundStyle(Color.cucuInkFaded)
            .padding(.horizontal, 2)
    }

    // MARK: - Selected tile

    private func selectedTile(for node: CanvasNode) -> some View {
        HStack(spacing: 12) {
            CucuIconBadge(kind: kind(for: node), symbol: iconName(for: node),
                          size: 36, iconSize: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: node))
                    .font(.cucuSerif(16, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Text(subtitle(for: node))
                    .font(.cucuSans(12, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
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
                .fill(Color.cucuCardSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
        )
    }

    private func tileMenu() -> some View {
        Menu {
            Button { tapHaptic(); onEdit() }
                label: { Label("Edit Properties", systemImage: "slider.horizontal.3") }
            Button { tapHaptic(); onDuplicate() }
                label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .disabled(!canDuplicateSelection)
            Button { tapHaptic(); onBringToFront() }
                label: { Label("Bring to Front", systemImage: "square.stack.3d.up") }
                .disabled(!canReorderSelection)
            Button { tapHaptic(); onSendBackward() }
                label: { Label("Send Backward", systemImage: "square.stack.3d.down.right") }
                .disabled(!canReorderSelection)
            Button { tapHaptic(); onLayers() }
                label: { Label("Layers", systemImage: "square.3.layers.3d") }
            Divider()
            Button(role: .destructive) { tapHaptic(); onDelete() }
                label: { Label("Delete", systemImage: "trash") }
                .disabled(!canDeleteSelection)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
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

        let inlineLimit = 3
        let rowHeight: CGFloat = 52
        let scrollHeight: CGFloat = CGFloat(inlineLimit) * rowHeight + CGFloat(inlineLimit - 1) * 6

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.cucuSerif(13, weight: .semibold))
                    .foregroundStyle(Color.cucuInkSoft)
                Spacer()
                Text("\(ids.count)")
                    .font(.cucuMono(11, weight: .medium))
                    .foregroundStyle(Color.cucuInkFaded)
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
                CucuIconBadge(kind: kind(for: node), symbol: iconName(for: node),
                              size: 30, iconSize: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: node))
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Text(rowPreview(for: node))
                        .font(.cucuSans(11, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cucuInkFaded)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cucuCardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(CucuPressableButtonStyle())
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
        case .icon:
            return (node.style.iconStyleFamily ?? .pastelDoodle).label
        case .divider:
            return (node.style.dividerStyleFamily ?? .solid).label
        case .link:
            let url = (node.content.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? (node.style.linkStyleVariant ?? .pill).label : url
        case .gallery:
            let count = node.content.imagePaths?.count ?? 0
            return "\(count) image\(count == 1 ? "" : "s")"
        case .carousel:
            let count = node.childrenIDs.count
            return "\(count) page\(count == 1 ? "" : "s")"
        case .note:
            let stamp = (node.content.noteTimestamp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return stamp.isEmpty ? "Note" : stamp
        }
    }

    private func siblings(of id: UUID) -> [UUID] {
        if let parentID = document.parent(of: id),
           let parent = document.nodes[parentID] {
            return parent.childrenIDs
        }
        if let pageIndex = document.pageContaining(id) {
            return document.children(of: nil, onPage: pageIndex)
        }
        return document.children(of: nil)
    }

    // MARK: - Tinted icon badge (delegated to CucuIconBadge)

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

    // MARK: - Small icon button (collapse / trash)

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            tapHaptic()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(CucuPressableButtonStyle())
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

    private func subtitle(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return childrenSummary(for: node)
        case .text:
            let preview = (node.content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Empty" : preview
        case .image: return imageSummary(for: node)
        case .icon:
            let family = (node.style.iconStyleFamily ?? .pastelDoodle).label
            let glyph = node.content.iconName ?? "—"
            return "\(family) · \(glyph)"
        case .divider:
            return (node.style.dividerStyleFamily ?? .solid).label
        case .link:
            let url = (node.content.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? (node.style.linkStyleVariant ?? .pill).label : url
        case .gallery:
            let count = node.content.imagePaths?.count ?? 0
            return "\(count) image\(count == 1 ? "" : "s")"
        case .carousel:
            let count = node.childrenIDs.count
            return count == 0 ? "Empty carousel" : "\(count) item\(count == 1 ? "" : "s")"
        case .note:
            let title = (node.content.noteTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Note" : title
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

extension SelectionBottomBar: Equatable {
    /// Equality on the rendering inputs only. The bar walks
    /// ancestors / siblings / children of `selectedID` against the
    /// full `document` tree, so document equality is the right grain.
    /// Closures aren't compared — they capture references whose
    /// internals stay current even when the closure value is reused.
    static func == (lhs: SelectionBottomBar, rhs: SelectionBottomBar) -> Bool {
        lhs.selectedID == rhs.selectedID && lhs.document == rhs.document
    }
}
