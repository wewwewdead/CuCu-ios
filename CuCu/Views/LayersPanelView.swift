import SwiftUI

/// Lightweight hierarchy browser for the v2 canvas document. This is
/// intentionally not a second editor: it reads the existing
/// `ProfileDocument` tree, selects nodes by ID, and invokes the same
/// mutation actions the canvas toolbar already uses.
struct LayersPanelView: View {
    let document: ProfileDocument
    @Binding var selectedID: UUID?

    var onDeleteSelected: () -> Void
    var onBringToFront: () -> Void
    var onSendBackward: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(document.pages.indices, id: \.self) { pageIndex in
                        pageRow(pageIndex)
                        ForEach(layerRows(onPage: pageIndex)) { row in
                            layerRow(row)
                        }
                    }
                } header: {
                    Text("Hierarchy")
                }

                Section {
                    Button {
                        onBringToFront()
                    } label: {
                        Label("Bring to Front", systemImage: "square.stack.3d.up")
                    }
                    .disabled(selectedID == nil)

                    Button {
                        onSendBackward()
                    } label: {
                        Label("Send Backward", systemImage: "square.stack.3d.down.right")
                    }
                    .disabled(selectedID == nil)

                    Button(role: .destructive) {
                        onDeleteSelected()
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .disabled(selectedID == nil)
                } header: {
                    Text("Actions")
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func pageRow(_ pageIndex: Int) -> some View {
        let page = document.pages[pageIndex]
        return Button {
            selectedID = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Page \(pageIndex + 1)")
                        .foregroundStyle(.primary)
                    Text("\(Int(document.pageWidth)) x \(Int(page.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedID == nil {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(selectedID == nil && pageIndex == 0 ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func layerRow(_ row: LayerRow) -> some View {
        Button {
            selectedID = row.nodeID
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.icon)
                    .frame(width: 24)
                    .foregroundStyle(row.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selectedID == row.nodeID {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 18)
        }
        .buttonStyle(.plain)
        .listRowBackground(selectedID == row.nodeID ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func layerRows(onPage pageIndex: Int) -> [LayerRow] {
        var rows: [LayerRow] = []
        appendRows(for: document.children(of: nil, onPage: pageIndex), depth: 0, into: &rows)
        return rows
    }

    private func appendRows(for ids: [UUID], depth: Int, into rows: inout [LayerRow]) {
        for id in ids {
            guard let node = document.nodes[id] else { continue }
            rows.append(LayerRow(nodeID: id,
                                 depth: depth,
                                 icon: iconName(for: node),
                                 tint: tint(for: node),
                                 label: label(for: node),
                                 detail: detail(for: node)))
            if node.type == .container {
                appendRows(for: node.childrenIDs, depth: depth + 1, into: &rows)
            }
        }
    }

    private func label(for node: CanvasNode) -> String {
        if let name = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        switch node.type {
        case .container:
            return "Container"
        case .text:
            let text = (node.content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Text" : text
        case .image:
            return node.style.clipShape == .circle ? "Avatar Image" : "Image"
        case .icon:
            let label = (node.content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? "Icon" : label
        case .divider:
            return "Divider"
        case .link:
            let title = (node.content.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Link" : title
        case .gallery:
            return "Gallery"
        case .carousel:
            return "Carousel"
        }
    }

    private func detail(for node: CanvasNode) -> String {
        switch node.type {
        case .container:
            let count = node.childrenIDs.count
            return count == 0 ? "Empty container" : "\(count) child\(count == 1 ? "" : "ren")"
        case .text:
            let weight = node.style.fontWeight ?? .regular
            return "\(Int(node.style.fontSize ?? 18)) pt · \(weight.rawValue.capitalized)"
        case .image:
            let fit = node.style.imageFit ?? .fill
            let shape = node.style.clipShape ?? .rectangle
            return "\(shape == .circle ? "Circle" : "Rectangle") · \(fit == .fill ? "Fill" : "Fit")"
        case .icon:
            let family = (node.style.iconStyleFamily ?? .pastelDoodle).label
            let glyph = node.content.iconName ?? "—"
            return "\(family) · \(glyph)"
        case .divider:
            let family = (node.style.dividerStyleFamily ?? .solid).label
            return family
        case .link:
            let url = (node.content.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let variant = (node.style.linkStyleVariant ?? .pill).label
            return url.isEmpty ? variant : "\(variant) · \(url)"
        case .gallery:
            let count = node.content.imagePaths?.count ?? 0
            let layout = (node.style.galleryLayout ?? .grid).label
            return "\(layout) · \(count) image\(count == 1 ? "" : "s")"
        case .carousel:
            let count = node.childrenIDs.count
            return count == 0 ? "Empty carousel" : "\(count) item\(count == 1 ? "" : "s")"
        }
    }

    private func iconName(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "rectangle.on.rectangle"
        case .text: return "textformat"
        case .image: return "photo"
        case .icon: return "star.fill"
        case .divider: return "minus"
        case .link: return "link"
        case .gallery: return "rectangle.grid.2x2"
        case .carousel: return "rectangle.stack"
        }
    }

    private func tint(for node: CanvasNode) -> Color {
        switch node.type {
        case .container: return .indigo
        case .text: return .orange
        case .image: return .blue
        case .icon: return .pink
        case .divider: return .gray
        case .link: return .green
        case .gallery: return .teal
        case .carousel: return .purple
        }
    }
}

private struct LayerRow: Identifiable {
    let nodeID: UUID
    let depth: Int
    let icon: String
    let tint: Color
    let label: String
    let detail: String

    var id: UUID { nodeID }
}

extension LayersPanelView: Equatable {
    /// The panel walks the entire tree to build its rows, so the
    /// rendering inputs are the document and the current selection.
    /// `selectedID` is a binding here, so we compare its
    /// wrapped value rather than the binding itself (Binding isn't
    /// Equatable). The button actions are closures and stay
    /// out of equality — they capture references that read live
    /// state when invoked.
    static func == (lhs: LayersPanelView, rhs: LayersPanelView) -> Bool {
        // `selectedID` is `@Binding`, so `lhs.selectedID` already
        // resolves to the wrapped `UUID?` (property-wrapper semantics
        // unwrap automatically; the `Binding` itself is reachable
        // only via `$` or `_selectedID`).
        lhs.selectedID == rhs.selectedID && lhs.document == rhs.document
    }
}
