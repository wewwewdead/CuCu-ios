import SwiftData
import SwiftUI

/// Top-level canvas editor for one `ProfileDraft`. Owns the in-memory
/// `ProfileDocument`, hosts the UIKit canvas, exposes toolbar actions
/// (add / delete / duplicate), and binds the property inspector sheet to
/// the current selection.
///
/// Persistence cadence:
/// - Every gesture-end (drag, resize) calls `onCommit` from the canvas, which
///   persists once.
/// - Every add / delete / duplicate / inspector-commit persists explicitly.
/// - In-flight pan/resize updates the in-memory document and re-renders the
///   canvas, but does not hit SwiftData until the gesture ends.
struct ProfileCanvasBuilderView: View {
    @Bindable var draft: ProfileDraft
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var document: ProfileDocument = .blank
    @State private var selectedID: UUID?
    @State private var legacyDraft: Bool = false
    @State private var showAddSheet = false
    @State private var showInspector = false
    @State private var showPreview = false
    @State private var showPublishSheet = false
    @State private var showOpenProfileSheet = false
    /// Username to push into the public viewer right after a successful
    /// publish, or when the user explicitly opens "View Published" from
    /// the overflow menu.
    @State private var publishedViewerUsername: String?
    /// Whether the selection bottom bar is showing its full
    /// (expanded) form. Defaults to `false` on every new selection so
    /// tapping a node first surfaces only a small chevron pill — the
    /// canvas stays mostly visible for dragging. Tap the chevron to
    /// expand into the full bar.
    @State private var isSelectionBarExpanded = false
    @State private var showPageBackgroundSheet = false
    @State private var showBackgroundEffectsSheet = false
    @State private var showLayersSheet = false
    @State private var showSaveTemplateSheet = false
    @State private var showApplyTemplateSheet = false
    /// Set when the user taps **Edit Image** inside `PageBackgroundSheet`.
    /// Read by the page-background sheet's `onDismiss` handler so the
    /// effects sheet only opens after the first sheet finishes its
    /// dismiss animation — avoids SwiftUI's "can't present from a view
    /// that's being dismissed" stutter.
    @State private var pendingShowBackgroundEffects = false
    /// Same chain pattern, but for editing a container's bg image
    /// effects from the property inspector.
    @State private var showContainerBackgroundEffectsSheet = false
    @State private var pendingShowContainerBackgroundEffects = false
    @State private var containerEffectsTargetID: UUID?
    @State private var titleDraft: String = ""


    private var store: DraftStore { DraftStore(context: context) }

    /// Where a new node will land if the user adds one right now. Mirrors
    /// the same rule used by `addNode(of:)` and `addImageNode(from:)`, so
    /// the AddNodeSheet's banner stays accurate.
    private var addDestination: AddNodeSheet.Destination {
        if let sid = selectedID, document.nodes[sid]?.type == .container {
            return .container
        }
        return .page
    }

    /// True when the canvas has zero nodes so the empty-state
    /// overlay should show. Both `rootChildrenIDs` and `nodes` get
    /// checked because a corrupt document could in theory have one
    /// without the other; an empty test that only checked one would
    /// leak through and hide the prompt.
    private var canvasIsEmpty: Bool {
        document.rootChildrenIDs.isEmpty && document.nodes.isEmpty
    }

