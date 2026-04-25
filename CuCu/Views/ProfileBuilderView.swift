import SwiftUI
import SwiftData

/// Top-level editor for a draft's design.
///
/// The builder owns the draft's in-memory `ProfileDesign` and the editor
/// chrome (title, theme button, publish button, floating Add Block bar).
/// The actual list-of-blocks editing — including drilling into containers —
/// is delegated to `BlockEditingArea`, which is reused inside containers
/// for recursive editing.
///
/// Persistence: any mutation to `design` triggers `.onChange`, which
/// re-encodes the JSON and saves the SwiftData record. There is no manual
/// Save button; edits are continuously persisted.
struct ProfileBuilderView: View {
    @Bindable var draft: ProfileDraft
    @Environment(\.modelContext) private var context

    @State private var design: ProfileDesign = .defaultDesign()
    @State private var isAddingBlock = false
    @State private var isEditingTheme = false
    @State private var isPublishing = false
    @State private var didLoad = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                titleField
                    .padding(.horizontal, design.theme.pageHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                if design.blocks.isEmpty {
                    emptyState
                } else {
                    BlockEditingArea(
                        blocks: $design.blocks,
                        theme: design.theme,
                        draftID: draft.id
                    )
                }
            }

            VStack {
                Spacer()
                EditorToolbar(
                    onAddBlock: { isAddingBlock = true },
                    onEditTheme: { isEditingTheme = true }
                )
                .padding(.bottom, 16)
            }
        }
        // Background lives in `.background` so it can call `.ignoresSafeArea`
        // without competing with safe-area-respecting siblings inside the
        // ZStack — otherwise the safe-area-ignoring image visually covers
        // the floating toolbar.
        .background {
            ZStack {
                Color(hex: design.theme.backgroundColorHex)
                if let path = design.theme.backgroundImagePath,
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
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS) || os(visionOS)
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPublishing = true
                } label: {
                    Image(systemName: draft.publishedProfileId == nil
                          ? "paperplane"
                          : "paperplane.fill")
                }
                .accessibilityLabel("Publish")
            }
        }
        .sheet(isPresented: $isAddingBlock) {
            AddBlockSheet(
                draftID: draft.id,
                onAddText: addTextBlock,
                onAddImage: addImageBlock,
                onAddContainer: addContainer
            )
        }
        .sheet(isPresented: $isEditingTheme) {
            ThemeEditorView(initial: design.theme, draftID: draft.id) { newTheme in
                design.theme = newTheme
            }
        }
        .sheet(isPresented: $isPublishing) {
            PublishSheet(draft: draft, design: design)
        }
        .task {
            if !didLoad {
                design = DesignJSONCoder.decode(draft.designJSON)
                didLoad = true
            }
        }
        .onChange(of: design) { _, newValue in
            persist(newValue)
        }
    }

    // MARK: - Subviews

    private var titleField: some View {
        TextField(
            "Untitled",
            text: Binding(
                get: { draft.title },
                set: { newValue in
                    draft.title = newValue
                    draft.updatedAt = .now
                }
            )
        )
        .font(.system(size: 28, weight: .bold, design: design.theme.defaultFontName.design))
        .foregroundStyle(Color(hex: design.theme.defaultTextColorHex))
        .textFieldStyle(.plain)
        .submitLabel(.done)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 116, height: 116)
                    .overlay(Circle().stroke(.quaternary, lineWidth: 1))
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text("Start with a blank canvas")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(hex: design.theme.defaultTextColorHex))
                Text("Add a text block, an image, or a container to start building your profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Adders (top-level)

    private func addTextBlock() {
        design.blocks.append(.text(.placeholder(theme: design.theme)))
    }

    private func addImageBlock(_ data: ImageBlockData) {
        design.blocks.append(.image(data))
    }

    private func addContainer() {
        design.blocks.append(.container(.newContainer()))
    }

    // MARK: - Persistence

    private func persist(_ design: ProfileDesign) {
        // Avoid clobbering the on-disk JSON with the default state during the
        // brief window between view appearance and the initial decode.
        guard didLoad else { return }
        guard let json = try? DesignJSONCoder.encode(design) else { return }
        draft.designJSON = json
        draft.updatedAt = .now
        try? context.save()
    }
}
