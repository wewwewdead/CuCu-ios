import SwiftUI

/// Save/Cancel sheet for editing a container's *own* properties (not its
/// children). Mirrors the discipline of the other property sheets: local
/// `@State` copy, no mutation of the parent until Save.
///
/// Children are preserved by the caller — `ContainerEditorView` overlays
/// the returned styling onto the existing children before assigning back.
struct ContainerSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var data: ContainerBlockData
    let onSave: (ContainerBlockData) -> Void

    init(initial: ContainerBlockData, onSave: @escaping (ContainerBlockData) -> Void) {
        self._data = State(initialValue: initial)
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

                Section("Layout") {
                    Picker("Axis", selection: $data.axis) {
                        ForEach(ContainerAxis.allCases, id: \.self) { axis in
                            Text(axis.rawValue.capitalized).tag(axis)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Children align", selection: $data.contentAlignment) {
                        ForEach(ContainerContentAlignment.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    StyleSliderRow(label: "Spacing", value: $data.spacing, range: 0...60)
                }

                Section("Shape") {
                    Picker("Clip", selection: $data.clipShape) {
                        ForEach(ContainerClipShape.allCases, id: \.self) { shape in
                            Text(shape.rawValue.capitalized).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)

                    StyleSliderRow(label: "Corner radius",
                                   value: $data.cornerRadius,
                                   range: 0...60)
                        .disabled(data.clipShape == .circle)

                    StyleSliderRow(label: "Padding", value: $data.padding, range: 0...40)

                    Picker("Width", selection: $data.widthStyle) {
                        ForEach(BlockWidthStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Background") {
                    ColorControlRow(label: "Color",
                                    hex: $data.backgroundColorHex,
                                    supportsAlpha: true)
                }
            }
            .navigationTitle("Container")
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

    /// Shows the container with a couple of placeholder rows inside so the
    /// user can see how their layout choices land before saving. Children
    /// from the actual container are preserved separately by the caller.
    private var livePreview: some View {
        let placeholderChildren: [ProfileBlock] = data.children.isEmpty
            ? sampleChildren
            : data.children
        var preview = data
        preview.children = placeholderChildren
        return ZStack {
            Color.secondary.opacity(0.06)
            ProfileBlockView(block: .container(preview))
                .padding(20)
        }
        .frame(minHeight: 160)
    }

    private var sampleChildren: [ProfileBlock] {
        [
            .text(TextBlockData(
                id: UUID(),
                content: "Sample item",
                fontName: .system,
                fontSize: 16,
                textColorHex: "#1C1C1E",
                backgroundColorHex: "#FFFFFF00",
                cornerRadius: 0,
                padding: 0,
                alignment: .leading,
                widthStyle: .compact
            )),
            .text(TextBlockData(
                id: UUID(),
                content: "Another item",
                fontName: .system,
                fontSize: 14,
                textColorHex: "#666666",
                backgroundColorHex: "#FFFFFF00",
                cornerRadius: 0,
                padding: 0,
                alignment: .leading,
                widthStyle: .compact
            )),
        ]
    }
}
