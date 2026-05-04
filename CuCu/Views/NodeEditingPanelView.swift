import PhotosUI
import SwiftUI

/// Published by the bottom panel so the host can reserve canvas
/// scroll-area below the selected node. Reduces by `max` so the
/// largest reported height wins when multiple sources publish (e.g.,
/// the panel re-emits while its content reflows).
struct EditorPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Bottom, keyboard-aware editor for structured profile nodes. It covers the
/// common mobile edits inline so users do not have to open the full inspector
/// for every text/style/layout change.
struct NodeEditingPanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case text = "Text"
        case style = "Style"
        case layout = "Layout"

        var id: String { rawValue }
    }

    @Binding var document: ProfileDocument
    let selectedID: UUID
    var selectedTextRange: NSRange?

    var onCommit: (ProfileDocument) -> Void
    var onAddElement: () -> Void
    var onOpenInspector: () -> Void
    var onDuplicate: () -> Void
    var onLayers: () -> Void
    var onDelete: () -> Void
    var onSetContainerBackground: (UUID, Data) -> Bool
    var onClearContainerBackground: (UUID) -> Void
    var onEditContainerBackground: (UUID) -> Void
    /// Replaces the bytes behind an image node. Wired through the host
    /// to `CanvasMutator.replaceImage`. The first tab on an image node
    /// uses this to swap the picture without making the user open the
    /// full inspector or remove the node and re-add it.
    var onReplaceImage: (UUID, Data) -> Bool
    /// Reorders the selected top-level element one slot up / down in
    /// `rootChildrenIDs`. The host passes a "can move" predicate so
    /// the menu items disable when the element is already at the
    /// top of the movable range or the bottom of the page.
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var canMoveUp: () -> Bool
    var canMoveDown: () -> Bool
    /// Appends one or more new photos to a gallery node — first tab on
    /// a gallery uses this to grow the grid in place via PhotosPicker.
    /// Wired to `CanvasMutator.appendGalleryImages`.
    var onAppendGalleryPhotos: (UUID, [Data]) -> Bool
    /// Optional close affordance — wired by the host to clear the
    /// selection (which collapses the panel). Used by the redesigned
    /// text inspector's `✕` button.
    var onClose: () -> Void = {}

    @State private var selectedTab: Tab = .text
    @State private var containerBackgroundSelection: PhotosPickerItem?
    /// Photos picker selection for the image-replace flow exposed on
    /// the first tab of an image node. Kept separate from the
    /// container-background selection so the two pickers don't fight
    /// over a shared state slot.
    @State private var imageReplaceSelection: PhotosPickerItem?
    /// Multi-select picker selection for the gallery-add flow on the
    /// first tab of a gallery node.
    @State private var galleryAppendSelection: [PhotosPickerItem] = []
    /// Drives the SF Symbol picker sheet on the icon tab. Nil means
    /// "no sheet"; setting it to a node ID presents `IconPickerSheet`
    /// for that node. Mirrors the per-node-keyed `.sheet(item:)`
    /// pattern used by `PropertyInspectorView` so picking a different
    /// node mid-flow tears the sheet down cleanly.
    @State private var iconPickerNodeID: UUID?
    @State private var pickerLoading = false
    @State private var pickerError: String?
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        if let node = document.nodes[selectedID] {
            // Text nodes (including the hero's name/meta/bio children
            // and any user-added text) get the redesigned tabbed
            // inspector. Everything else stays on the existing
            // segmented-picker + horizontal-card layout — those types
            // have their own type-specific cards (image replace,
            // gallery append, etc.) that the text redesign never
            // covered.
            if node.type == .text {
                TextInspectorV2(
                    document: $document,
                    textID: selectedID,
                    selectedTextRange: selectedTextRange,
                    onDuplicate: onDuplicate,
                    onDelete: onDelete,
                    onClose: onClose
                )
                .padding(.horizontal, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .background(panelHeightReporter)
                .onDisappear {
                    commitTask?.cancel()
                    onCommit(document)
                }
            } else {
                ElementInspectorChrome(
                    typeLabel: ElementInspectorChrome<EmptyView>.typeLabel(for: node),
                    idTag: ElementInspectorChrome<EmptyView>.idTag(for: node.id),
                    tabs: chromeTabLabels(for: node),
                    selectedIndex: chromeTabIndex,
                    onDuplicate: onDuplicate,
                    canDuplicate: StructuredProfileLayout.canDuplicate(selectedID, in: document),
                    onDelete: onDelete,
                    canDelete: StructuredProfileLayout.canDelete(selectedID, in: document),
                    onClose: onClose
                ) {
                    VStack(spacing: 10) {
                        tabContent(for: node)
                            .padding(.top, 4)

                        if let pickerError {
                            Text(pickerError)
                                .font(.cucuSans(11, weight: .medium))
                                .foregroundStyle(Color.cucuCherry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .background(panelHeightReporter)
                .onChange(of: containerBackgroundSelection) { _, item in
                    loadContainerBackground(item)
                }
                .onChange(of: imageReplaceSelection) { _, item in
                    loadImageReplacement(item)
                }
                .onChange(of: galleryAppendSelection) { _, items in
                    loadGalleryAppend(items)
                }
                // SF Symbol grid for the icon tab. Per-node-keyed so
                // selecting a different icon node mid-flow tears down
                // and re-presents the sheet cleanly. The picker writes
                // through `bindingIconName`, then `onCommit` persists.
                .sheet(item: Binding(
                    get: { iconPickerNodeID.map { IconPickerTarget(nodeID: $0) } },
                    set: { iconPickerNodeID = $0?.nodeID }
                )) { target in
                    IconPickerSheet(
                        selection: bindingIconName(target.nodeID),
                        onCommit: { commitNow() }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .onDisappear {
                    commitTask?.cancel()
                    onCommit(document)
                }
            }
        }
    }

    /// Identifiable wrapper so `.sheet(item:)` can present the icon
    /// picker keyed off the target node ID. Same pattern as the full
    /// `PropertyInspectorView`.
    private struct IconPickerTarget: Identifiable, Equatable {
        let nodeID: UUID
        var id: UUID { nodeID }
    }

    /// Tab labels for the new dark-capsule TabBar. The first label
    /// adapts to the node type so the leftmost segment reads as the
    /// most-natural action ("Photos" for galleries, "Items" for
    /// carousels, etc.). Style and Layout are universal.
    private func chromeTabLabels(for node: CanvasNode) -> [String] {
        [label(for: .text, on: node), "Style", "Layout"]
    }

    /// Bridges the legacy `Tab` enum to the chrome's index-based
    /// `selectedIndex` binding so the existing `tabContent(for:)`
    /// switch keeps working unchanged.
    private var chromeTabIndex: Binding<Int> {
        Binding(
            get: {
                switch selectedTab {
                case .text:   return 0
                case .style:  return 1
                case .layout: return 2
                }
            },
            set: { newValue in
                switch newValue {
                case 0:  selectedTab = .text
                case 1:  selectedTab = .style
                default: selectedTab = .layout
                }
            }
        )
    }

    /// Hidden GeometryReader that publishes the panel's measured
    /// height to the host via `EditorPanelHeightKey`. Drawn behind
    /// every panel surface so any reflow (TabBar swap, HSV picker
    /// open/close, format toolbar drawer) republishes immediately.
    private var panelHeightReporter: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: EditorPanelHeightKey.self,
                value: geo.size.height
            )
        }
    }

    private func header(for node: CanvasNode) -> some View {
        HStack(spacing: 10) {
            CucuIconBadge(kind: kind(for: node), symbol: iconName(for: node), size: 30, iconSize: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: node))
                    .font(.cucuSerif(15, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                    .lineLimit(1)
                Text(subtitle(for: node))
                    .font(.cucuSans(11, weight: .regular))
                    .foregroundStyle(Color.cucuInkFaded)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            Button(action: onAddElement) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.cucuInk)
            .background(Circle().fill(Color.cucuCard))
            .disabled(!canAddElements)
            .accessibilityLabel("Add Element")

            Menu {
                Button("More Properties", systemImage: "slider.horizontal.3", action: onOpenInspector)
                Button("Layers", systemImage: "square.3.layers.3d", action: onLayers)
                Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                    .disabled(!canMoveUp())
                Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                    .disabled(!canMoveDown())
                Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                    .disabled(!StructuredProfileLayout.canDuplicate(selectedID, in: document))
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .disabled(!StructuredProfileLayout.canDelete(selectedID, in: document))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cucuInkSoft)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.cucuCard))
            }
            .accessibilityLabel("Selection actions")
        }
    }

    @ViewBuilder
    private func tabContent(for node: CanvasNode) -> some View {
        switch selectedTab {
        case .text:
            // Content-bearing primitives hijack the first tab so it
            // surfaces controls that actually do something:
            //   • image    → Replace photo
            //   • gallery  → Add photos
            //   • carousel → Add item (routes through `onAddElement`)
            //   • icon     → Pick SF Symbol (the icon's only "content")
            // Everything else keeps the regular text controls.
            switch node.type {
            case .image:    imageTab(for: node)
            case .gallery:  galleryTab(for: node)
            case .carousel: carouselTab(for: node)
            case .icon:     iconTab(for: node)
            case .note:     noteTab(for: node)
            default:        textTab(for: node)
            }
        case .style:
            styleTab(for: node)
        case .layout:
            layoutTab(for: node)
        }
    }

    /// Per-tab segment label, used by the segmented `Picker`. The
    /// first segment renames itself to match what the tab exposes —
    /// `Image` for image nodes, `Photos` for galleries, `Items` for
    /// carousels. Other types keep the default `Text` label.
    private func label(for tab: Tab, on node: CanvasNode) -> String {
        switch tab {
        case .text:
            switch node.type {
            case .image:    return "Image"
            case .gallery:  return "Photos"
            case .carousel: return "Items"
            case .icon:     return "Icon"
            case .note:     return "Note"
            default:        return "Text"
            }
        case .style:
            return "Style"
        case .layout:
            return "Layout"
        }
    }

    @ViewBuilder
    private func textTab(for node: CanvasNode) -> some View {
        if let textID = editableTextID(for: node),
           let textNode = document.nodes[textID] {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    textContentCard(textID)
                    // Link nodes need a URL field on the same tab as
                    // their visible title — without it the bottom
                    // panel offered no way to set the destination at
                    // all (the full inspector had it, but most users
                    // never opened that). Reuses the same
                    // `content.url` field the published viewer's tap
                    // handler reads, so saving here makes the link
                    // tappable in the published profile.
                    if textNode.type == .link {
                        linkURLCard(textID)
                    }
                    fontFamilyCard(textID)
                    fontWeightCard(textID)
                    sliderCard(
                        title: "Size",
                        value: bindingStyleDouble(textID, key: \.fontSize, defaultValue: 17),
                        range: 8...72,
                        step: 1,
                        valueText: "\(Int(document.nodes[textID]?.style.fontSize ?? 17))"
                    )
                    colorCard(
                        title: "Text",
                        hex: bindingTextColor(textID, defaultHex: "#1A140E")
                    )
                    underlineCard(textID)
                    alignmentCard(textID)
                    if textNode.type == .text {
                        sliderCard(
                            title: "Line",
                            value: bindingOptionalStyleDouble(textID, key: \.lineSpacing),
                            range: 0...16,
                            step: 1,
                            valueText: "\(Int(document.nodes[textID]?.style.lineSpacing ?? 0))"
                        )
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: 96)
        } else {
            emptyState(
                title: node.role == .sectionCard || node.type == .container
                    ? "Select a text element inside this card."
                    : "This element does not expose text controls.",
                systemImage: "textformat"
            )
        }
    }

    private func linkURLCard(_ id: UUID) -> some View {
        cardShell(title: "URL", width: 240) {
            TextField("https://", text: bindingLinkURL(id))
                .font(.cucuMono(13, weight: .medium))
                .foregroundStyle(Color.cucuInk)
                .textFieldStyle(.plain)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.done)
                .onSubmit { commitNow() }
        }
    }

    /// First-tab content for image nodes. Replaces the irrelevant text
    /// controls with a Replace-photo card (and a small thumbnail when
    /// an image is already set) so the user can swap the picture
    /// directly from the bottom panel — same friction-free flow the
    /// container background card offers, scaled down to a single
    /// horizontal control.
    @ViewBuilder
    private func imageTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                imageReplaceCard(node)
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    /// First-tab content for gallery nodes. Surfaces an Add-photos
    /// PhotosPicker plus a thumbnail strip of the gallery's current
    /// images, mirroring the visual rhythm of `imageTab`. Removal /
    /// reorder still live in the full property inspector — this tab
    /// stays focused on the most-common gallery edit (growing it).
    @ViewBuilder
    private func galleryTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                galleryAppendCard(node)
                galleryThumbsCard(node)
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    private func galleryAppendCard(_ node: CanvasNode) -> some View {
        let count = node.content.imagePaths?.count ?? 0
        let title = count == 0 ? "Add photos" : "Add more"
        return cardShell(title: title, width: 200) {
            PhotosPicker(
                selection: $galleryAppendSelection,
                maxSelectionCount: 12,
                matching: .images,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.cucuCardSoft)
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.cucuInk)
                    }
                    .frame(width: 34, height: 34)
                    Text(pickerLoading
                         ? "Loading…"
                         : (count == 0 ? "Pick photos" : "\(count) photo\(count == 1 ? "" : "s")"))
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer(minLength: 0)
                }
            }
            .disabled(pickerLoading)
        }
    }

    @ViewBuilder
    private func galleryThumbsCard(_ node: CanvasNode) -> some View {
        // Only show the thumbnail strip when the gallery has at least
        // one image — an empty card is just visual noise on a fresh
        // gallery the user just created.
        let paths = node.content.imagePaths ?? []
        if !paths.isEmpty {
            cardShell(title: "Preview", width: 220) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(paths.prefix(8).enumerated()), id: \.offset) { _, path in
                            if let img = LocalCanvasAssetStore.loadUIImage(path) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
            }
        }
    }

    /// First-tab content for icon nodes. The icon's only content is
    /// the SF Symbol name, so the tab is a single tile that opens the
    /// shared `IconPickerSheet`. Without this the tab fell through to
    /// `textTab`, which rendered an empty-state because icons have no
    /// editable text — so users had no way to change the symbol from
    /// the bottom panel.
    @ViewBuilder
    private func iconTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                iconGlyphCard(node)
                // Optional outbound URL. When set, the icon becomes
                // tappable in the published viewer (see the `.icon`
                // case in `CanvasEditorView.attachPanGesture`). Empty
                // = inert icon, same behavior as before this card
                // existed.
                iconLinkCard(node)
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    private func iconLinkCard(_ node: CanvasNode) -> some View {
        cardShell(title: "Link", width: 240) {
            TextField("https://", text: bindingIconURL(node.id))
                .font(.cucuMono(13, weight: .medium))
                .foregroundStyle(Color.cucuInk)
                .textFieldStyle(.plain)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.done)
                .onSubmit { commitNow() }
        }
    }

    private func iconGlyphCard(_ node: CanvasNode) -> some View {
        let binding = bindingIconName(node.id)
        let nodeID = node.id
        return cardShell(title: "Icon", width: 200) {
            Button {
                iconPickerNodeID = nodeID
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.cucuCardSoft)
                        Image(systemName: binding.wrappedValue)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.cucuInk)
                    }
                    .frame(width: 34, height: 34)
                    Text(IconCatalog.label(for: binding.wrappedValue))
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// First-tab content for note nodes. Three text fields cover the
    /// editable surface: Title (the headline + count badge), Time (the
    /// editable relative-time string), and Body (the multi-line note
    /// text). Body uses the same `bindingText` plumbing the regular
    /// text node uses, so the existing reconcileTextStyleSpans guard
    /// is benign for notes (textStyleSpans is never set on notes).
    @ViewBuilder
    private func noteTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                noteTitleCard(node.id)
                noteTimestampCard(node.id)
                noteBodyCard(node.id)
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    private func noteTitleCard(_ id: UUID) -> some View {
        cardShell(title: "Title", width: 220) {
            TextField("Notes (12)", text: bindingNoteTitle(id))
                .font(.cucuSerif(15, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit { commitNow() }
        }
    }

    private func noteTimestampCard(_ id: UUID) -> some View {
        cardShell(title: "Time", width: 180) {
            TextField("10 min. ago", text: bindingNoteTimestamp(id))
                .font(.cucuMono(13, weight: .medium))
                .foregroundStyle(Color.cucuInk)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit { commitNow() }
        }
    }

    private func noteBodyCard(_ id: UUID) -> some View {
        cardShell(title: "Body", width: 280) {
            TextField("Write your note", text: bindingText(id), axis: .vertical)
                .font(.cucuSerif(14, weight: .regular))
                .foregroundStyle(Color.cucuInk)
                .lineLimit(2...3)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit { commitNow() }
        }
    }

    /// First-tab content for carousel nodes. Routes to the existing
    /// AddNodeSheet via `onAddElement`, which auto-pivots to the
    /// `.carousel` destination since the carousel is selected. Shows
    /// the current item count so the user knows what's there.
    @ViewBuilder
    private func carouselTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                carouselAddItemCard(node)
                carouselItemCountCard(node)
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    private func carouselAddItemCard(_ node: CanvasNode) -> some View {
        cardShell(title: "Add item", width: 200) {
            Button(action: onAddElement) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.cucuCardSoft)
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.cucuInk)
                    }
                    .frame(width: 34, height: 34)
                    Text("Pick element")
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func carouselItemCountCard(_ node: CanvasNode) -> some View {
        let count = node.childrenIDs.count
        return cardShell(title: "Items", width: 130) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.cucuInkSoft)
                Text("\(count)")
                    .font(.cucuSerif(18, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
                Spacer(minLength: 0)
            }
        }
    }

    private func imageReplaceCard(_ node: CanvasNode) -> some View {
        cardShell(title: node.content.localImagePath?.isEmpty == false ? "Replace" : "Insert",
                  width: 200) {
            PhotosPicker(
                selection: $imageReplaceSelection,
                matching: .images,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 9) {
                    if let path = node.content.localImagePath,
                       !path.isEmpty,
                       let preview = LocalCanvasAssetStore.loadUIImage(path) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.cucuCardSoft)
                            Image(systemName: "photo")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.cucuInkSoft)
                        }
                        .frame(width: 34, height: 34)
                    }
                    Text(pickerLoading ? "Loading…" : (node.content.localImagePath?.isEmpty == false ? "Pick photo" : "Choose photo"))
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Spacer(minLength: 0)
                }
            }
            .disabled(pickerLoading)
        }
    }

    @ViewBuilder
    private func styleTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                switch node.type {
                case .container, .carousel:
                    colorCard(
                        title: "Fill",
                        hex: bindingStyleHex(node.id, key: \.backgroundColorHex, defaultHex: "#FFFFFF"),
                        supportsAlpha: true
                    )
                    if node.type == .container {
                        containerBackgroundCard(node)
                    }
                    sliderCard(
                        title: "Opacity",
                        value: bindingNodeDouble(node.id, key: \.opacity, defaultValue: 1),
                        range: 0...1,
                        step: 0.01,
                        valueText: "\(Int((document.nodes[node.id]?.opacity ?? 1) * 100))%"
                    )
                    colorCard(
                        title: "Border",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#1A140E")
                    )
                    sliderCard(
                        title: "Border W",
                        value: bindingStyleDouble(node.id, key: \.borderWidth, defaultValue: 0),
                        range: 0...8,
                        step: 0.5,
                        valueText: String(format: "%.1f", document.nodes[node.id]?.style.borderWidth ?? 0)
                    )
                    sliderCard(
                        title: "Radius",
                        value: bindingStyleDouble(node.id, key: \.cornerRadius, defaultValue: 0),
                        range: 0...64,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.cornerRadius ?? 0))"
                    )
                    sliderCard(
                        title: "Backdrop",
                        value: bindingOptionalStyleDouble(node.id, key: \.containerBlur),
                        range: 0...1,
                        step: 0.01,
                        valueText: "\(Int((document.nodes[node.id]?.style.containerBlur ?? 0) * 100))%"
                    )
                    if node.style.backgroundImagePath != nil {
                        sliderCard(
                            title: "Img Blur",
                            value: bindingOptionalStyleDouble(node.id, key: \.backgroundBlur),
                            range: 0...30,
                            step: 1,
                            valueText: "\(Int(document.nodes[node.id]?.style.backgroundBlur ?? 0))"
                        )
                    }
                    if node.type == .container {
                        gradientGroupCard(node.id)
                    }
                case .text:
                    colorCard(
                        title: "Text",
                        hex: bindingTextColor(node.id, defaultHex: "#1A140E")
                    )
                    colorCard(
                        title: "Fill",
                        hex: bindingStyleHex(node.id, key: \.backgroundColorHex, defaultHex: "#FFFFFF"),
                        supportsAlpha: true
                    )
                    sliderCard(
                        title: "Backdrop",
                        value: bindingOptionalStyleDouble(node.id, key: \.textBackdropBlur),
                        range: 0...1,
                        step: 0.01,
                        valueText: "\(Int((document.nodes[node.id]?.style.textBackdropBlur ?? 0) * 100))%"
                    )
                    sliderCard(
                        title: "Radius",
                        value: bindingStyleDouble(node.id, key: \.cornerRadius, defaultValue: 0),
                        range: 0...64,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.cornerRadius ?? 0))"
                    )
                case .icon:
                    iconStyleCard(node.id)
                    colorCard(
                        title: "Tint",
                        hex: bindingStyleHex(node.id, key: \.tintColorHex, defaultHex: "#B22A4A")
                    )
                    colorCard(
                        title: "Plate",
                        hex: bindingStyleHex(node.id, key: \.backgroundColorHex, defaultHex: "#FFE3EC")
                    )
                    colorCard(
                        title: "Border",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#1A140E")
                    )
                case .divider:
                    dividerStyleCard(node.id)
                    colorCard(
                        title: "Color",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#B22A4A")
                    )
                    if node.role != .fixedDivider {
                        sliderCard(
                            title: "Thick",
                            value: bindingOptionalStyleDouble(node.id, key: \.dividerThickness, defaultValue: 2),
                            range: 0.5...10,
                            step: 0.5,
                            valueText: String(format: "%.1f", document.nodes[node.id]?.style.dividerThickness ?? 2)
                        )
                    }
                case .image:
                    imageFitCard(node.id)
                    clipShapeCard(node.id)
                    sliderCard(
                        title: "Opacity",
                        value: bindingNodeDouble(node.id, key: \.opacity, defaultValue: 1),
                        range: 0...1,
                        step: 0.01,
                        valueText: "\(Int((document.nodes[node.id]?.opacity ?? 1) * 100))%"
                    )
                    colorCard(
                        title: "Border",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#FFFFFF")
                    )
                    sliderCard(
                        title: "Border W",
                        value: bindingStyleDouble(node.id, key: \.borderWidth, defaultValue: 0),
                        range: 0...8,
                        step: 0.5,
                        valueText: String(format: "%.1f", document.nodes[node.id]?.style.borderWidth ?? 0)
                    )
                    // No-op when clipShape is `.circle` — the renderer
                    // overrides cornerRadius to min(w,h)/2 in that mode
                    // (see `NodeRenderView`), same pattern as the link
                    // `.pill` variant.
                    sliderCard(
                        title: "Radius",
                        value: bindingStyleDouble(node.id, key: \.cornerRadius, defaultValue: 8),
                        range: 0...40,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.cornerRadius ?? 8))"
                    )
                case .link:
                    // Variant picker first so the user can move off
                    // `.pill` (which always renders as a capsule and
                    // ignores the radius slider — that's the variant's
                    // defining property). Card / Button / Badge respect
                    // the slider directly; Underlined is a wavy text
                    // treatment with no fill / border / radius.
                    linkVariantCard(node.id)
                    colorCard(
                        title: "Text",
                        hex: bindingTextColor(node.id, defaultHex: "#1A140E")
                    )
                    colorCard(
                        title: "Fill",
                        hex: bindingStyleHex(node.id, key: \.backgroundColorHex, defaultHex: "#FBF6E9")
                    )
                    colorCard(
                        title: "Border",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#1A140E")
                    )
                    // Stroke width and corner radius mirror the
                    // container / image style tabs so the link surface
                    // can be tuned the same way every other framed
                    // primitive can. The `.pill` variant overrides
                    // cornerRadius to height/2 in the renderer, so the
                    // slider only takes effect on card / button /
                    // badge variants — by design.
                    sliderCard(
                        title: "Border W",
                        value: bindingStyleDouble(node.id, key: \.borderWidth, defaultValue: 0),
                        range: 0...8,
                        step: 0.5,
                        valueText: String(format: "%.1f", document.nodes[node.id]?.style.borderWidth ?? 0)
                    )
                    sliderCard(
                        title: "Radius",
                        value: bindingLinkCornerRadius(node.id),
                        range: 0...40,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.cornerRadius ?? 0))"
                    )
                case .gallery:
                    galleryLayoutCard(node.id)
                    // Per-photo Fit/Fill mirrors the image inspector.
                    // Gallery's renderer defaults a missing value to
                    // `.fit` (see `GalleryNodeView.cachedImageFit`),
                    // so the picker uses the same default — otherwise
                    // it'd misreport the rendered state on a fresh
                    // gallery as "Fill".
                    galleryImageFitCard(node.id)
                    // Gallery card background — flows through the same
                    // `backgroundColorHex` field every other node uses,
                    // so the gallery's render path picks it up via
                    // `NodeRenderView.apply(node:)`. Alpha is enabled
                    // so users can knock the card surface back to a
                    // tinted wash or all the way to transparent if
                    // they want the photos to float on the page bg.
                    colorCard(
                        title: "Fill",
                        hex: bindingStyleHex(node.id, key: \.backgroundColorHex, defaultHex: "#FBF9F2"),
                        supportsAlpha: true
                    )
                    sliderCard(
                        title: "Opacity",
                        value: bindingNodeDouble(node.id, key: \.opacity, defaultValue: 1),
                        range: 0...1,
                        step: 0.01,
                        valueText: "\(Int((document.nodes[node.id]?.opacity ?? 1) * 100))%"
                    )
                    colorCard(
                        title: "Border",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#E5E5EA")
                    )
                    // Border has no width by default — without this
                    // slider, picking a Border color was a no-op
                    // because `borderWidth` stayed at 0 and the stroke
                    // never rendered.
                    sliderCard(
                        title: "Border W",
                        value: bindingStyleDouble(node.id, key: \.borderWidth, defaultValue: 0),
                        range: 0...8,
                        step: 0.5,
                        valueText: String(format: "%.1f", document.nodes[node.id]?.style.borderWidth ?? 0)
                    )
                    sliderCard(
                        title: "Radius",
                        value: bindingStyleDouble(node.id, key: \.cornerRadius, defaultValue: 12),
                        range: 0...40,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.cornerRadius ?? 12))"
                    )
                case .note:
                    // Notes are container-shaped: same Fill / Border /
                    // Radius family every other framed primitive uses.
                    // Text controls (font family / size / color) are
                    // included so the typography of all three rows
                    // (title, timestamp, body) — which derive from the
                    // node's base font — can be tuned in one place.
                    colorCard(
                        title: "Fill",
                        hex: bindingStyleHex(node.id, key: \.backgroundColorHex, defaultHex: "#FFFFFF"),
                        supportsAlpha: true
                    )
                    colorCard(
                        title: "Text",
                        hex: bindingTextColor(node.id, defaultHex: "#1A140E")
                    )
                    fontFamilyCard(node.id)
                    sliderCard(
                        title: "Size",
                        value: bindingStyleDouble(node.id, key: \.fontSize, defaultValue: 15),
                        range: 10...28,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.fontSize ?? 15))"
                    )
                    sliderCard(
                        title: "Opacity",
                        value: bindingNodeDouble(node.id, key: \.opacity, defaultValue: 1),
                        range: 0...1,
                        step: 0.01,
                        valueText: "\(Int((document.nodes[node.id]?.opacity ?? 1) * 100))%"
                    )
                    colorCard(
                        title: "Border",
                        hex: bindingStyleHex(node.id, key: \.borderColorHex, defaultHex: "#1A140E")
                    )
                    sliderCard(
                        title: "Border W",
                        value: bindingStyleDouble(node.id, key: \.borderWidth, defaultValue: 1),
                        range: 0...8,
                        step: 0.5,
                        valueText: String(format: "%.1f", document.nodes[node.id]?.style.borderWidth ?? 1)
                    )
                    sliderCard(
                        title: "Radius",
                        value: bindingStyleDouble(node.id, key: \.cornerRadius, defaultValue: 18),
                        range: 0...40,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.cornerRadius ?? 18))"
                    )
                    sliderCard(
                        title: "Padding",
                        value: bindingOptionalStyleDouble(node.id, key: \.padding, defaultValue: 16),
                        range: 0...32,
                        step: 1,
                        valueText: "\(Int(document.nodes[node.id]?.style.padding ?? 16))"
                    )
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    @ViewBuilder
    private func layoutTab(for node: CanvasNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if node.role == .sectionCard {
                    sliderCard(
                        title: "Card H",
                        value: bindingFrameHeight(node.id),
                        range: StructuredProfileLayout.cardMinimumHeight...520,
                        step: 4,
                        valueText: "\(Int(document.nodes[node.id]?.frame.height ?? 0))"
                    )
                    infoCard(title: "Margins", text: "Fixed side margins")
                    infoCard(title: "Width", text: "Auto fitted")
                } else if isInsideSectionCard(node.id) {
                    alignmentHelpersCard(node.id)
                    frameSizeCard(node.id)
                    positionCard(node.id)
                    if node.type == .text {
                        sliderCard(
                            title: "Padding",
                            value: bindingOptionalStyleDouble(node.id, key: \.padding),
                            range: 0...48,
                            step: 1,
                            valueText: "\(Int(document.nodes[node.id]?.style.padding ?? 0))"
                        )
                    }
                    if node.type == .gallery {
                        sliderCard(
                            title: "Gap",
                            value: bindingOptionalStyleDouble(node.id, key: \.galleryGap, defaultValue: 6),
                            range: 0...24,
                            step: 1,
                            valueText: "\(Int(document.nodes[node.id]?.style.galleryGap ?? 6))"
                        )
                    }
                } else if node.role == .fixedDivider || StructuredProfileLayout.isInSystemProfileSubtree(node.id, in: document) {
                    emptyState(title: "This system element is locked.", systemImage: "lock")
                } else {
                    frameSizeCard(node.id)
                    positionCard(node.id)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 96)
    }

    // MARK: - Cards

    private func cardShell<Content: View>(title: String,
                                          width: CGFloat = 148,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.cucuMono(9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.cucuInkFaded)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: width, height: 86)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cucuCard))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.14), lineWidth: 1)
        )
    }

    private func textContentCard(_ id: UUID) -> some View {
        cardShell(title: "Content", width: 250) {
            TextField("Write something", text: bindingText(id), axis: .vertical)
                .font(.cucuSerif(15, weight: .regular))
                .foregroundStyle(Color.cucuInk)
                .lineLimit(2...3)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit { commitNow() }
        }
    }

    private func colorCard(title: String,
                           hex: Binding<String>,
                           supportsAlpha: Bool = false) -> some View {
        cardShell(title: title, width: 142) {
            HStack(spacing: 9) {
                ColorPicker("", selection: hex.asColor(), supportsOpacity: supportsAlpha)
                    .labelsHidden()
                    .frame(width: 32, height: 32)
                    .onChange(of: hex.wrappedValue) { _, _ in commitNow() }
                Text(hex.wrappedValue.uppercased())
                    .font(.cucuMono(10, weight: .medium))
                    .foregroundStyle(Color.cucuInkSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func sliderCard(title: String,
                            value: Binding<Double>,
                            range: ClosedRange<Double>,
                            step: Double.Stride,
                            valueText: String) -> some View {
        cardShell(title: title, width: 170) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(valueText)
                        .font(.cucuMono(11, weight: .medium))
                        .foregroundStyle(Color.cucuInkSoft)
                    Spacer()
                }
                Slider(value: value, in: range, step: step) { editing in
                    if !editing { commitNow() }
                }
            }
        }
    }

    private func menuCard<T: Hashable>(title: String,
                                       width: CGFloat = 170,
                                       value: Binding<T>,
                                       options: [(T, String)]) -> some View {
        cardShell(title: title, width: width) {
            Menu {
                ForEach(options, id: \.0) { option, label in
                    Button {
                        value.wrappedValue = option
                        commitNow()
                    } label: {
                        if option == value.wrappedValue {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(options.first(where: { $0.0 == value.wrappedValue })?.1 ?? "Select")
                        .font(.cucuSerif(14, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
        }
    }

    private func fontFamilyCard(_ id: UUID) -> some View {
        menuCard(
            title: "Font",
            width: 180,
            value: bindingFontFamily(id),
            options: NodeFontFamily.allCases.map { ($0, label(for: $0)) }
        )
    }

    private func fontWeightCard(_ id: UUID) -> some View {
        menuCard(
            title: "Weight",
            value: bindingFontWeight(id),
            options: NodeFontWeight.allCases.map { ($0, label(for: $0)) }
        )
    }

    private func underlineCard(_ id: UUID) -> some View {
        cardShell(title: "Style", width: 118) {
            Button {
                bindingTextUnderlined(id).wrappedValue.toggle()
                commitNow()
            } label: {
                HStack {
                    Image(systemName: "underline")
                    Text(bindingTextUnderlined(id).wrappedValue ? "On" : "Off")
                    Spacer()
                }
                .font(.cucuSerif(14, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
            }
            .buttonStyle(.plain)
        }
    }

    private func alignmentCard(_ id: UUID) -> some View {
        cardShell(title: "Align", width: 178) {
            Picker("", selection: bindingTextAlignment(id)) {
                Text("L").tag(NodeTextAlignment.leading)
                Text("C").tag(NodeTextAlignment.center)
                Text("R").tag(NodeTextAlignment.trailing)
            }
            .pickerStyle(.segmented)
            .onChange(of: bindingTextAlignment(id).wrappedValue) { _, _ in commitNow() }
        }
    }

    private func iconStyleCard(_ id: UUID) -> some View {
        menuCard(
            title: "Icon",
            width: 190,
            value: bindingIconStyle(id),
            options: NodeIconStyleFamily.allCases.map { ($0, $0.label) }
        )
    }

    private func dividerStyleCard(_ id: UUID) -> some View {
        menuCard(
            title: "Divider",
            width: 190,
            value: bindingDividerStyle(id),
            options: NodeDividerStyleFamily.allCases.map { ($0, $0.label) }
        )
    }

    /// Variant picker for link nodes. Without it, the radius slider
    /// looks broken on a fresh link because the default `.pill`
    /// variant always paints a capsule.
    private func linkVariantCard(_ id: UUID) -> some View {
        menuCard(
            title: "Variant",
            width: 170,
            value: bindingLinkVariant(id),
            options: NodeLinkStyleVariant.allCases.map { ($0, $0.label) }
        )
    }

    private func imageFitCard(_ id: UUID) -> some View {
        menuCard(
            title: "Fit",
            width: 140,
            value: bindingImageFit(id),
            options: [(.fill, "Fill"), (.fit, "Fit")]
        )
    }

    /// Gallery variant: defaults to `.fit` to match
    /// `GalleryNodeView.cachedImageFit` so a freshly-added gallery
    /// reports the same value the renderer is actually showing.
    private func galleryImageFitCard(_ id: UUID) -> some View {
        menuCard(
            title: "Fit",
            width: 140,
            value: bindingGalleryImageFit(id),
            options: [(.fit, "Fit"), (.fill, "Fill")]
        )
    }

    private func clipShapeCard(_ id: UUID) -> some View {
        menuCard(
            title: "Shape",
            width: 150,
            value: bindingClipShape(id),
            options: [(.rectangle, "Rect"), (.circle, "Circle")]
        )
    }

    /// Single grouped card that owns every gradient control: the
    /// on/off switch in the header, the two color stops, the
    /// direction picker, and the spread + smoothness sliders. Keeping
    /// the cluster in one card (instead of six siblings on the
    /// horizontal scroller) makes the relationship obvious — the
    /// sub-controls are visibly part of the same surface as the
    /// toggle that gates them, and they collapse out of view when
    /// the gradient is off so the rest of the Style tab stays
    /// uncluttered.
    private func gradientGroupCard(_ id: UUID) -> some View {
        let enabled = bindingGradientEnabled(id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("GRADIENT")
                    .font(.cucuMono(9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.cucuInkFaded)
                Spacer(minLength: 0)
                Toggle("", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: enabled.wrappedValue) { _, _ in commitNow() }
            }

            if enabled.wrappedValue {
                HStack(spacing: 8) {
                    gradientColorTile(
                        title: "Start",
                        hex: bindingStyleHex(id, key: \.gradientStartColorHex, defaultHex: "#FFFFFF")
                    )
                    gradientColorTile(
                        title: "End",
                        hex: bindingStyleHex(id, key: \.gradientEndColorHex, defaultHex: "#FFC1D8")
                    )
                    gradientDirectionTile(id: id)
                }

                gradientSliderRow(
                    title: "Spread",
                    binding: bindingStyleDouble(id, key: \.gradientSpread, defaultValue: 1.0),
                    valueText: "\(Int((document.nodes[id]?.style.gradientSpread ?? 1.0) * 100))%"
                )
                gradientSliderRow(
                    title: "Smoothness",
                    binding: bindingStyleDouble(id, key: \.gradientSmoothness, defaultValue: 0),
                    valueText: "\(Int((document.nodes[id]?.style.gradientSmoothness ?? 0) * 100))%"
                )
            } else {
                Text("Off")
                    .font(.cucuSerif(13, weight: .semibold))
                    .foregroundStyle(Color.cucuInkFaded)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: enabled.wrappedValue ? 320 : 158,
               height: enabled.wrappedValue ? nil : 86,
               alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cucuCard))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.14), lineWidth: 1)
        )
    }

    /// Compact color-stop tile used inside the gradient group card.
    /// Mirrors the `colorCard` look but shrinks the chrome so two
    /// tiles plus the direction picker fit comfortably on one row.
    private func gradientColorTile(title: String, hex: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.cucuMono(8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.cucuInkFaded)
            ColorPicker("", selection: hex.asColor(), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 30, height: 30)
                .onChange(of: hex.wrappedValue) { _, _ in commitNow() }
        }
    }

    /// Direction picker tile inside the gradient group card. Uses a
    /// menu so the four named directions stay legible without forcing
    /// the card to widen for a segmented control.
    private func gradientDirectionTile(id: UUID) -> some View {
        let direction = bindingGradientDirection(id)
        return VStack(alignment: .leading, spacing: 4) {
            Text("DIRECTION")
                .font(.cucuMono(8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.cucuInkFaded)
            Menu {
                ForEach(NodeGradientDirection.allCases, id: \.self) { option in
                    Button {
                        direction.wrappedValue = option
                        commitNow()
                    } label: {
                        if option == direction.wrappedValue {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(direction.wrappedValue.label)
                        .font(.cucuSerif(13, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.cucuInkFaded)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.cucuCardSoft))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Compact slider row used inside the gradient group card. Lays
    /// out as `[label] [slider] [value]` so spread and smoothness
    /// each take exactly one line of vertical space, keeping the
    /// card from growing taller than the other Style-tab cards by
    /// more than necessary.
    private func gradientSliderRow(title: String,
                                   binding: Binding<Double>,
                                   valueText: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.cucuSerif(12, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .frame(width: 86, alignment: .leading)
            Slider(value: binding, in: 0...1, step: 0.01) { editing in
                if !editing { commitNow() }
            }
            Text(valueText)
                .font(.cucuMono(10, weight: .medium))
                .foregroundStyle(Color.cucuInkSoft)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func galleryLayoutCard(_ id: UUID) -> some View {
        menuCard(
            title: "Gallery",
            width: 160,
            value: bindingGalleryLayout(id),
            options: NodeGalleryLayout.allCases.map { ($0, $0.label) }
        )
    }

    private func containerBackgroundCard(_ node: CanvasNode) -> some View {
        cardShell(title: "Image", width: 168) {
            if let path = node.style.backgroundImagePath,
               !path.isEmpty,
               let preview = LocalCanvasAssetStore.loadUIImage(path) {
                Menu {
                    PhotosPicker(
                        selection: $containerBackgroundSelection,
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
                    HStack(spacing: 9) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Manage")
                            .font(.cucuSerif(14, weight: .semibold))
                            .foregroundStyle(Color.cucuInk)
                        Spacer()
                    }
                }
            } else {
                PhotosPicker(
                    selection: $containerBackgroundSelection,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                        Text(pickerLoading ? "Loading..." : "Add")
                        Spacer()
                    }
                    .font(.cucuSerif(14, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                }
                .disabled(pickerLoading)
            }
        }
    }

    private func frameSizeCard(_ id: UUID) -> some View {
        cardShell(title: "Size", width: 190) {
            VStack(spacing: 6) {
                Slider(value: bindingFrameWidth(id), in: 24...360, step: 2) { editing in
                    if !editing { commitNow() }
                }
                Slider(value: bindingFrameHeight(id), in: 24...520, step: 2) { editing in
                    if !editing { commitNow() }
                }
            }
        }
    }

    private func positionCard(_ id: UUID) -> some View {
        cardShell(title: "Position", width: 190) {
            HStack(spacing: 10) {
                Stepper("X", value: bindingFrameX(id), in: 0...600, step: 4)
                    .labelsHidden()
                Stepper("Y", value: bindingFrameY(id), in: 0...800, step: 4)
                    .labelsHidden()
            }
        }
    }

    private func alignmentHelpersCard(_ id: UUID) -> some View {
        cardShell(title: "Align", width: 168) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    alignButton("align.horizontal.left", id: id, horizontal: .leading)
                    alignButton("align.horizontal.center", id: id, horizontal: .center)
                    alignButton("align.horizontal.right", id: id, horizontal: .trailing)
                }
                HStack(spacing: 6) {
                    alignButton("align.vertical.top", id: id, vertical: .top)
                    alignButton("align.vertical.center", id: id, vertical: .center)
                    alignButton("align.vertical.bottom", id: id, vertical: .bottom)
                }
            }
        }
    }

    private func alignButton(_ systemName: String,
                             id: UUID,
                             horizontal: HorizontalAlignmentTarget? = nil,
                             vertical: VerticalAlignmentTarget? = nil) -> some View {
        Button {
            alignNode(id, horizontal: horizontal, vertical: vertical)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.cucuCardSoft))
        }
        .buttonStyle(.plain)
    }

    private func infoCard(title: String, text: String) -> some View {
        cardShell(title: title, width: 142) {
            Text(text)
                .font(.cucuSerif(14, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyState(title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
            Text(title)
                .font(.cucuSerif(14, weight: .semibold))
                .foregroundStyle(Color.cucuInkSoft)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 96)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cucuCard.opacity(0.85)))
    }

    // MARK: - Bindings

    private func bindingText(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.text ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                let oldText = node.content.text ?? ""
                node.content.text = newValue
                reconcileTextStyleSpans(afterTextChangeFrom: oldText, to: newValue, in: &node)
                document.nodes[id] = node
                scheduleCommit()
            }
        )
    }

    private func bindingNoteTitle(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.noteTitle ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.noteTitle = newValue
                document.nodes[id] = node
                scheduleCommit()
            }
        )
    }

    private func bindingNoteTimestamp(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.noteTimestamp ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.noteTimestamp = newValue
                document.nodes[id] = node
                scheduleCommit()
            }
        )
    }

    private func bindingStyleHex(_ id: UUID,
                                 key: WritableKeyPath<NodeStyle, String?>,
                                 defaultHex: String) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.style[keyPath: key] ?? defaultHex },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Specialised binding for `style.textColorHex` that also flips
    /// `textColorAuto` off on user pick. The structured-profile
    /// normalizer rewrites `textColorHex` for the hero's name /
    /// @username / bio whenever `textColorAuto == true`, so an
    /// explicit pick has to clear that flag in the same write —
    /// otherwise the next normalize pass would reset the hex back to
    /// the contrast default and the user's color would never stick.
    /// Non-hero text nodes have `textColorAuto` nil/false to begin
    /// with so this is a no-op for them, and the binding is safe to
    /// use everywhere `textColorHex` is edited.
    private func bindingTextColor(_ id: UUID, defaultHex: String) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.style.textColorHex ?? defaultHex },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.textColorHex = newValue
                node.style.textColorAuto = false
                document.nodes[id] = node
            }
        )
    }

    private func bindingStyleDouble(_ id: UUID,
                                    key: WritableKeyPath<NodeStyle, Double?>,
                                    defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style[keyPath: key] ?? defaultValue },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingStyleDouble(_ id: UUID,
                                    key: WritableKeyPath<NodeStyle, Double>,
                                    defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style[keyPath: key] ?? defaultValue },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingOptionalStyleDouble(_ id: UUID,
                                            key: WritableKeyPath<NodeStyle, Double?>,
                                            defaultValue: Double = 0) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style[keyPath: key] ?? defaultValue },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style[keyPath: key] = newValue > 0.01 ? newValue : nil
                document.nodes[id] = node
            }
        )
    }

    private func bindingNodeDouble(_ id: UUID,
                                   key: WritableKeyPath<CanvasNode, Double>,
                                   defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?[keyPath: key] ?? defaultValue },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node[keyPath: key] = newValue
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

    private func bindingTextUnderlined(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { document.nodes[id]?.style.textUnderlined == true },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.textUnderlined = newValue ? true : nil
                document.nodes[id] = node
            }
        )
    }

    private func bindingIconStyle(_ id: UUID) -> Binding<NodeIconStyleFamily> {
        Binding(
            get: { document.nodes[id]?.style.iconStyleFamily ?? .pastelDoodle },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.iconStyleFamily = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingDividerStyle(_ id: UUID) -> Binding<NodeDividerStyleFamily> {
        Binding(
            get: { document.nodes[id]?.style.dividerStyleFamily ?? .solid },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.dividerStyleFamily = newValue
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

    /// Outbound URL for icon nodes. Reuses the same `content.url`
    /// field link nodes use, so the published viewer's tap handler
    /// can stay type-agnostic. Debounced commit so each keystroke
    /// doesn't flood SwiftData; commits on Done / blur via the
    /// surrounding `commitTask` machinery.
    private func bindingIconURL(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.url ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.url = newValue
                document.nodes[id] = node
                scheduleCommit()
            }
        )
    }

    /// URL field for link nodes. Same field as `bindingIconURL` (both
    /// write `content.url`); kept as a separate helper for clarity at
    /// call sites and so a future link-only validation rule can be
    /// added without affecting icons.
    private func bindingLinkURL(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.url ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.content.url = newValue
                document.nodes[id] = node
                scheduleCommit()
            }
        )
    }

    private func bindingLinkVariant(_ id: UUID) -> Binding<NodeLinkStyleVariant> {
        Binding(
            get: { document.nodes[id]?.style.linkStyleVariant ?? .pill },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.linkStyleVariant = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Slider binding for a link's corner radius. The `.pill` and
    /// `.underlined` variants don't read `cornerRadius` (pill uses
    /// height/2, underlined paints no fill / border), so moving the
    /// slider on those variants would *appear* broken — the model
    /// updates and the selection overlay redraws, but the visible
    /// element keeps its old corners. Auto-promote those variants to
    /// `.card` on the same write so the user's intent ("I want this
    /// corner radius") actually lands. Card / button / badge already
    /// honor cornerRadius, so they pass through untouched.
    private func bindingLinkCornerRadius(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style.cornerRadius ?? 0 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.cornerRadius = newValue
                let variant = node.style.linkStyleVariant ?? .pill
                if variant == .pill || variant == .underlined {
                    node.style.linkStyleVariant = .card
                }
                document.nodes[id] = node
            }
        )
    }

    private func bindingImageFit(_ id: UUID) -> Binding<NodeImageFit> {
        Binding(
            get: { document.nodes[id]?.style.imageFit ?? .fill },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.imageFit = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Same field as `bindingImageFit`, but the read-side default is
    /// `.fit` to match the gallery renderer (`GalleryNodeView`).
    /// Without this the picker would show "Fill" on a fresh gallery
    /// even though the photos were drawn `.fit`.
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

    private func bindingClipShape(_ id: UUID) -> Binding<NodeClipShape> {
        Binding(
            get: { document.nodes[id]?.style.clipShape ?? .rectangle },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.clipShape = newValue
                if newValue == .circle {
                    let side = min(node.frame.width, node.frame.height)
                    node.frame.width = side
                    node.frame.height = side
                }
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

    private func bindingGradientDirection(_ id: UUID) -> Binding<NodeGradientDirection> {
        Binding(
            get: { document.nodes[id]?.style.gradientDirection ?? .topToBottom },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.gradientDirection = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Toggle binding for the container gradient. The setter seeds
    /// default colors on first enable so the toggle produces a
    /// visible result without forcing the user to pick two colors
    /// before they see anything change.
    private func bindingGradientEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { document.nodes[id]?.style.gradientEnabled == true },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.gradientEnabled = newValue ? true : nil
                if newValue {
                    if node.style.gradientStartColorHex == nil {
                        node.style.gradientStartColorHex = node.style.backgroundColorHex ?? "#FFFFFF"
                    }
                    if node.style.gradientEndColorHex == nil {
                        node.style.gradientEndColorHex = "#FFC1D8"
                    }
                    if node.style.gradientDirection == nil {
                        node.style.gradientDirection = .topToBottom
                    }
                    if node.style.gradientSpread == nil {
                        node.style.gradientSpread = 1.0
                    }
                    if node.style.gradientSmoothness == nil {
                        node.style.gradientSmoothness = 0.0
                    }
                }
                document.nodes[id] = node
            }
        )
    }

    private func bindingFrameX(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.frame.x ?? 0 },
            set: { setFrame(id) { $0.origin.x = CGFloat($1) }($0) }
        )
    }

    private func bindingFrameY(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.frame.y ?? 0 },
            set: { setFrame(id) { $0.origin.y = CGFloat($1) }($0) }
        )
    }

    private func bindingFrameWidth(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.frame.width ?? 24 },
            set: { setFrame(id) { $0.size.width = CGFloat($1) }($0) }
        )
    }

    private func bindingFrameHeight(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.frame.height ?? 24 },
            set: { setFrame(id) { $0.size.height = CGFloat($1) }($0) }
        )
    }

    private func setFrame(_ id: UUID, _ update: @escaping (inout CGRect, Double) -> Void) -> (Double) -> Void {
        { value in
            guard var node = document.nodes[id] else { return }
            var frame = node.frame.cgRect
            update(&frame, value)
            frame = clampedFrame(frame, for: id)
            node.frame = NodeFrame(frame)
            document.nodes[id] = node
            if node.role == .sectionCard {
                StructuredProfileLayout.normalize(&document)
            }
        }
    }

    // MARK: - Layout helpers

    private enum HorizontalAlignmentTarget {
        case leading
        case center
        case trailing
    }

    private enum VerticalAlignmentTarget {
        case top
        case center
        case bottom
    }

    private func alignNode(_ id: UUID,
                           horizontal: HorizontalAlignmentTarget? = nil,
                           vertical: VerticalAlignmentTarget? = nil) {
        guard var node = document.nodes[id],
              let bounds = parentBounds(for: id) else { return }
        var frame = node.frame.cgRect
        if let horizontal {
            switch horizontal {
            case .leading: frame.origin.x = 0
            case .center: frame.origin.x = (bounds.width - frame.width) / 2
            case .trailing: frame.origin.x = bounds.width - frame.width
            }
        }
        if let vertical {
            switch vertical {
            case .top: frame.origin.y = 0
            case .center: frame.origin.y = (bounds.height - frame.height) / 2
            case .bottom: frame.origin.y = bounds.height - frame.height
            }
        }
        node.frame = NodeFrame(clampedFrame(frame, for: id))
        document.nodes[id] = node
        commitNow()
    }

    private func clampedFrame(_ frame: CGRect, for id: UUID) -> CGRect {
        guard isInsideSectionCard(id),
              document.nodes[id]?.role != .sectionCard,
              let bounds = parentBounds(for: id) else {
            return frame
        }
        var next = frame
        next.size.width = min(max(next.width, 24), bounds.width)
        next.size.height = min(max(next.height, 24), bounds.height)
        next.origin.x = min(max(0, next.origin.x), max(0, bounds.width - next.width))
        next.origin.y = min(max(0, next.origin.y), max(0, bounds.height - next.height))
        return next
    }

    private func parentBounds(for id: UUID) -> CGSize? {
        if let parentID = document.parent(of: id),
           let parent = document.nodes[parentID] {
            return CGSize(width: parent.frame.width, height: parent.frame.height)
        }
        guard let pageIndex = document.pageContaining(id),
              document.pages.indices.contains(pageIndex) else { return nil }
        return CGSize(width: document.pageWidth, height: document.pages[pageIndex].height)
    }

    private func isInsideSectionCard(_ id: UUID) -> Bool {
        guard document.nodes[id]?.role != .sectionCard else { return false }
        return StructuredProfileLayout.sectionCardAncestor(containing: id, in: document) != nil
    }

    private var canAddElements: Bool {
        guard document.nodes[selectedID] != nil else { return false }
        return !StructuredProfileLayout.isInSystemProfileSubtree(selectedID, in: document)
    }

    private func editableTextID(for node: CanvasNode) -> UUID? {
        if node.type == .text || node.type == .link { return node.id }
        if node.type == .container || node.role == .sectionCard {
            return node.childrenIDs.first { document.nodes[$0]?.type == .text }
        }
        return nil
    }

    // MARK: - Picker loading

    private func loadContainerBackground(_ item: PhotosPickerItem?) {
        guard let item else { return }
        guard document.nodes[selectedID]?.type == .container else {
            containerBackgroundSelection = nil
            return
        }
        pickerLoading = true
        pickerError = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        if onSetContainerBackground(selectedID, data) {
                            pickerError = nil
                        } else {
                            pickerError = "Couldn't save that image."
                        }
                        pickerLoading = false
                        containerBackgroundSelection = nil
                    }
                } else {
                    await MainActor.run {
                        pickerError = "Couldn't read that image."
                        pickerLoading = false
                        containerBackgroundSelection = nil
                    }
                }
            } catch {
                await MainActor.run {
                    pickerError = "Couldn't read that image."
                    pickerLoading = false
                    containerBackgroundSelection = nil
                }
            }
        }
    }

    /// Multi-photo loader for the gallery's "Add photos" picker on its
    /// first tab. Reads each transferable in parallel, then hands the
    /// non-empty bytes list to `onAppendGalleryPhotos`. Clears the
    /// selection slot so the picker is ready to fire again.
    private func loadGalleryAppend(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        guard document.nodes[selectedID]?.type == .gallery else {
            galleryAppendSelection = []
            return
        }
        pickerLoading = true
        pickerError = nil
        Task {
            var bytes: [Data] = []
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        bytes.append(data)
                    }
                } catch {
                    // Best effort — skip the unreadable item.
                }
            }
            await MainActor.run {
                if bytes.isEmpty {
                    pickerError = "Couldn't read those photos."
                } else if onAppendGalleryPhotos(selectedID, bytes) {
                    pickerError = nil
                } else {
                    pickerError = "Couldn't save the gallery photos."
                }
                pickerLoading = false
                galleryAppendSelection = []
            }
        }
    }

    /// Loader for the image-replace control on an image node's first
    /// tab. Mirrors `loadContainerBackground`'s shape so the two flows
    /// stay in lockstep: read transferable bytes, hand them to the
    /// host's replacement closure, and clear the selection slot
    /// regardless of outcome so the picker is ready to fire again.
    private func loadImageReplacement(_ item: PhotosPickerItem?) {
        guard let item else { return }
        guard document.nodes[selectedID]?.type == .image else {
            imageReplaceSelection = nil
            return
        }
        pickerLoading = true
        pickerError = nil
        Task {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        if onReplaceImage(selectedID, data) {
                            pickerError = nil
                        } else {
                            pickerError = "Couldn't save that photo."
                        }
                        pickerLoading = false
                        imageReplaceSelection = nil
                    }
                } else {
                    await MainActor.run {
                        pickerError = "Couldn't read that photo."
                        pickerLoading = false
                        imageReplaceSelection = nil
                    }
                }
            } catch {
                await MainActor.run {
                    pickerError = "Couldn't read that photo."
                    pickerLoading = false
                    imageReplaceSelection = nil
                }
            }
        }
    }

    // MARK: - Commit

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            onCommit(document)
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        onCommit(document)
    }

    // MARK: - Display helpers

    private func kind(for node: CanvasNode) -> CucuNodeKind {
        switch node.type {
        case .container: return .container
        case .text: return .text
        case .image: return .image
        case .icon: return .icon
        case .divider: return .divider
        case .link: return .link
        case .gallery: return .gallery
        case .carousel: return .carousel
        case .note: return .note
        }
    }

    private func iconName(for node: CanvasNode) -> String {
        switch node.type {
        case .container: return node.role == .sectionCard ? "rectangle.inset.filled" : "rectangle.on.rectangle"
        case .text: return "textformat"
        case .image: return "photo"
        case .icon: return "star.fill"
        case .divider: return "scribble"
        case .link: return "link"
        case .gallery: return "rectangle.grid.2x2"
        case .carousel: return "rectangle.stack"
        case .note: return "note.text"
        }
    }

    private func displayName(for node: CanvasNode) -> String {
        if node.role == .sectionCard { return "Section Card" }
        if node.role == .fixedDivider { return "Profile Divider" }
        if let name = node.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        switch node.type {
        case .container: return "Container"
        case .text: return "Text"
        case .image: return "Image"
        case .icon: return "Icon"
        case .divider: return "Divider"
        case .link: return "Link"
        case .gallery: return "Gallery"
        case .carousel: return "Carousel"
        case .note: return "Note"
        }
    }

    private func subtitle(for node: CanvasNode) -> String {
        if node.role == .sectionCard { return "Fixed width, vertical resize" }
        if StructuredProfileLayout.isInSystemProfileSubtree(node.id, in: document) {
            return "System owned"
        }
        if isInsideSectionCard(node.id) { return "Inside section card" }
        return "Selected element"
    }

    private func label(for font: NodeFontFamily) -> String {
        switch font {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Mono"
        case .caprasimo: return "Caprasimo"
        case .yesevaOne: return "Yeseva"
        case .abrilFatface: return "Abril"
        case .fraunces: return "Fraunces"
        case .fredoka: return "Fredoka"
        case .modak: return "Modak"
        case .bungee: return "Bungee"
        case .caveat: return "Caveat"
        case .pacifico: return "Pacifico"
        case .lobster: return "Lobster"
        case .permanentMarker: return "Marker"
        case .shadowsIntoLight: return "Shadows"
        case .patrickHand: return "Patrick"
        case .pressStart2P: return "Pixel"
        }
    }

    private func label(for weight: NodeFontWeight) -> String {
        switch weight {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "Semi"
        case .bold: return "Bold"
        }
    }
}
