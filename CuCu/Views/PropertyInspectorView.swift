import PhotosUI
import SwiftUI
import UIKit

/// Compact property inspector for the selected node. Lays controls out
/// as a horizontally-scrolling row of "tool cards" instead of a
/// vertical Form — a horizontal layout fits a bottom sheet's compact
/// detent (where the canvas remains visible) without the user having
/// to scroll a tall form away from the editing target.
///
/// Each card is a self-contained mini-control:
/// - Slider cards for numeric properties (corner radius, border width,
///   font size, opacity).
/// - Color cards with a color swatch + hex readout.
/// - Segmented cards for enum picks (clip shape, fit, alignment).
/// - Text field cards for name and text content.
/// - Image cards (preview + Menu) for picking / replacing / removing /
///   editing the container background or image-node image.
///
/// All cards share the same shell (`cardShell(title:...)`) so the row
/// reads as a consistent palette of tools regardless of the selected
/// node type.
struct PropertyInspectorView: View {
    @Binding var document: ProfileDocument
    let selectedID: UUID
    var onCommit: (ProfileDocument) -> Void
    var onReplaceImage: (UUID, Data) -> Void
    var onSetContainerBackground: (UUID, Data) -> Void
    var onClearContainerBackground: (UUID) -> Void
    var onEditContainerBackground: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var replaceSelection: PhotosPickerItem?
    @State private var containerBgSelection: PhotosPickerItem?
    @State private var pickerLoading = false
    @State private var pickerError: String?

    /// Pending crop work — set after the user picks a photo for the
    /// container's background but before the cropper has confirmed.
    /// The cropper sheet stacks on top of this inspector sheet.
    @State private var pendingContainerCropSource: PendingContainerCrop?

    private struct PendingContainerCrop: Identifiable {
        let id = UUID()
        let nodeID: UUID
        let data: Data
        let aspect: CGFloat
    }

    var body: some View {
        if let node = document.nodes[selectedID] {
            VStack(spacing: 0) {
                header(for: node)
                cardScroll(for: node)
                if let pickerError {
                    Text(pickerError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom, 8)
                }
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: replaceSelection) { _, newItem in
                loadPickerData(newItem) { data in
                    onReplaceImage(selectedID, data)
                }
            }
            .onChange(of: containerBgSelection) { _, newItem in
                loadPickerData(newItem) { data in
                    // Stage the picked bytes for the cropper instead
                    // of saving immediately — the cropper sheet
                    // stacks on top of this inspector sheet, the user
                    // positions the photo, and only then do the bytes
                    // flow into `onSetContainerBackground`.
                    let aspect = aspectForContainer(selectedID)
                    pendingContainerCropSource = PendingContainerCrop(
                        nodeID: selectedID,
                        data: data,
                        aspect: aspect
                    )
                }
            }
            .sheet(item: $pendingContainerCropSource) { source in
                ImageCropperSheet(
                    sourceData: source.data,
                    targetAspect: source.aspect
                ) { croppedData in
                    onSetContainerBackground(source.nodeID, croppedData)
                }
            }
        } else {
            // Node disappeared (deleted while inspector was open) —
            // auto-dismiss instead of leaving a blank modal on screen.
            Color.clear
                .onAppear { dismiss() }
        }
    }

    // MARK: - Header

    private func header(for node: CanvasNode) -> some View {
        HStack(spacing: 12) {
            iconBadge(for: node)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: node))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(typeLabel(for: node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.primary.opacity(0.06)))
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    // MARK: - Card scroll

    @ViewBuilder
    private func cardScroll(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 10) {
                switch node.type {
                case .container: containerCards(node: node)
                case .text:      textCards(node: node)
                case .image:     imageCards(node: node)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollClipDisabled()
    }

    // MARK: - Card shell

    @ViewBuilder
    private func cardShell<Content: View>(
        title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: width, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
        )
    }

    // MARK: - Card kinds

