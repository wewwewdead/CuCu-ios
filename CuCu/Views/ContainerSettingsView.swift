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
                    CucuSectionLabel(text: "Live preview")
                }

                Section {
                    Picker(selection: $data.axis) {
                        ForEach(ContainerAxis.allCases, id: \.self) { axis in
                            Text(axis.rawValue.capitalized).tag(axis)
                        }
                    } label: {
                        Text("Axis").font(.cucuSerif(15, weight: .semibold)).foregroundStyle(Color.cucuInk)
                    }
                    .pickerStyle(.segmented)

                    Picker(selection: $data.contentAlignment) {
                        ForEach(ContainerContentAlignment.allCases, id: \.self) { value in
                            Text(value.rawValue.capitalized).tag(value)
                        }
                    } label: {
                        Text("Children align").font(.cucuSerif(15, weight: .semibold)).foregroundStyle(Color.cucuInk)
                    }
                    .pickerStyle(.segmented)

                    StyleSliderRow(label: "Spacing", value: $data.spacing, range: 0...60)
                } header: {
                    CucuSectionLabel(text: "Layout")
                }

                Section {
                    Picker(selection: $data.clipShape) {
                        ForEach(ContainerClipShape.allCases, id: \.self) { shape in
                            Text(shape.rawValue.capitalized).tag(shape)
                        }
                    } label: {
                        Text("Clip").font(.cucuSerif(15, weight: .semibold)).foregroundStyle(Color.cucuInk)
                    }
                    .pickerStyle(.segmented)

                    StyleSliderRow(label: "Corner radius",
                                   value: $data.cornerRadius,
                                   range: 0...60)
                        .disabled(data.clipShape == .circle)

                    StyleSliderRow(label: "Padding", value: $data.padding, range: 0...40)

                    Picker(selection: $data.widthStyle) {
                        ForEach(BlockWidthStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    } label: {
                        Text("Width").font(.cucuSerif(15, weight: .semibold)).foregroundStyle(Color.cucuInk)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    CucuSectionLabel(text: "Shape")
                }

                Section {
                    ColorControlRow(label: "Color",
                                    hex: $data.backgroundColorHex,
                                    supportsAlpha: true)
                } header: {
                    CucuSectionLabel(text: "Background")
                }
            }
            .cucuFormBackdrop()
            .cucuSheetTitle("Container")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(data)
                        dismiss()
                    }
                    .font(.cucuSerif(16, weight: .bold))
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
