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
    /// Whether the selection bottom bar is showing its full
    /// (expanded) form. Defaults to `false` on every new selection so
    /// tapping a node first surfaces only a small chevron pill — the
    /// canvas stays mostly visible for dragging. Tap the chevron to
    /// expand into the full bar.
    @State private var isSelectionBarExpanded = false
    @State private var showPageBackgroundSheet = false
    @State private var showBackgroundEffectsSheet = false
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
                    }
                )
            }
        }
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
                        onDelete: { deleteSelected() },
                        onCollapse: { isSelectionBarExpanded = false }
                    )
                } else {
                    CollapsedSelectionBar(
                        document: document,
                        selectedID: id,
                        onExpand: { isSelectionBarExpanded = true }
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
            ToolbarItem(placement: .principal) {
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
                    .onChange(of: titleDraft) { _, newValue in
                        store.updateTitle(draft, title: newValue.isEmpty ? "Untitled" : newValue)
                    }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showPageBackgroundSheet = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .disabled(legacyDraft)
                .accessibilityLabel("Page Background")

                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.square")
                }
                .disabled(legacyDraft)

                Menu {
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicateSelected() }
                        .disabled(selectedID == nil)
                    Button("Bring to Front", systemImage: "square.stack.3d.up") { bringSelectedToFront() }
                        .disabled(selectedID == nil)
                    Button("Send Backward", systemImage: "square.stack.3d.down.right") { sendSelectedBackward() }
                        .disabled(selectedID == nil)
                    Button("Edit Properties…", systemImage: "slider.horizontal.3") { showInspector = true }
                        .disabled(selectedID == nil)
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
                onPickImage: { data in addImageNode(from: data) }
            )
            .presentationDetents([.medium])
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
        case .text: node = .defaultText()
        case .image:
            // Image-add comes through `addImageNode(from:)` after the user
            // picks a photo and we have bytes in hand. The .image branch is
            // unreachable from `AddNodeSheet`'s type-emit path; keep a noop
            // so the switch is exhaustive.
            return
        }
        document.insert(node, under: parentID)
        selectedID = node.id
        store.updateDocument(draft, document: document)
    }

    /// Save picked image bytes to disk and create an image node referencing
    /// that local path. If the save fails, no node is created — the user's
    /// canvas stays clean.
    private func addImageNode(from data: Data) {
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
        } catch {
            // Save failed — surface nothing for now (no broken node added).
            // A future revision could show a transient toast.
        }
    }

    /// Save picked image bytes as the page background and update the
    /// document's `pageBackgroundImagePath`. Filename is fixed per draft
    /// (`page_background.jpg`) so replacing always overwrites cleanly.
    private func setPageBackgroundImage(_ data: Data) {
        do {
            let path = try LocalCanvasAssetStore.savePageBackground(
                data,
                draftID: draft.id
            )
            document.pageBackgroundImagePath = path
            store.updateDocument(draft, document: document)
        } catch {
            // Best-effort; existing background stays in place on failure.
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
    private func setContainerBackgroundImage(for nodeID: UUID, with data: Data) {
        guard var node = document.nodes[nodeID], node.type == .container else { return }
        do {
            let path = try LocalCanvasAssetStore.saveContainerBackground(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.style.backgroundImagePath = path
            document.nodes[nodeID] = node
            store.updateDocument(draft, document: document)
        } catch {
            // Best-effort; existing background stays in place on failure.
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
    private func replaceImage(for nodeID: UUID, with data: Data) {
        guard var node = document.nodes[nodeID], node.type == .image else { return }
        do {
            let path = try LocalCanvasAssetStore.saveImage(
                data,
                draftID: draft.id,
                nodeID: nodeID
            )
            node.content.localImagePath = path
            document.nodes[nodeID] = node
            store.updateDocument(draft, document: document)
        } catch {
            // Best-effort; existing image stays in place on failure.
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        document.remove(id)
        selectedID = nil
        store.updateDocument(draft, document: document)
    }

    private func duplicateSelected() {
        guard let id = selectedID else { return }
        if let newID = document.duplicate(id) {
            selectedID = newID
            store.updateDocument(draft, document: document)
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
}
