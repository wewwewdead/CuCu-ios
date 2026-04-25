import SwiftUI

/// Drill-in editor for a single container. Mirrors `ProfileBuilderView`'s
/// structure (header preview, content list, floating toolbar) but operates
/// on the container's own children — so the recursion just feels like
/// opening a folder.
///
/// The container's binding is shared with the parent list; mutations here
/// flow back up to `design.blocks` and through SwiftData on the next
/// `.onChange` cycle.
struct ContainerEditorView: View {
    @Binding var container: ContainerBlockData
    let theme: ProfileTheme
    let draftID: UUID

    @State private var isAddingBlock = false
    @State private var isEditingSettings = false

    var body: some View {
        ZStack {
            // Inherit the page background so a drilled-in container reads as
            // the same canvas, not a separate sheet.
            BlockEditingArea(blocks: $container.children, theme: theme, draftID: draftID)

            VStack {
                Spacer()
                EditorToolbar(
                    onAddBlock: { isAddingBlock = true },
                    onEditTheme: { isEditingSettings = true }
                )
                .padding(.bottom, 16)
            }
        }
        .background {
            ZStack {
                Color(hex: theme.backgroundColorHex)
                if let path = theme.backgroundImagePath,
                   let img = LocalAssetStore.loadImage(relativePath: path) {
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
            .ignoresSafeArea()
        }
        .navigationTitle("Container")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Container settings")
            }
        }
        .sheet(isPresented: $isAddingBlock) {
            AddBlockSheet(
                draftID: draftID,
                onAddText: addTextBlock,
                onAddImage: addImageBlock,
                onAddContainer: addContainer
            )
        }
        .sheet(isPresented: $isEditingSettings) {
            ContainerSettingsView(initial: container) { updated in
                // Preserve children; the settings sheet only edits styling.
                var copy = updated
                copy.children = container.children
                container = copy
            }
        }
    }

    // MARK: - Adders (append to this container's children)

    private func addTextBlock() {
        container.children.append(.text(.placeholder(theme: theme)))
    }

    private func addImageBlock(_ data: ImageBlockData) {
        container.children.append(.image(data))
    }

    private func addContainer() {
        container.children.append(.container(.newContainer()))
    }
}
