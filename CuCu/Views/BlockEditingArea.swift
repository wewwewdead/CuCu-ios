import SwiftUI

/// Reusable List-based editor for any `[ProfileBlock]` array — used at the
/// top level (binding to `design.blocks`) and inside a container's drill-in
/// (binding to `container.children`). All editing affordances live here so
/// the recursion is purely a data binding swap.
///
/// Tap on a text/image block opens the property sheet (`BlockEditorView`).
/// Tap on a container pushes a `ContainerEditorView` onto the navigation
/// stack so the user can edit that container's own children.
struct BlockEditingArea: View {
    @Binding var blocks: [ProfileBlock]
    let theme: ProfileTheme
    let draftID: UUID

    @State private var editingSelection: BlockEditingSelection?

    var body: some View {
        List {
            ForEach($blocks) { $block in
                BlockEditingRow(
                    block: $block,
                    theme: theme,
                    draftID: draftID,
                    onEditProperties: { current in
                        editingSelection = BlockEditingSelection(id: current.id, block: current)
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: theme.blockSpacing / 2,
                    leading: theme.pageHorizontalPadding,
                    bottom: theme.blockSpacing / 2,
                    trailing: theme.pageHorizontalPadding
                ))
            }
            .onMove(perform: moveBlocks)
            .onDelete(perform: deleteBlocks)

            // Keep the floating Add button from covering the last row.
            Color.clear
                .frame(height: 96)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sheet(item: $editingSelection) { sel in
            BlockEditorView(
                initialBlock: sel.block,
                theme: theme,
                draftID: draftID
            ) { updated in
                if let idx = blocks.firstIndex(where: { $0.id == updated.id }) {
                    blocks[idx] = updated
                }
            }
        }
    }

    private func moveBlocks(from offsets: IndexSet, to destination: Int) {
        blocks.move(fromOffsets: offsets, toOffset: destination)
    }

    private func deleteBlocks(at offsets: IndexSet) {
        // Recurse into containers so deleting a container also scrubs the
        // image files of every nested image block — keeps Application
        // Support tidy without leaking files we'll never reference again.
        for i in offsets {
            for img in blocks[i].imageBlocksDeep {
                LocalAssetStore.delete(relativePath: img.localImagePath)
            }
        }
        blocks.remove(atOffsets: offsets)
    }
}

/// Single row in the editing list. Containers get a NavigationLink wrapper
/// so the user drills in instead of opening a properties sheet; text/image
/// blocks tap straight to their property sheet.
private struct BlockEditingRow: View {
    @Binding var block: ProfileBlock
    let theme: ProfileTheme
    let draftID: UUID
    let onEditProperties: (ProfileBlock) -> Void

    var body: some View {
        switch block {
        case .container:
            NavigationLink {
                ContainerEditorView(
                    container: $block.asContainer,
                    theme: theme,
                    draftID: draftID
                )
            } label: {
                ProfileBlockView(block: block)
                    .overlay(alignment: .topTrailing) { containerBadge }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .text, .image:
            ProfileBlockView(block: block)
                .contentShape(Rectangle())
                .onTapGesture { onEditProperties(block) }
        }
    }

    /// Tiny stack icon in the corner of containers — the only visual
    /// distinction between "tap to edit properties" and "tap to drill in".
    /// Stays unobtrusive: thinMaterial pill, caption-size, only visible
    /// against the row, not in the renderer.
    private var containerBadge: some View {
        Image(systemName: "square.stack.3d.up")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
    }
}

private struct BlockEditingSelection: Identifiable {
    let id: UUID
    var block: ProfileBlock
}

extension Binding where Value == ProfileBlock {
    /// Project a `Binding<ProfileBlock>` whose case is `.container` into a
    /// `Binding<ContainerBlockData>`. Caller is responsible for verifying the
    /// case before reading; the getter falls back to a fresh container value
    /// only as a defensive default.
    var asContainer: Binding<ContainerBlockData> {
        Binding<ContainerBlockData>(
            get: {
                if case .container(let data) = self.wrappedValue { return data }
                return .newContainer()
            },
            set: { newValue in
                self.wrappedValue = .container(newValue)
            }
        )
    }
}