    private func sliderCard(title: String,
                            binding: Binding<Double>,
                            range: ClosedRange<Double>,
                            step: Double.Stride,
                            valueLabel: String) -> some View {
        cardShell(title: title, width: 210) {
            HStack(spacing: 8) {
                Slider(value: binding, in: range, step: step) { editing in
                    if !editing { onCommit(document) }
                }
                Text(valueLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
    }

    private func segmentedCard<T: Hashable>(
        title: String,
        binding: Binding<T>,
        options: [(T, String)]
    ) -> some View {
        cardShell(title: title, width: 180) {
            Picker("", selection: binding) {
                ForEach(options, id: \.0) { (value, label) in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: binding.wrappedValue) { _, _ in onCommit(document) }
        }
    }

    private func colorCard(title: String, hex: Binding<String>) -> some View {
        cardShell(title: title, width: 140) {
            HStack(spacing: 10) {
                ColorPicker("", selection: hex.asColor(), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32, height: 32)
                    .onChange(of: hex.wrappedValue) { _, _ in onCommit(document) }
                Text(hex.wrappedValue.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func textFieldCard(title: String,
                               text: Binding<String>,
                               placeholder: String) -> some View {
        cardShell(title: title, width: 220) {
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { onCommit(document) }
        }
    }

    private func fontFamilyCard(node: CanvasNode) -> some View {
        let binding = bindingFontFamily(node.id)
        return cardShell(title: "Font", width: 170) {
            Menu {
                ForEach(NodeFontFamily.allCases, id: \.self) { family in
                    Button {
                        binding.wrappedValue = family
                        onCommit(document)
                    } label: {
                        if family == binding.wrappedValue {
                            Label(label(for: family), systemImage: "checkmark")
                        } else {
                            Text(label(for: family))
                        }
                    }
                }
            } label: {
                HStack {
                    Text(label(for: binding.wrappedValue))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Container background image card. Three states:
    /// - **No image**: a PhotosPicker styled as a "+ Add Image" button.
    /// - **Image set**: a thumbnail with a Menu offering Replace / Edit /
    ///   Remove. A PhotosPicker (hidden) is wired to the Replace action.
    @ViewBuilder
    private func containerImageCard(node: CanvasNode) -> some View {
        cardShell(title: "Image", width: 170) {
            if let path = node.style.backgroundImagePath,
               !path.isEmpty,
               let url = LocalCanvasAssetStore.resolveURL(path),
               let preview = UIImage(contentsOfFile: url.path) {
                Menu {
                    PhotosPicker(
                        selection: $containerBgSelection,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label("Replace", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        onEditContainerBackground(node.id)
                    } label: {
                        Label("Edit", systemImage: "wand.and.stars")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onClearContainerBackground(node.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Set")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("Tap to manage")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                PhotosPicker(
                    selection: $containerBgSelection,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(pickerLoading ? "Loading…" : "Add Image")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                }
                .disabled(pickerLoading)
            }
        }
    }

    /// Image node "Replace" card — like the container image card but
    /// only offers Replace (the image content itself can't be removed
    /// without destroying the node).
    private func imageReplaceCard(node: CanvasNode) -> some View {
        cardShell(title: "Image", width: 170) {
            PhotosPicker(
                selection: $replaceSelection,
                matching: .images,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pickerLoading ? "Loading…" : "Replace")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
            .disabled(pickerLoading)
        }
    }

    // MARK: - Per-type card sets

    @ViewBuilder
    private func containerCards(node: CanvasNode) -> some View {
        textFieldCard(
            title: "Name",
            text: bindingName(node.id),
            placeholder: "e.g. Hero"
        )
        colorCard(
            title: "Background",
            hex: bindingHex(node.id, key: \.style.backgroundColorHex, defaultHex: "#FFFFFF")
        )
        containerImageCard(node: node)
        segmentedCard(
            title: "Shape",
            binding: bindingClip(node.id),
            options: [(.rectangle, "Rect"), (.circle, "Circle")]
        )
        if (bindingClip(node.id).wrappedValue) != .circle {
            sliderCard(
                title: "Corner Radius",
                binding: binding(node.id, key: \.style.cornerRadius),
                range: 0...128,
                step: 1,
                valueLabel: "\(Int(binding(node.id, key: \.style.cornerRadius).wrappedValue))"
            )
        }
        sliderCard(
            title: "Border Width",
            binding: binding(node.id, key: \.style.borderWidth),
            range: 0...12,
            step: 1,
            valueLabel: "\(Int(binding(node.id, key: \.style.borderWidth).wrappedValue))"
        )
        colorCard(
            title: "Border",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#E5E5EA")
        )
        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
        sliderCard(
            title: "Blur",
            binding: bindingOptionalDouble(node.id, key: \.style.containerBlur),
            range: 0...1,
            step: 0.05,
            valueLabel: "\(Int(bindingOptionalDouble(node.id, key: \.style.containerBlur).wrappedValue * 100))%"
        )
        sliderCard(
            title: "Vignette",
            binding: bindingOptionalDouble(node.id, key: \.style.containerVignette),
            range: 0...1,
            step: 0.05,
            valueLabel: "\(Int(bindingOptionalDouble(node.id, key: \.style.containerVignette).wrappedValue * 100))%"
        )
    }

    @ViewBuilder
    private func textCards(node: CanvasNode) -> some View {
        textFieldCard(
            title: "Text",
            text: bindingText(node.id),
            placeholder: "Tap to edit"
        )
        fontFamilyCard(node: node)
        sliderCard(
            title: "Size",
            binding: bindingFontSize(node.id),
            range: 10...72,
            step: 1,
            valueLabel: "\(Int(bindingFontSize(node.id).wrappedValue))"
        )
        colorCard(
            title: "Text Color",
            hex: bindingHex(node.id, key: \.style.textColorHex, defaultHex: "#1C1C1E")
        )
        colorCard(
            title: "Background",
            hex: bindingHex(node.id, key: \.style.backgroundColorHex, defaultHex: "#FFFFFF")
        )
    }

    @ViewBuilder
    private func imageCards(node: CanvasNode) -> some View {
        imageReplaceCard(node: node)
        segmentedCard(
            title: "Fit",
            binding: bindingFit(node.id),
            options: [(.fill, "Fill"), (.fit, "Fit")]
        )
        segmentedCard(
            title: "Shape",
            binding: bindingClip(node.id),
            options: [(.rectangle, "Rect"), (.circle, "Circle")]
        )
        if bindingClip(node.id).wrappedValue != .circle {
            sliderCard(
                title: "Corner Radius",
                binding: binding(node.id, key: \.style.cornerRadius),
                range: 0...128,
                step: 1,
                valueLabel: "\(Int(binding(node.id, key: \.style.cornerRadius).wrappedValue))"
            )
        }
        sliderCard(
            title: "Border Width",
            binding: binding(node.id, key: \.style.borderWidth),
            range: 0...12,
            step: 1,
            valueLabel: "\(Int(binding(node.id, key: \.style.borderWidth).wrappedValue))"
        )
        colorCard(
            title: "Border",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#E5E5EA")
        )
        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
    }

    // MARK: - Display helpers

    private func iconBadge(for node: CanvasNode) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(badgeColor(for: node).opacity(colorScheme == .dark ? 0.22 : 0.16))
            Image(systemName: iconName(for: node))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(badgeColor(for: node))
        }
        .frame(width: 32, height: 32)
    }

    private func badgeColor(for node: CanvasNode) -> Color {
        switch node.type {
        case .container: return .indigo
        case .text:      return .orange
        case .image:     return .blue
        }
    }

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

    private func displayName(for node: CanvasNode) -> String {
        if let trimmed = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return typeLabel(for: node)
    }

    private func label(for font: NodeFontFamily) -> String {
        switch font {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Mono"
        }
    }

    /// Aspect ratio of a container's frame — used to size the
    /// cropper window so the saved image matches what the container
    /// will actually display. Falls back to portrait phone aspect
    /// for a degenerate / missing frame.
    private func aspectForContainer(_ id: UUID) -> CGFloat {
        guard let node = document.nodes[id],
              node.frame.width > 0,
              node.frame.height > 0
        else { return 9.0 / 19.5 }
        return CGFloat(node.frame.width / node.frame.height)
    }

    // MARK: - Picker handling

    private func loadPickerData(_ item: PhotosPickerItem?, callback: @escaping (Data) -> Void) {
        guard let item else { return }
        pickerLoading = true
        pickerError = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        callback(data)
                        pickerLoading = false
                        replaceSelection = nil
                        containerBgSelection = nil
                    }
                } else {
                    await MainActor.run {
                        pickerError = "Couldn't read that image."
                        pickerLoading = false
                        replaceSelection = nil
                        containerBgSelection = nil
                    }
                }
            } catch {
                await MainActor.run {
                    pickerError = "Couldn't read that image."
                    pickerLoading = false
                    replaceSelection = nil
                    containerBgSelection = nil
                }
            }
        }
    }

    // MARK: - Bindings

    private func bindingText(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.text ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.text = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.name ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                node.name = trimmed.isEmpty ? nil : newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingFontFamily(_ id: UUID) -> Binding<NodeFontFamily> {
        Binding(
            get: { document.nodes[id]?.style.fontFamily ?? .system },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.fontFamily = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingFontSize(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style.fontSize ?? 17 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.fontSize = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingFit(_ id: UUID) -> Binding<NodeImageFit> {
        Binding(
            get: { document.nodes[id]?.style.imageFit ?? .fill },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.imageFit = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingClip(_ id: UUID) -> Binding<NodeClipShape> {
        Binding(
            get: { document.nodes[id]?.style.clipShape ?? .rectangle },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.clipShape = newValue
                // Switching to circle snaps the frame to a square so
                // the result is a true circle, not a capsule.
                if newValue == .circle {
                    let side = min(node.frame.width, node.frame.height)
                    node.frame.width = side
                    node.frame.height = side
                }
                document.nodes[id] = node
            }
        )
    }

    private func binding(_ id: UUID, key: WritableKeyPath<CanvasNode, Double>) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?[keyPath: key] ?? 0 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Bridge a `Double?` field (storing nil for "off") to a slider's
    /// `Double` binding. Sets the field to nil when the value rolls
    /// down to zero so the JSON envelope stays minimal.
    private func bindingOptionalDouble(_ id: UUID,
                                       key: WritableKeyPath<CanvasNode, Double?>) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?[keyPath: key] ?? 0 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node[keyPath: key] = newValue > 0.01 ? newValue : nil
                document.nodes[id] = node
            }
        )
    }

    private func bindingHex(_ id: UUID,
                            key: WritableKeyPath<CanvasNode, String?>,
                            defaultHex: String) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?[keyPath: key] ?? defaultHex },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }
}
