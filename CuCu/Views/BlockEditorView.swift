import SwiftUI

/// Type-dispatch shell. Each block type routes to its own editor here so this
/// file stays the single entry point from the builder. `draftID` is threaded
/// through for editors that touch the on-disk asset folder (image blocks).
struct BlockEditorView: View {
    let initialBlock: ProfileBlock
    let theme: ProfileTheme
    let draftID: UUID
    let onSave: (ProfileBlock) -> Void

    var body: some View {
        switch initialBlock {
        case .text(let data):
            TextBlockEditor(initial: data, theme: theme) { updated in
                onSave(.text(updated))
            }
        case .image(let data):
            ImageBlockEditorView(initial: data, theme: theme, draftID: draftID) { updated in
                onSave(.image(updated))
            }
        case .container(let data):
            // Containers normally drill in (NavigationLink in BlockEditingArea),
            // so this branch only runs if something else opens the dispatcher
            // for a container — route to the styling-only sheet and preserve
            // children. The caller is responsible for re-attaching `children`.
            ContainerSettingsView(initial: data) { updated in
                onSave(.container(updated))
            }
        }
    }
}

/// Save/Cancel sheet with a live preview pinned at the top of the form.
///
/// Edits mutate local `@State`; nothing flows back to SwiftData until the user
/// taps Save. This avoids persisting partial state, but the preview at the top
/// updates on every keystroke so the UX still feels live.
private struct TextBlockEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data: TextBlockData
    let theme: ProfileTheme
    let onSave: (TextBlockData) -> Void

    init(initial: TextBlockData,
         theme: ProfileTheme,
         onSave: @escaping (TextBlockData) -> Void) {
        self._data = State(initialValue: initial)
        self.theme = theme
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    livePreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Live preview")
                }

                Section("Content") {
                    TextEditor(text: $data.content)
                        .frame(minHeight: 120)
                        .font(.system(size: data.fontSize, design: data.fontName.design))
                }

                Section("Typography") {
                    FontPickerView(label: "Font", selection: $data.fontName)
                    StyleSliderRow(label: "Size", value: $data.fontSize, range: 10...80)
                    Picker("Alignment", selection: $data.alignment) {
                        ForEach(ProfileTextAlignment.allCases, id: \.self) { align in
                            Text(align.rawValue.capitalized).tag(align)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Colors") {
                    ColorControlRow(label: "Text", hex: $data.textColorHex, supportsAlpha: false)
                    ColorControlRow(label: "Background", hex: $data.backgroundColorHex, supportsAlpha: true)
                }

                Section("Shape") {
                    StyleSliderRow(label: "Corner radius", value: $data.cornerRadius, range: 0...40)
                    StyleSliderRow(label: "Padding", value: $data.padding, range: 0...40)
                    Picker("Width", selection: $data.widthStyle) {
                        ForEach(BlockWidthStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Edit Text")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(data)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// The preview is rendered on the actual page background so the user sees
    /// the block in context, not on a neutral surface.
    private var livePreview: some View {
        ZStack {
            Color(hex: theme.backgroundColorHex)
            ProfileBlockView(block: .text(data))
                .padding(.horizontal, theme.pageHorizontalPadding)
                .padding(.vertical, 24)
        }
        .frame(minHeight: 140)
    }
}