    var body: some View {
        ZStack {
            if legacyDraft {
                legacyView
            } else {
                CanvasEditorContainer(
                    document: $document,
                    selectedID: $selectedID,
                    onCommit: { doc in
                        document = doc
                        store.updateDocument(draft, document: doc)
                    },
                    onRequestEditNode: { id in
                        // Long-press shortcut: open the existing
                        // property inspector for the pressed node. We
                        // reuse the same `showInspector` flag the
                        // toolbar / selection-bar Edit actions use, so
                        // there is exactly one inspector
                        // implementation. Guard against re-presenting
                        // when another modal is already up — the user
                        // explicitly asked for one editor at a time.
                        guard document.nodes[id] != nil else { return }
                        if showInspector { return }
                        if showPageBackgroundSheet
                            || showBackgroundEffectsSheet
                            || showLayersSheet
                            || showSaveTemplateSheet
                            || showApplyTemplateSheet
                            || showContainerBackgroundEffectsSheet
                            || showPublishSheet
                            || showOpenProfileSheet
                            || publishedViewerUsername != nil {
                            return
                        }
                        selectedID = id
                        showInspector = true
                    }
                )

                // Empty-state overlay — fades on top of the (empty)
                // canvas, fades out the moment the user adds the
                // first node. Wrapped in `.allowsHitTesting` so taps
                // on the CTAs land here, not on the canvas surface
                // behind. Hit-testing flips to false once content
                // exists, so the overlay never blocks edits.
                if canvasIsEmpty {
                    CanvasEmptyStateView(
                        onAddElement: { showAddSheet = true },
                        onUseTemplate: { showApplyTemplateSheet = true },
                        onPreview: { showPreview = true }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
                }
            }
        }
        .animation(.easeOut(duration: 0.32), value: canvasIsEmpty)
        .overlay(alignment: .bottom) {
            // Bottom selection surface — collapsed (small chevron pill)
            // by default, full bar when the user expands it. Floats
            // above the canvas (no safeAreaInset) so the canvas bounds
            // stay constant regardless of which form is showing.
            if !legacyDraft, let id = selectedID, document.nodes[id] != nil {
                if isSelectionBarExpanded {
                    SelectionBottomBar(
                        document: document,
                        selectedID: id,
                        onSelect: { newID in
                            selectedID = newID
                        },
                        onEdit: { showInspector = true },
                        onDuplicate: { duplicateSelected() },
                        onBringToFront: { bringSelectedToFront() },
                        onSendBackward: { sendSelectedBackward() },
                        onLayers: { showLayersSheet = true },
                        onDelete: { deleteSelected() },
                        onCollapse: { isSelectionBarExpanded = false }
                    )
                } else {
                    CollapsedSelectionBar(
                        document: document,
                        selectedID: id,
                        onExpand: { isSelectionBarExpanded = true },
                        onEdit: { showInspector = true },
                        onDuplicate: { duplicateSelected() },
                        onBringToFront: { bringSelectedToFront() },
                        onSendBackward: { sendSelectedBackward() },
                        onLayers: { showLayersSheet = true },
                        onDelete: { deleteSelected() }
                    )
                }
            }
        }
        // Opt the entire view tree out of SwiftUI's automatic
        // keyboard safe-area shrink. We don't want the canvas's
        // allotted space to change when the keyboard appears — the
        // canvas keeps its full size, and only the *editing text
        // node* lifts itself (via a transform inside the UIKit
        // canvas) to sit above the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: selectedID)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isSelectionBarExpanded)
        .onChange(of: selectedID) { _, newID in
            // Each new selection starts collapsed so the user can drag
            // the freshly-tapped node without the full bar covering the
            // canvas.
            isSelectionBarExpanded = false

            // Background interaction is enabled on every editing sheet,
            // so a canvas tap can change `selectedID` while a sheet is
            // open. We close any selection-tied surface here so it
            // doesn't linger as a blank modal (the inspector's content
            // closure resolves to nothing when `selectedID` is nil) or
            // keep editing the wrong node.
            if newID == nil {
                showInspector = false
                showContainerBackgroundEffectsSheet = false
                pendingShowContainerBackgroundEffects = false
                containerEffectsTargetID = nil
            } else if newID != containerEffectsTargetID,
                      showContainerBackgroundEffectsSheet {
                // Selection moved to a different node — the effects
                // sheet was tied to the original container, so close it.
                showContainerBackgroundEffectsSheet = false
                containerEffectsTargetID = nil
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Leading: Explore feed. Lives here (not in `RootView`)
            // because the product is single-document and `RootView`
            // is now a thin routing shell — the canvas builder owns
            // the visible chrome.
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    PublishedProfilesListView()
                } label: {
                    Image(systemName: "sparkles")
                }
                .accessibilityLabel("Explore Profiles")
                .disabled(legacyDraft)
            }

            ToolbarItem(placement: .principal) {
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .onChange(of: titleDraft) { _, newValue in
                        store.updateTitle(draft, title: newValue.isEmpty ? "Untitled" : newValue)
                    }
            }
            // Three visible trailing items: Add, Publish, Menu.
            // We previously had five (photo, layers, plus, publish,
            // …) which on smaller iPhones overflowed the nav bar
            // — the Publish button could end up hidden behind iOS's
            // auto-collapse, which is exactly what users were
            // hitting. Page Settings + Layers are still reachable
            // from the overflow menu below; Add and Publish are the
            // two primary actions and need to be visible at all
            // times so they stay in the bar.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.square")
                }
                .disabled(legacyDraft)
                .accessibilityLabel("Add Element")

                Button {
                    showPreview = true
                } label: {
                    Image(systemName: "eye")
                }
                .disabled(legacyDraft || canvasIsEmpty)
                .accessibilityLabel("Preview")

                Button {
                    showPublishSheet = true
                } label: {
                    // Filled paperplane once a publish has succeeded —
                    // gives the user a free "this draft is live"
                    // affordance without an extra label.
                    Image(systemName: draft.publishedProfileId == nil
                          ? "paperplane"
                          : "paperplane.fill")
                }
                .disabled(legacyDraft)
                .accessibilityLabel("Publish")

                Menu {
                    Button("Page Settings", systemImage: "photo.on.rectangle.angled") {
                        showPageBackgroundSheet = true
                    }
                    Button("Layers", systemImage: "square.3.layers.3d") { showLayersSheet = true }
                    Divider()
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicateSelected() }
                        .disabled(selectedID == nil)
                    Button("Bring to Front", systemImage: "square.stack.3d.up") { bringSelectedToFront() }
                        .disabled(selectedID == nil)
                    Button("Send Backward", systemImage: "square.stack.3d.down.right") { sendSelectedBackward() }
                        .disabled(selectedID == nil)
                    Button("Edit Properties…", systemImage: "slider.horizontal.3") { showInspector = true }
                        .disabled(selectedID == nil)
                    Divider()
                    Button("Save as Template", systemImage: "square.and.arrow.down") {
                        showSaveTemplateSheet = true
                    }
                    Button("Apply Template", systemImage: "square.on.square") {
                        showApplyTemplateSheet = true
                    }
                    Divider()
                    if let published = draft.publishedUsername, !published.isEmpty {
                        Button("View Published", systemImage: "eye") {
                            publishedViewerUsername = published
                        }
                    }
                    Button("Open Profile by Username", systemImage: "person.crop.circle.badge.questionmark") {
                        showOpenProfileSheet = true
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { deleteSelected() }
                        .disabled(selectedID == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(legacyDraft)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddNodeSheet(
                destination: addDestination,
                onPickType: { type in addNode(of: type) },
                onPickImage: { data in addImageNode(from: data) },
                onPickAvatar: { data in addAvatarNode(from: data) },
                onPickGallery: { dataList in addGalleryNode(from: dataList) },
                onPickSection: { preset in addSectionPreset(preset) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(
            isPresented: $showInspector,
            onDismiss: {
                // Same chain trick as the page-background flow: defer
                // presenting the effects sheet until the inspector
                // finishes its dismiss animation. Also validate the
                // target — if the container was deleted or the target
                // ID is stale, drop the chain instead of presenting a
                // blank effects sheet.
                guard pendingShowContainerBackgroundEffects else { return }
                pendingShowContainerBackgroundEffects = false
                guard let id = containerEffectsTargetID,
                      document.nodes[id]?.type == .container else {
                    containerEffectsTargetID = nil
                    return
                }
                showContainerBackgroundEffectsSheet = true
            }
        ) {
            if let id = selectedID {
                PropertyInspectorView(
                    document: $document,
                    selectedID: id,
                    onCommit: { doc in store.updateDocument(draft, document: doc) },
                    onReplaceImage: { nodeID, data in replaceImage(for: nodeID, with: data) },
                    onSetContainerBackground: { nodeID, data in
                        setContainerBackgroundImage(for: nodeID, with: data)
                    },
                    onClearContainerBackground: { nodeID in
                        clearContainerBackgroundImage(for: nodeID)
                    },
                    onEditContainerBackground: { nodeID in
                        containerEffectsTargetID = nodeID
                        pendingShowContainerBackgroundEffects = true
                        showInspector = false
                    },
                    onAppendGalleryImages: { nodeID, dataList in
                        appendGalleryImages(for: nodeID, with: dataList)
                    },
                    onRemoveGalleryImage: { nodeID, index in
                        removeGalleryImage(for: nodeID, at: index)
                    }
                )
                // Compact bottom sheet: starts at ~30% of screen so the
                // canvas stays visible. User can drag up to medium / large
                // for more controls. `presentationBackgroundInteraction`
                // keeps the canvas tap/drag-able while the sheet is at
                // small or medium — that's how the live preview actually
                // works without forcing the user to dismiss the inspector
                // every time they want to nudge a node.
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
            }
        }
        .sheet(
            isPresented: $showPageBackgroundSheet,
            onDismiss: {
                // After the page-background sheet finishes dismissing,
                // open the effects sheet if the user requested it.
                // Doing the chain inside `onDismiss` avoids the
                // sheet-on-sheet flicker SwiftUI produces if you set
                // both flags simultaneously.
                if pendingShowBackgroundEffects {
                    pendingShowBackgroundEffects = false
                    showBackgroundEffectsSheet = true
                }
            }
        ) {
            PageBackgroundSheet(
                document: $document,
                onPickImage: { data in setPageBackgroundImage(data) },
                onClearImage: { clearPageBackgroundImage() },
                onCommit: { store.updateDocument(draft, document: document) },
                onEditEffects: {
                    pendingShowBackgroundEffects = true
                    showPageBackgroundSheet = false
                }
            )
            .presentationDetents([.fraction(0.3), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showLayersSheet) {
            LayersPanelView(
                document: document,
                selectedID: $selectedID,
                onDeleteSelected: { deleteSelected() },
                onBringToFront: { bringSelectedToFront() },
                onSendBackward: { sendSelectedBackward() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showSaveTemplateSheet) {
            SaveTemplateSheet(
                defaultName: draft.title.isEmpty ? "Untitled Template" : draft.title,
                onSave: { name in saveTemplate(named: name) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showApplyTemplateSheet) {
            ApplyTemplateSheet(
                onApply: { template in applyTemplate(template) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBackgroundEffectsSheet) {
            BackgroundEffectsSheet(
                title: "Edit Page Image",
                blur: Binding(
                    get: { document.pageBackgroundBlur },
                    set: { document.pageBackgroundBlur = $0 }
                ),
                vignette: Binding(
                    get: { document.pageBackgroundVignette },
                    set: { document.pageBackgroundVignette = $0 }
                ),
                onCommit: { store.updateDocument(draft, document: document) }
            )
            .presentationDetents([.fraction(0.3), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationContentInteraction(.scrolls)
        }
        .sheet(
            isPresented: $showContainerBackgroundEffectsSheet,
            onDismiss: {
                // Reset the target so a stale ID can never resurface as
                // a blank modal if SwiftUI re-presents this sheet later
                // for any reason.
                containerEffectsTargetID = nil
            }
        ) {
            if let id = containerEffectsTargetID, document.nodes[id]?.type == .container {
                BackgroundEffectsSheet(
                    title: "Edit Container Image",
                    blur: containerBlurBinding(id: id),
                    vignette: containerVignetteBinding(id: id),
                    onCommit: { store.updateDocument(draft, document: document) }
                )
                .presentationDetents([.fraction(0.3), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
            }
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(
                draft: draft,
                document: document,
                onViewPublished: { username in
                    // Push the public viewer onto the same nav stack
                    // after the publish sheet dismisses. Using
                    // `publishedViewerUsername` as a binding-driven
                    // navigation trigger keeps the logic in one place
                    // for both "View Profile" right after publish and
                    // "View Published" from the overflow menu.
                    publishedViewerUsername = username
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showOpenProfileSheet) {
            OpenPublishedProfileSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showPreview) {
            // Preview lives in `.fullScreenCover` (not `.sheet`) so
            // it really does fill the screen — the user is checking
            // what visitors see, not skimming a quick form.
            CanvasPreviewView(
                document: document,
                onClose: { showPreview = false },
                onPublish: {
                    showPreview = false
                    // Defer presenting the publish sheet until the
                    // cover finishes its dismissal animation —
                    // SwiftUI doesn't allow "present from a view
                    // currently being dismissed".
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showPublishSheet = true
                    }
                }
            )
        }
        .navigationDestination(item: $publishedViewerUsername) { username in
            PublishedProfileView(username: username)
        }
        .onAppear(perform: loadDraft)
        .onChange(of: selectedID) { _, newID in
            // Auto-open inspector when a node is selected and the user taps
            // the toolbar option. Selection alone shouldn't open the sheet
            // (it'd block the canvas), so we leave that to the menu.
            _ = newID
        }
    }

    // MARK: - Legacy draft fallback

    private var legacyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("This draft uses an older format.")
                .font(.headline)
            Text("Starting fresh will replace its contents with a blank canvas. The current data will be overwritten only after you confirm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Start fresh canvas") {
                document = .blank
                legacyDraft = false
                store.updateDocument(draft, document: document)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Loading

    private func loadDraft() {
        titleDraft = draft.title
        switch CanvasDocumentCodec.decode(draft.designJSON) {
        case .document(let doc):
            document = doc
            legacyDraft = false
        case .legacy:
            // Don't overwrite. Show banner; user opts in to blank canvas.
            legacyDraft = true
        case .empty:
            // Brand-new or wiped — seed a blank doc and persist so subsequent
            // launches go straight to .document.
            document = .blank
            legacyDraft = false
            store.updateDocument(draft, document: document)
        }
    }

    // MARK: - Templates

    private func saveTemplate(named name: String) -> Bool {
        do {
            _ = try TemplateStore(context: context).createTemplate(
                name: name,
                document: document
            )
            return true
        } catch {
            return false
        }
    }

    private func applyTemplate(_ template: ProfileTemplate) -> Bool {
        do {
            let appliedDocument = try TemplateStore(context: context).apply(template, to: draft)
            document = appliedDocument
            selectedID = nil
            legacyDraft = false
            showInspector = false
            showLayersSheet = false
            CucuHaptics.success()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Mutations

    private func addNode(of type: NodeType) {
        // Parent: currently selected container if any, else page root.
        let parentID: UUID? = {
            if let sid = selectedID, document.nodes[sid]?.type == .container {
                return sid
            }
            return nil
        }()

        let node: CanvasNode
        switch type {
        case .container: node = .defaultContainer()
        case .text:      node = .defaultText()
        case .image:
            // Image-add comes through `addImageNode(from:)` after the user
            // picks a photo and we have bytes in hand. The .image branch is
            // unreachable from `AddNodeSheet`'s type-emit path; keep a noop
            // so the switch is exhaustive.
            return
        case .icon:      node = .defaultIcon()
        case .divider:   node = .defaultDivider()
        case .link:      node = .defaultLink()
        case .gallery:
            // Gallery-add comes through `addGalleryNode(from:)` after the
            // user picks photos. Unreachable here; noop for exhaustivity.
            return
        }
        document.insert(node, under: parentID)
        selectedID = node.id
        store.updateDocument(draft, document: document)
        CucuHaptics.soft()
    }

    /// Save each picked image's bytes to disk under fresh per-image
    /// UUIDs and create one gallery node referencing all of them. The
    /// gallery's own `id` is distinct from the image-asset UUIDs so the
    /// node and its assets don't collide. Skips bytes that fail to
    /// normalize — partial saves are better than zero-image galleries
    /// and the user can pick more from the inspector if they want.
    @discardableResult
    private func addGalleryNode(from imageBytesList: [Data]) -> Bool {
        let parentID: UUID? = {
            if let sid = selectedID, document.nodes[sid]?.type == .container {
                return sid
            }
            return nil
        }()

        var savedPaths: [String] = []
        for bytes in imageBytesList {
            let assetID = UUID()
            do {
                let path = try LocalCanvasAssetStore.saveImage(
                    bytes,
                    draftID: draft.id,
                    nodeID: assetID
                )
                savedPaths.append(path)
            } catch {
                // Skip this image; keep the rest.
            }
        }
        guard !savedPaths.isEmpty else { return false }

        let node = CanvasNode.defaultGallery(imagePaths: savedPaths)
        document.insert(node, under: parentID)
        selectedID = node.id
        store.updateDocument(draft, document: document)
        return true
    }

    /// Append more images to an existing gallery node (called from the
    /// property inspector). New images are saved under fresh UUIDs and
    /// appended to the node's `imagePaths`. Returns `false` if no
    /// bytes saved at all so the inspector can surface a single error.
    @discardableResult
    private func appendGalleryImages(for nodeID: UUID, with imageBytesList: [Data]) -> Bool {
        guard var node = document.nodes[nodeID], node.type == .gallery else { return false }

        var newPaths: [String] = []
        for bytes in imageBytesList {
            let assetID = UUID()
            do {
                let path = try LocalCanvasAssetStore.saveImage(
                    bytes,
                    draftID: draft.id,
                    nodeID: assetID
                )
                newPaths.append(path)
            } catch { }
        }
        guard !newPaths.isEmpty else { return false }

        var existing = node.content.imagePaths ?? []
        existing.append(contentsOf: newPaths)
        node.content.imagePaths = existing
        document.nodes[nodeID] = node
        store.updateDocument(draft, document: document)
        return true
    }

    /// Remove the image at `index` from a gallery node. The underlying
    /// file is deleted only if no other node still references the same
    /// path (mirrors `deleteUnreferencedAssetPaths`).
    private func removeGalleryImage(for nodeID: UUID, at index: Int) {
        guard var node = document.nodes[nodeID],
              node.type == .gallery,
              var paths = node.content.imagePaths,
              index >= 0, index < paths.count else { return }
        let removed = paths.remove(at: index)
        node.content.imagePaths = paths
        document.nodes[nodeID] = node
        if !assetPathIsReferenced(removed, in: document) {
            LocalCanvasAssetStore.delete(relativePath: removed)
        }
        store.updateDocument(draft, document: document)
    }

    /// Save picked image bytes to disk and create an avatar node — a
    /// circle-clipped image at a square frame so the result is a true
    /// profile-pic circle on first paint. Identical disk-save path as
    /// `addImageNode`; only the style differs.
    @discardableResult
    private func addAvatarNode(from data: Data) -> Bool {
        let parentID: UUID? = {
            if let sid = selectedID, document.nodes[sid]?.type == .container {
                return sid
            }
            return nil
        }()
        let nodeID = UUID()
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            // Square frame + circle clip = profile-pic circle. The
            // size is intentionally smaller than `defaultImage`'s
            // 200pt because avatars typically read better at ~120pt.
            var node = CanvasNode.defaultImage(
                localImagePath: path,
                size: CGSize(width: 120, height: 120)
            )
            node.id = nodeID
            node.style.clipShape = .circle
            // Subtle white ring so the avatar separates from any
            // page background — same convention `imagePlaceholderTree`
            // uses inside the hero preset.
            node.style.borderColorHex = "#FFFFFF"
            node.style.borderWidth = 2
            document.insert(node, under: parentID)
            selectedID = nodeID
            store.updateDocument(draft, document: document)
            CucuHaptics.soft()
            return true
        } catch {
            return false
        }
    }

    /// Save picked image bytes to disk and create an image node referencing
    /// that local path. If the save fails, no node is created — the user's
    /// canvas stays clean.
    @discardableResult
    private func addImageNode(from data: Data) -> Bool {
        let parentID: UUID? = {
            if let sid = selectedID, document.nodes[sid]?.type == .container {
                return sid
            }
            return nil
        }()

        let nodeID = UUID()
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            var node = CanvasNode.defaultImage(localImagePath: path)
            node.id = nodeID
            document.insert(node, under: parentID)
            selectedID = nodeID
            store.updateDocument(draft, document: document)
            CucuHaptics.soft()
            return true
        } catch {
            // Save failed — no broken node is added. The add sheet keeps
            // itself open and shows the user a retryable error.
            return false
        }
    }

    private func addSectionPreset(_ preset: CanvasSectionPreset) {
        let parentID: UUID? = {
            if let sid = selectedID, document.nodes[sid]?.type == .container {
                return sid
            }
            return nil
        }()

        let tree = makeSectionPreset(preset, parentID: parentID)
        insertPresetTree(tree, under: parentID)
        selectedID = tree.node.id
        store.updateDocument(draft, document: document)
        CucuHaptics.soft()
    }

    private struct PresetNodeTree {
        var node: CanvasNode
        var children: [PresetNodeTree] = []
    }

    private func insertPresetTree(_ tree: PresetNodeTree, under parentID: UUID?) {
        document.insert(tree.node, under: parentID)
        for child in tree.children {
            insertPresetTree(child, under: tree.node.id)
        }
    }

    private func makeSectionPreset(_ preset: CanvasSectionPreset, parentID: UUID?) -> PresetNodeTree {
        let width = presetWidth(parentID: parentID)
        let origin = presetOrigin(parentID: parentID)

        switch preset {
        case .hero:
            return makeHeroPreset(origin: origin, width: width)
        case .interests:
            return makeInterestsPreset(origin: origin, width: width)
        case .wall:
            return makeWallPreset(origin: origin, width: width)
        case .journal:
            return makeJournalPreset(origin: origin, width: width)
        case .bulletin:
            return makeBulletinPreset(origin: origin, width: width)
        }
    }

    private func presetWidth(parentID: UUID?) -> Double {
        if let parentID, let parent = document.nodes[parentID] {
            return max(220, min(parent.frame.width - 32, 326))
        }
        return 326
    }

    private func presetOrigin(parentID: UUID?) -> CGPoint {
        if parentID != nil {
            return CGPoint(x: 16, y: 16)
        }

        let bottom = document.rootChildrenIDs
            .compactMap { document.nodes[$0] }
            .map { $0.frame.y + $0.frame.height }
            .max() ?? 56
        return CGPoint(x: 32, y: max(80, bottom + 24))
    }

    private func makeHeroPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let textX: Double = 124
        let rightWidth = max(128, width - textX - 16)
        let section = sectionContainer(
            name: "Hero Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 250),
            background: "#FFF7E6",
            border: "#E9C46A"
        )

        return PresetNodeTree(node: section, children: [
            imagePlaceholderTree(x: 16, y: 22, side: 92),
            textTree("Display Name", x: textX, y: 24, width: rightWidth, height: 34, size: 24, weight: .bold),
            textTree("Short bio about your vibe, projects, links, or current obsession.", x: textX, y: 66, width: rightWidth, height: 66, size: 14, color: "#3A3024"),
            textTree("profile badge", x: textX, y: 148, width: min(156, rightWidth), height: 34, size: 14, weight: .semibold, color: "#FFFFFF", background: "#D85C7A", cornerRadius: 17, alignment: .center),
            textTree("Make it yours", x: 16, y: 154, width: 92, height: 32, size: 13, weight: .medium, color: "#7C5B19", background: "#FFE9AD", cornerRadius: 16, alignment: .center)
        ])
    }

    private func makeInterestsPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Interests Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 188),
            background: "#F1FBF7",
            border: "#8BD8BD"
        )
        let tags = ["music", "coding", "anime", "design", "retro", "friends"]
        let chipWidth = max(78, min(92, (width - 44) / 3))
        let chipHeight: Double = 32
        let chipGap: Double = 8
        let chipTrees = tags.enumerated().map { index, title in
            let row = Double(index / 3)
            let col = Double(index % 3)
            return textTree(
                title,
                x: 16 + col * (chipWidth + chipGap),
                y: 58 + row * (chipHeight + chipGap),
                width: chipWidth,
                height: chipHeight,
                size: 13,
                weight: .semibold,
                color: "#185A43",
                background: "#D8F3E8",
                cornerRadius: 16,
                alignment: .center
            )
        }

        return PresetNodeTree(node: section, children: [
            textTree("Interests", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#123B2D")
        ] + chipTrees)
    }

    private func makeWallPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Wall Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 232),
            background: "#F5F1FF",
            border: "#B8A4F4"
        )
        let messageCard = containerTree(
            name: "Sample Message",
            frame: frame(16, 112, width - 32, 82),
            background: "#FFFFFF",
            cornerRadius: 12,
            border: "#E2DAFF",
            children: [
                textTree("Visitor", x: 12, y: 10, width: width - 56, height: 22, size: 14, weight: .bold, color: "#49327A"),
                textTree("Love this layout. The colors feel very you.", x: 12, y: 36, width: width - 56, height: 34, size: 13, color: "#3B3152")
            ]
        )

        return PresetNodeTree(node: section, children: [
            textTree("Wall", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#382062"),
            textTree("Leave a message...", x: 16, y: 58, width: width - 32, height: 38, size: 14, color: "#6D647C", background: "#FFFFFF", cornerRadius: 10),
            messageCard
        ])
    }

    private func makeJournalPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Journal Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 298),
            background: "#FFF4F1",
            border: "#F2A38D"
        )
        let cardData = [
            ("Today I redesigned my profile", "A quick note about the new colors."),
            ("Favorite links this week", "Three things worth saving."),
            ("Small update", "Still building, still changing.")
        ]
        let cards = cardData.enumerated().map { index, item in
            let y = 58 + Double(index) * 72
            return containerTree(
                name: "Journal Card",
                frame: frame(16, y, width - 32, 62),
                background: "#FFFFFF",
                cornerRadius: 12,
                border: "#F6D1C7",
                children: [
                    textTree(item.0, x: 12, y: 8, width: width - 56, height: 24, size: 14, weight: .bold, color: "#693226"),
                    textTree(item.1, x: 12, y: 34, width: width - 56, height: 20, size: 12, color: "#7A5B54")
                ]
            )
        }

        return PresetNodeTree(node: section, children: [
            textTree("Latest Journals", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#60281E")
        ] + cards)
    }

    private func makeBulletinPreset(origin: CGPoint, width: Double) -> PresetNodeTree {
        let section = sectionContainer(
            name: "Bulletin Section",
            frame: frame(Double(origin.x), Double(origin.y), width, 178),
            background: "#EFF7FF",
            border: "#91BEEB"
        )

        return PresetNodeTree(node: section, children: [
            textTree("Bulletins", x: 16, y: 16, width: width - 32, height: 30, size: 22, weight: .bold, color: "#143C66"),
            textTree("Status update: changing the whole profile again because the old one did not pass the vibe check.", x: 16, y: 58, width: width - 32, height: 76, size: 14, color: "#1F3F5F", background: "#FFFFFF", cornerRadius: 12),
            textTree("local placeholder", x: 16, y: 142, width: 134, height: 24, size: 12, weight: .medium, color: "#2E5E91", background: "#D8EAFC", cornerRadius: 12, alignment: .center)
        ])
    }

    private func sectionContainer(name: String,
                                  frame: NodeFrame,
                                  background: String,
                                  border: String) -> CanvasNode {
        CanvasNode(
            type: .container,
            name: name,
            frame: frame,
            style: NodeStyle(
                backgroundColorHex: background,
                cornerRadius: 16,
                borderWidth: 1,
                borderColorHex: border
            )
        )
    }

    private func containerTree(name: String,
                               frame: NodeFrame,
                               background: String,
                               cornerRadius: Double,
                               border: String,
                               children: [PresetNodeTree]) -> PresetNodeTree {
        PresetNodeTree(
            node: CanvasNode(
                type: .container,
                name: name,
                frame: frame,
                style: NodeStyle(
                    backgroundColorHex: background,
                    cornerRadius: cornerRadius,
                    borderWidth: 1,
                    borderColorHex: border
                )
            ),
            children: children
        )
    }

    private func textTree(_ text: String,
                          x: Double,
                          y: Double,
                          width: Double,
                          height: Double,
                          size: Double,
                          weight: NodeFontWeight = .regular,
                          color: String = "#1C1C1E",
                          background: String? = nil,
                          cornerRadius: Double = 0,
                          alignment: NodeTextAlignment = .leading) -> PresetNodeTree {
        PresetNodeTree(
            node: CanvasNode(
                type: .text,
                frame: frame(x, y, width, height),
                style: NodeStyle(
                    backgroundColorHex: background,
                    cornerRadius: cornerRadius,
                    borderWidth: 0,
                    borderColorHex: nil,
                    fontFamily: .system,
                    fontWeight: weight,
                    fontSize: size,
                    textColorHex: color,
                    textAlignment: alignment
                ),
                content: NodeContent(text: text)
            )
        )
    }

    private func imagePlaceholderTree(x: Double, y: Double, side: Double) -> PresetNodeTree {
        PresetNodeTree(
            node: CanvasNode(
                type: .image,
                frame: frame(x, y, side, side),
                style: NodeStyle(
                    backgroundColorHex: "#F2F2F7",
                    cornerRadius: side / 2,
                    borderWidth: 2,
                    borderColorHex: "#FFFFFF",
                    imageFit: .fill,
                    clipShape: .circle
                ),
                content: NodeContent()
            )
        )
    }

    private func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NodeFrame {
        NodeFrame(x: x, y: y, width: width, height: height)
    }

    /// Save picked image bytes as the page background and update the
    /// document's `pageBackgroundImagePath`. Filename is fixed per draft
    /// (`page_background.jpg`) so replacing always overwrites cleanly.
    @discardableResult
    private func setPageBackgroundImage(_ data: Data) -> Bool {
        do {
            let path = try LocalCanvasAssetStore.savePageBackground(
                data,
                draftID: draft.id
            )
            document.pageBackgroundImagePath = path
            store.updateDocument(draft, document: document)
            return true
        } catch {
            // Best-effort; existing background stays in place on failure.
            return false
        }
    }

    /// Clear the page background image — delete the file and unset the
    /// path so the canvas renders only the color again.
    private func clearPageBackgroundImage() {
        if let path = document.pageBackgroundImagePath {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        document.pageBackgroundImagePath = nil
        store.updateDocument(draft, document: document)
    }

    /// Two-way binding into a container node's `style.backgroundBlur`.
    /// Lifted into a helper because the inline closure inside the sheet
    /// modifier wouldn't capture `id` cleanly otherwise.
    private func containerBlurBinding(id: UUID) -> Binding<Double?> {
        Binding(
            get: { document.nodes[id]?.style.backgroundBlur },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.backgroundBlur = newValue
                document.nodes[id] = node
            }
        )
    }

    private func containerVignetteBinding(id: UUID) -> Binding<Double?> {
        Binding(
            get: { document.nodes[id]?.style.backgroundVignette },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style.backgroundVignette = newValue
                document.nodes[id] = node
            }
        )
    }

    /// Save picked bytes as the *container's* background image. Mirrors
    /// the page-background flow but writes to a per-node deterministic
    /// filename (`container_<UUID>.jpg`). Updates only the
    /// `style.backgroundImagePath` field; the rest of the node is
    /// untouched.
    @discardableResult
    private func setContainerBackgroundImage(for nodeID: UUID, with data: Data) -> Bool {
        guard var node = document.nodes[nodeID], node.type == .container else { return false }
        do {
            let path = try LocalCanvasAssetStore.saveContainerBackground(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.style.backgroundImagePath = path
            document.nodes[nodeID] = node
            store.updateDocument(draft, document: document)
            return true
        } catch {
            // Best-effort; existing background stays in place on failure.
            return false
        }
    }

    /// Remove the container's background image — delete the file and
    /// unset the path so the canvas renders just the color again.
    private func clearContainerBackgroundImage(for nodeID: UUID) {
        guard var node = document.nodes[nodeID], node.type == .container else { return }
        if let path = node.style.backgroundImagePath {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        node.style.backgroundImagePath = nil
        document.nodes[nodeID] = node
        store.updateDocument(draft, document: document)
    }

    /// Replace the image bytes for an existing image node. The new file is
    /// written under the node's own ID, so duplicated nodes that initially
    /// shared a path get their own file on first replacement (no clobbering
    /// the original's image).
    @discardableResult
    private func replaceImage(for nodeID: UUID, with data: Data) -> Bool {
        guard var node = document.nodes[nodeID], node.type == .image else { return false }
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.content.localImagePath = path
            document.nodes[nodeID] = node
            store.updateDocument(draft, document: document)
            return true
        } catch {
            // Best-effort; existing image stays in place on failure.
            return false
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        let removedAssetPaths = assetPaths(inSubtreeRootedAt: id, document: document)
        document.remove(id)
        deleteUnreferencedAssetPaths(removedAssetPaths)
        selectedID = nil
        store.updateDocument(draft, document: document)
        CucuHaptics.delete()
    }

    private func duplicateSelected() {
        guard let id = selectedID else { return }
        if let newID = document.duplicate(id) {
            copyImageAssetsForDuplicatedSubtree(rootedAt: newID)
            selectedID = newID
            store.updateDocument(draft, document: document)
            CucuHaptics.duplicate()
        }
    }

    private func bringSelectedToFront() {
        guard let id = selectedID else { return }
        document.bringToFront(id)
        store.updateDocument(draft, document: document)
    }

    private func sendSelectedBackward() {
        guard let id = selectedID else { return }
        document.sendBackward(id)
        store.updateDocument(draft, document: document)
    }

    // MARK: - Asset housekeeping

    /// After a duplicate, the copied image nodes initially point at the
    /// original nodes' files because `ProfileDocument.duplicate` is a pure
    /// model clone. Give each copied image node its own deterministic asset
    /// path so later replace/delete operations stay node-local.
    private func copyImageAssetsForDuplicatedSubtree(rootedAt rootID: UUID) {
        for nodeID in document.subtree(rootedAt: rootID) {
            guard var node = document.nodes[nodeID] else { continue }

            switch node.type {
            case .image:
                guard let currentPath = node.content.localImagePath,
                      !currentPath.isEmpty else { continue }
                do {
                    let copiedPath = try LocalCanvasAssetStore.copyImage(
                        from: currentPath,
                        draftID: draft.id,
                        nodeID: nodeID
                    )
                    node.content.localImagePath = copiedPath
                    document.nodes[nodeID] = node
                } catch {
                    // If the source file is missing, keep the copied node's path
                    // as-is so the renderer shows its existing placeholder.
                }
            case .gallery:
                guard let currentPaths = node.content.imagePaths,
                      !currentPaths.isEmpty else { continue }
                // Each gallery image gets its own fresh asset UUID under
                // the new node so per-image replace/delete stays node-local.
                var copied: [String] = []
                for original in currentPaths {
                    let assetID = UUID()
                    do {
                        let path = try LocalCanvasAssetStore.copyImage(
                            from: original,
                            draftID: draft.id,
                            nodeID: assetID
                        )
                        copied.append(path)
                    } catch {
                        // Source missing — preserve the path so the
                        // gallery's count stays right; the renderer
                        // will show a placeholder for the missing tile.
                        copied.append(original)
                    }
                }
                node.content.imagePaths = copied
                document.nodes[nodeID] = node
            default:
                break
            }
        }
    }

    private func assetPaths(inSubtreeRootedAt rootID: UUID, document: ProfileDocument) -> Set<String> {
        var paths: Set<String> = []
        for nodeID in document.subtree(rootedAt: rootID) {
            guard let node = document.nodes[nodeID] else { continue }
            if let path = node.content.localImagePath, !path.isEmpty {
                paths.insert(path)
            }
            if let path = node.style.backgroundImagePath, !path.isEmpty {
                paths.insert(path)
            }
            if let galleryPaths = node.content.imagePaths {
                for p in galleryPaths where !p.isEmpty { paths.insert(p) }
            }
        }
        return paths
    }

    private func deleteUnreferencedAssetPaths(_ paths: Set<String>) {
        for path in paths where !assetPathIsReferenced(path, in: document) {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
    }

    private func assetPathIsReferenced(_ path: String, in document: ProfileDocument) -> Bool {
        if document.pageBackgroundImagePath == path {
            return true
        }
        return document.nodes.values.contains { node in
            if node.content.localImagePath == path { return true }
            if node.style.backgroundImagePath == path { return true }
            if let gallery = node.content.imagePaths, gallery.contains(path) { return true }
            return false
        }
    }
}
