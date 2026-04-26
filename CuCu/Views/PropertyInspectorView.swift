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
    var onReplaceImage: (UUID, Data) -> Bool
    var onSetContainerBackground: (UUID, Data) -> Bool
    var onClearContainerBackground: (UUID) -> Void
    var onEditContainerBackground: (UUID) -> Void
    /// Append picked image bytes to a `.gallery` node. Host writes each
    /// image to `LocalCanvasAssetStore` under a fresh per-image UUID
    /// and returns `true` when *all* bytes saved cleanly. Provided as
    /// a callback rather than handled inline so the host owns the
    /// draft-id / asset-folder coupling.
    var onAppendGalleryImages: (UUID, [Data]) -> Bool
    /// Remove the image at `index` from a `.gallery` node's
    /// `imagePaths`. Host deletes the underlying file if no longer
    /// referenced and updates the document.
    var onRemoveGalleryImage: (UUID, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var replaceSelection: PhotosPickerItem?
    @State private var containerBgSelection: PhotosPickerItem?
    /// Multi-selection picker driving gallery image additions.
    @State private var gallerySelection: [PhotosPickerItem] = []
    @State private var pickerLoading = false
    @State private var pickerError: String?
    /// When non-nil, the icon-picker grid sheet is presented for this
    /// node. The sheet writes the chosen SF Symbol back through the
    /// node's `bindingIconName` and runs `onCommit(document)`.
    @State private var iconPickerNodeID: UUID?
    /// When non-nil, the font-family picker sheet is presented for
    /// this node. Mirrors `iconPickerNodeID`'s pattern so opening
    /// the picker for one node never leaks state to another.
    @State private var fontPickerNodeID: UUID?

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

    /// Identifiable wrapper so `.sheet(item:)` can present the icon
    /// grid keyed off the target node ID. The struct is the SwiftUI
    /// re-presentation key — opening the picker for a different node
    /// dismisses + re-presents the sheet cleanly.
    private struct IconPickerTarget: Identifiable, Equatable {
        let nodeID: UUID
        var id: UUID { nodeID }
    }

    /// Same pattern as `IconPickerTarget`, but for the font-family
    /// sheet. Both sheets stay in lockstep with the rest of the
    /// `.sheet(item:)`-driven modals on this screen.
    private struct FontPickerTarget: Identifiable, Equatable {
        let nodeID: UUID
        var id: UUID { nodeID }
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
            .background(Color.cucuPaper.ignoresSafeArea())
            .tint(Color.cucuMoss)
            .onChange(of: replaceSelection) { _, newItem in
                loadPickerData(newItem) { data in
                    onReplaceImage(selectedID, data)
                }
            }
            .onChange(of: gallerySelection) { _, newItems in
                guard !newItems.isEmpty else { return }
                loadGalleryPickerData(newItems)
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
                    return true
                }
            }
            .sheet(item: $pendingContainerCropSource) { source in
                ImageCropperSheet(
                    sourceData: source.data,
                    targetAspect: source.aspect
                ) { croppedData in
                    if !onSetContainerBackground(source.nodeID, croppedData) {
                        pickerError = "Couldn't save that image."
                    }
                }
            }
            // Icon-picker grid. Driven by the per-node ID so opening
            // the picker for one node doesn't carry stale state if
            // the user selects a different node mid-flow. The
            // `bindingIconName` writes through `document.nodes[id]`
            // so the canvas rebinds on the next reconciliation pass.
            .sheet(item: Binding(
                get: { iconPickerNodeID.map { IconPickerTarget(nodeID: $0) } },
                set: { iconPickerNodeID = $0?.nodeID }
            )) { target in
                IconPickerSheet(
                    selection: bindingIconName(target.nodeID),
                    onCommit: { onCommit(document) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            // Font-picker sheet. Same `.sheet(item:)` driven approach
            // as the icon picker so a node-switch mid-flow tears the
            // sheet down cleanly. The picker itself reads / writes
            // `bindingFontFamily(nodeID)`.
            .sheet(item: Binding(
                get: { fontPickerNodeID.map { FontPickerTarget(nodeID: $0) } },
                set: { fontPickerNodeID = $0?.nodeID }
            )) { target in
                FontPickerSheet(
                    selection: bindingFontFamily(target.nodeID),
                    onCommit: { onCommit(document) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        VStack(alignment: .leading, spacing: 8) {
            CucuSpecLine(figure: "fig. 04 — inspector",
                         trailing: typeLabel(for: node))
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                iconBadge(for: node)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: node))
                        .font(.cucuSerif(20, weight: .bold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Text(typeLabel(for: node))
                        .font(.cucuSans(12, weight: .medium))
                        .foregroundStyle(Color.cucuInkFaded)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color.cucuInk)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.cucuCard))
                        .overlay(Circle().strokeBorder(Color.cucuInk, lineWidth: 1))
                }
                .buttonStyle(CucuPressableButtonStyle())
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
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
                case .icon:      iconCards(node: node)
                case .divider:   dividerCards(node: node)
                case .link:      linkCards(node: node)
                case .gallery:   galleryCards(node: node)
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
            Text(title)
                .font(.cucuSerif(11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Color.cucuInkSoft)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: width, height: 84)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cucuCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1)
        )
        .shadow(color: Color.cucuInk.opacity(0.10), radius: 8, x: 0, y: 3)
    }

    // MARK: - Card kinds

    private func sliderCard(title: String,
                            binding: Binding<Double>,
                            range: ClosedRange<Double>,
                            step: Double.Stride,
                            valueLabel: String) -> some View {
        cardShell(title: title, width: 220) {
            HStack(spacing: 8) {
                Slider(value: binding, in: range, step: step) { editing in
                    if !editing { onCommit(document) }
                }
                .tint(Color.cucuMoss)
                CucuValuePill(text: valueLabel)
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
        cardShell(title: title, width: 150) {
            HStack(spacing: 10) {
                ColorPicker("", selection: hex.asColor(), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 32, height: 32)
                    .onChange(of: hex.wrappedValue) { _, _ in onCommit(document) }
                Text(hex.wrappedValue.uppercased())
                    .font(.cucuMono(11, weight: .medium))
                    .foregroundStyle(Color.cucuInkSoft)
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
                .font(.cucuSerif(15, weight: .regular))
                .foregroundStyle(Color.cucuInk)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { onCommit(document) }
        }
    }

    private func fontFamilyCard(node: CanvasNode) -> some View {
        let binding = bindingFontFamily(node.id)
        let nodeID = node.id
        let family = binding.wrappedValue
        return cardShell(title: "Font", width: 200) {
            Button {
                fontPickerNodeID = nodeID
            } label: {
                HStack(spacing: 8) {
                    // Live preview "Aa" rendered in the family the
                    // text node will actually use — gives the user a
                    // glance at what tapping into the picker will
                    // reveal without opening it.
                    Text("Aa")
                        .font(family.swiftUIFont(size: 22, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .frame(width: 36, alignment: .leading)
                    Text(family.displayName)
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func fontWeightCard(node: CanvasNode) -> some View {
        let binding = bindingFontWeight(node.id)
        return cardShell(title: "Weight", width: 170) {
            Menu {
                ForEach(NodeFontWeight.allCases, id: \.self) { weight in
                    Button {
                        binding.wrappedValue = weight
                        onCommit(document)
                    } label: {
                        if weight == binding.wrappedValue {
                            Label(label(for: weight), systemImage: "checkmark")
                        } else {
                            Text(label(for: weight))
                        }
                    }
                }
            } label: {
                HStack {
                    Text(label(for: binding.wrappedValue))
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
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
               let preview = LocalCanvasAssetStore.loadUIImage(path) {
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
                                .font(.cucuSerif(14, weight: .semibold))
                                .foregroundStyle(Color.cucuInk)
                            Text("Tap to manage")
                                .font(.cucuSans(10, weight: .regular))
                                .foregroundStyle(Color.cucuInkFaded)
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.cucuInkSoft)
                        Text(pickerLoading ? "Loading…" : "Add Image")
                            .font(.cucuSerif(14, weight: .semibold))
                            .foregroundStyle(Color.cucuInk)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.cucuInkSoft)
                    Text(pickerLoading ? "Loading…" : "Replace")
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
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
        fontWeightCard(node: node)
        sliderCard(
            title: "Size",
            binding: bindingFontSize(node.id),
            range: 10...72,
            step: 1,
            valueLabel: "\(Int(bindingFontSize(node.id).wrappedValue))"
        )
        sliderCard(
            title: "Line Spacing",
            binding: bindingLineSpacing(node.id),
            range: 0...20,
            step: 0.5,
            valueLabel: String(format: "%.1f", bindingLineSpacing(node.id).wrappedValue)
        )
        colorCard(
            title: "Text Color",
            hex: bindingHex(node.id, key: \.style.textColorHex, defaultHex: "#1C1C1E")
        )
        segmentedCard(
            title: "Align",
            binding: bindingTextAlignment(node.id),
            options: [(.leading, "Left"), (.center, "Center"), (.trailing, "Right")]
        )

        // ── Background styling — color / radius / border / padding ──
        // Grouped together so the cards read as "this is what the
        // text's background does". Padding is in this cluster too
        // because it controls how much room the text gets inside the
        // background fill.
        colorCard(
            title: "Background",
            hex: bindingHex(node.id, key: \.style.backgroundColorHex, defaultHex: "#FFFFFF")
        )
        sliderCard(
            title: "Padding",
            binding: bindingPadding(node.id),
            range: 0...60,
            step: 1,
            valueLabel: "\(Int(bindingPadding(node.id).wrappedValue))"
        )
        sliderCard(
            title: "Corner Radius",
            binding: binding(node.id, key: \.style.cornerRadius),
            range: 0...64,
            step: 1,
            valueLabel: "\(Int(binding(node.id, key: \.style.cornerRadius).wrappedValue))"
        )
        sliderCard(
            title: "Border Width",
            binding: binding(node.id, key: \.style.borderWidth),
            range: 0...8,
            step: 0.5,
            valueLabel: String(format: "%.1f", binding(node.id, key: \.style.borderWidth).wrappedValue)
        )
        colorCard(
            title: "Border",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#1A140E")
        )

        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
    }

    // MARK: - Icon cards

    @ViewBuilder
    private func iconCards(node: CanvasNode) -> some View {
        iconStyleFamilyCard(node: node)
        iconGlyphCard(node: node)
        textFieldCard(
            title: "Label",
            text: bindingText(node.id),
            placeholder: "Optional"
        )
        colorCard(
            title: "Tint",
            hex: bindingHex(node.id, key: \.style.tintColorHex, defaultHex: "#B22A4A")
        )
        colorCard(
            title: "Plate",
            hex: bindingHex(node.id, key: \.style.backgroundColorHex, defaultHex: "#FFE3EC")
        )
        sliderCard(
            title: "Border Width",
            binding: binding(node.id, key: \.style.borderWidth),
            range: 0...8,
            step: 0.5,
            valueLabel: "\(Int(binding(node.id, key: \.style.borderWidth).wrappedValue))"
        )
        colorCard(
            title: "Border",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#1A140E")
        )
        sliderCard(
            title: "Corner Radius",
            binding: binding(node.id, key: \.style.cornerRadius),
            range: 0...64,
            step: 1,
            valueLabel: "\(Int(binding(node.id, key: \.style.cornerRadius).wrappedValue))"
        )
        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
    }

    /// Menu over the 12 icon families. Each row shows the family's
    /// label with a checkmark next to the active one.
    private func iconStyleFamilyCard(node: CanvasNode) -> some View {
        let binding = bindingIconStyleFamily(node.id)
        return cardShell(title: "Style", width: 200) {
            Menu {
                ForEach(NodeIconStyleFamily.allCases, id: \.self) { family in
                    Button {
                        binding.wrappedValue = family
                        onCommit(document)
                    } label: {
                        if family == binding.wrappedValue {
                            Label(family.label, systemImage: "checkmark")
                        } else {
                            Text(family.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(binding.wrappedValue.label)
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
        }
    }

    /// Tile that opens the full-screen icon-picker grid. The grid
    /// itself lives in `IconPickerSheet`; this card just shows the
    /// current selection + a chevron and wires the sheet up via the
    /// `iconPickerNodeID` state. Replaced an inline `Menu` over the
    /// flat 90-icon catalog (the menu had become a long, awkward
    /// scroll once the social-profile icons landed).
    private func iconGlyphCard(node: CanvasNode) -> some View {
        let binding = bindingIconName(node.id)
        let nodeID = node.id
        return cardShell(title: "Icon", width: 180) {
            Button {
                iconPickerNodeID = nodeID
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: binding.wrappedValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Text(IconCatalog.label(for: binding.wrappedValue))
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Divider cards

    @ViewBuilder
    private func dividerCards(node: CanvasNode) -> some View {
        dividerStyleFamilyCard(node: node)
        colorCard(
            title: "Color",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#B22A4A")
        )
        sliderCard(
            title: "Thickness",
            binding: bindingDividerThickness(node.id),
            range: 0.5...10,
            step: 0.5,
            valueLabel: String(format: "%.1f", bindingDividerThickness(node.id).wrappedValue)
        )
        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
    }

    private func dividerStyleFamilyCard(node: CanvasNode) -> some View {
        let binding = bindingDividerStyleFamily(node.id)
        return cardShell(title: "Style", width: 200) {
            Menu {
                ForEach(NodeDividerStyleFamily.allCases, id: \.self) { family in
                    Button {
                        binding.wrappedValue = family
                        onCommit(document)
                    } label: {
                        if family == binding.wrappedValue {
                            Label(family.label, systemImage: "checkmark")
                        } else {
                            Text(family.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(binding.wrappedValue.label)
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
        }
    }

    // MARK: - Link cards

    @ViewBuilder
    private func linkCards(node: CanvasNode) -> some View {
        textFieldCard(
            title: "Title",
            text: bindingText(node.id),
            placeholder: "my link"
        )
        textFieldCard(
            title: "URL",
            text: bindingURL(node.id),
            placeholder: "https://"
        )
        linkStyleVariantCard(node: node)
        iconGlyphCard(node: node) // optional leading icon
        colorCard(
            title: "Text",
            hex: bindingHex(node.id, key: \.style.textColorHex, defaultHex: "#1A140E")
        )
        colorCard(
            title: "Background",
            hex: bindingHex(node.id, key: \.style.backgroundColorHex, defaultHex: "#FBF6E9")
        )
        sliderCard(
            title: "Border Width",
            binding: binding(node.id, key: \.style.borderWidth),
            range: 0...6,
            step: 0.5,
            valueLabel: "\(Int(binding(node.id, key: \.style.borderWidth).wrappedValue))"
        )
        colorCard(
            title: "Border",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#1A140E")
        )
        sliderCard(
            title: "Corner Radius",
            binding: binding(node.id, key: \.style.cornerRadius),
            range: 0...32,
            step: 1,
            valueLabel: "\(Int(binding(node.id, key: \.style.cornerRadius).wrappedValue))"
        )
        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
    }

    private func linkStyleVariantCard(node: CanvasNode) -> some View {
        let binding = bindingLinkStyleVariant(node.id)
        return cardShell(title: "Style", width: 180) {
            Menu {
                ForEach(NodeLinkStyleVariant.allCases, id: \.self) { variant in
                    Button {
                        binding.wrappedValue = variant
                        onCommit(document)
                    } label: {
                        if variant == binding.wrappedValue {
                            Label(variant.label, systemImage: "checkmark")
                        } else {
                            Text(variant.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(binding.wrappedValue.label)
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
        }
    }

    // MARK: - Gallery cards

    @ViewBuilder
    private func galleryCards(node: CanvasNode) -> some View {
        galleryAddImagesCard(node: node)
        galleryImagesListCard(node: node)
        galleryLayoutCard(node: node)
        segmentedCard(
            title: "Fit",
            binding: bindingGalleryImageFit(node.id),
            options: [(.fit, "Fit"), (.fill, "Fill")]
        )
        sliderCard(
            title: "Gap",
            binding: bindingGalleryGap(node.id),
            range: 0...20,
            step: 1,
            valueLabel: "\(Int(bindingGalleryGap(node.id).wrappedValue))"
        )
        sliderCard(
            title: "Corner Radius",
            binding: binding(node.id, key: \.style.cornerRadius),
            range: 0...32,
            step: 1,
            valueLabel: "\(Int(binding(node.id, key: \.style.cornerRadius).wrappedValue))"
        )
        sliderCard(
            title: "Border Width",
            binding: binding(node.id, key: \.style.borderWidth),
            range: 0...6,
            step: 0.5,
            valueLabel: "\(Int(binding(node.id, key: \.style.borderWidth).wrappedValue))"
        )
        colorCard(
            title: "Border",
            hex: bindingHex(node.id, key: \.style.borderColorHex, defaultHex: "#1A140E")
        )
        sliderCard(
            title: "Opacity",
            binding: binding(node.id, key: \.opacity),
            range: 0...1,
            step: 0.01,
            valueLabel: "\(Int(binding(node.id, key: \.opacity).wrappedValue * 100))%"
        )
    }

    /// PhotosPicker that appends to the gallery's `imagePaths`. Multi-
    /// selection up to 12 images at a time so the user can build a
    /// gallery in one go.
    private func galleryAddImagesCard(node: CanvasNode) -> some View {
        cardShell(title: "Add Images", width: 180) {
            PhotosPicker(
                selection: $gallerySelection,
                maxSelectionCount: 12,
                matching: .images,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.cucuInkSoft)
                    Text(pickerLoading ? "Loading…" : "Pick Photos")
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer(minLength: 0)
                }
            }
            .disabled(pickerLoading)
        }
    }

    /// Vertical scrolling list of the gallery's current images with a
    /// remove button per row. Compact layout so the card stays in the
    /// 84pt row height.
    private func galleryImagesListCard(node: CanvasNode) -> some View {
        cardShell(title: "Images", width: 200) {
            let paths = node.content.imagePaths ?? []
            if paths.isEmpty {
                Text("Empty gallery")
                    .font(.cucuSans(12, weight: .medium))
                    .foregroundStyle(Color.cucuInkFaded)
            } else {
                Menu {
                    ForEach(Array(paths.enumerated()), id: \.offset) { (index, _) in
                        Button(role: .destructive) {
                            onRemoveGalleryImage(node.id, index)
                        } label: {
                            Label("Remove image \(index + 1)", systemImage: "trash")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(paths.count) image\(paths.count == 1 ? "" : "s")")
                            .font(.cucuSerif(14, weight: .semibold))
                            .foregroundStyle(Color.cucuInk)
                        Spacer(minLength: 0)
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.cucuInkFaded)
                    }
                }
            }
        }
    }

    private func galleryLayoutCard(node: CanvasNode) -> some View {
        let binding = bindingGalleryLayout(node.id)
        return cardShell(title: "Layout", width: 180) {
            Menu {
                ForEach(NodeGalleryLayout.allCases, id: \.self) { layout in
                    Button {
                        binding.wrappedValue = layout
                        onCommit(document)
                    } label: {
                        if layout == binding.wrappedValue {
                            Label(layout.label, systemImage: "checkmark")
                        } else {
                            Text(layout.label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(binding.wrappedValue.label)
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
        }
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
        CucuIconBadge(kind: kind(for: node),
                      symbol: iconName(for: node),
                      size: 36, iconSize: 15)
    }

    private func kind(for node: CanvasNode) -> CucuNodeKind {
        switch node.type {
        case .container: return .container
        case .text:      return .text
        case .image:     return .image
        case .icon:      return .icon
        case .divider:   return .divider
        case .link:      return .link
        case .gallery:   return .gallery
        }
    }

    private func iconName(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return "rectangle.on.rectangle"
        case .text:      return "textformat"
        case .image:     return "photo"
        case .icon:      return "star.fill"
        case .divider:   return "minus"
        case .link:      return "link"
        case .gallery:   return "rectangle.grid.2x2"
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
        }
    }

    private func displayName(for node: CanvasNode) -> String {
        if let trimmed = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return typeLabel(for: node)
    }

    /// Friendly font-family label. Delegates to
    /// `NodeFontFamily.displayName` so adding a new case in the model
    /// doesn't require a compile error here — the resolver is the
    /// single source of truth for human-readable family names.
    private func label(for font: NodeFontFamily) -> String {
        font.displayName
    }

    private func label(for weight: NodeFontWeight) -> String {
        switch weight {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "Semibold"
        case .bold: return "Bold"
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

    private func loadPickerData(_ item: PhotosPickerItem?, callback: @escaping (Data) -> Bool) {
        guard let item else { return }
        pickerLoading = true
        pickerError = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        let saved = callback(data)
                        if !saved {
                            pickerError = "Couldn't save that image."
                        }
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

    // MARK: - Gallery picker loading

    /// Load every selected `PhotosPickerItem` as `Data`, then hand the
    /// list to the host's `onAppendGalleryImages` so the bytes get
    /// written to disk under per-image deterministic UUIDs. Resets the
    /// selection state after a successful round-trip so subsequent picks
    /// don't see stale items.
    private func loadGalleryPickerData(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerLoading = true
        pickerError = nil
        Task {
            var bytesList: [Data] = []
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        bytesList.append(data)
                    }
                } catch {
                    // Skip the unreadable item; surface a single
                    // friendly error after the loop if anything failed.
                }
            }
            await MainActor.run {
                if bytesList.isEmpty {
                    pickerError = "Couldn't read those photos."
                } else if !onAppendGalleryImages(selectedID, bytesList) {
                    pickerError = "Couldn't save the images."
                }
                pickerLoading = false
                gallerySelection = []
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

    private func bindingFontWeight(_ id: UUID) -> Binding<NodeFontWeight> {
        Binding(
            get: { document.nodes[id]?.style.fontWeight ?? .regular },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.fontWeight = newValue
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

    private func bindingTextAlignment(_ id: UUID) -> Binding<NodeTextAlignment> {
        Binding(
            get: { document.nodes[id]?.style.textAlignment ?? .leading },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.textAlignment = newValue
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

    // MARK: - New-element bindings

    private func bindingIconStyleFamily(_ id: UUID) -> Binding<NodeIconStyleFamily> {
        Binding(
            get: { document.nodes[id]?.style.iconStyleFamily ?? .pastelDoodle },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.iconStyleFamily = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingIconName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.iconName ?? "star.fill" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.iconName = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingDividerStyleFamily(_ id: UUID) -> Binding<NodeDividerStyleFamily> {
        Binding(
            get: { document.nodes[id]?.style.dividerStyleFamily ?? .solid },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.dividerStyleFamily = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingDividerThickness(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style.dividerThickness ?? 2 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.dividerThickness = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingLinkStyleVariant(_ id: UUID) -> Binding<NodeLinkStyleVariant> {
        Binding(
            get: { document.nodes[id]?.style.linkStyleVariant ?? .pill },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.linkStyleVariant = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingURL(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.url ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.url = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingGalleryLayout(_ id: UUID) -> Binding<NodeGalleryLayout> {
        Binding(
            get: { document.nodes[id]?.style.galleryLayout ?? .grid },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.galleryLayout = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Per-tile image fit for galleries. Reuses the `NodeImageFit`
    /// enum so single-image and gallery nodes share the same Fit/Fill
    /// vocabulary. Defaults to `.fit` so the user always sees the
    /// whole photo unless they explicitly pick crop-to-fill.
    private func bindingGalleryImageFit(_ id: UUID) -> Binding<NodeImageFit> {
        Binding(
            get: { document.nodes[id]?.style.imageFit ?? .fit },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.imageFit = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Padding around text inside its background. Reads `nil` as `0`
    /// in the slider — but the renderer keeps the original 4/2pt
    /// fallback for nil so old drafts don't shift visually unless
    /// the user actually drags the slider, at which point a real
    /// value gets stored and the renderer respects it uniformly.
    private func bindingPadding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style.padding ?? 0 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.padding = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Extra spacing in points between lines of text. `0` keeps the
    /// font's natural line height. Stored as `nil` for `0` so the
    /// JSON stays minimal for the common case.
    private func bindingLineSpacing(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style.lineSpacing ?? 0 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.lineSpacing = newValue > 0.01 ? newValue : nil
                document.nodes[id] = node
            }
        )
    }

    private func bindingGalleryGap(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style.galleryGap ?? 6 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.galleryGap = newValue
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
