import SwiftData
import SwiftUI
import UIKit

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
///
/// The view's body is intentionally thin — the heavy lifting is in three
/// helper types it composes:
/// - `CanvasSheetCoordinator` owns every modal/transition flag and the
///   chained sheet hand-offs (page background → effects, inspector →
///   container effects).
/// - `CanvasMutator` owns every document mutation (add/delete/duplicate,
///   asset save/replace/delete, template save/apply).
/// - `CanvasPresetBuilder` owns the section-preset construction tree.
struct ProfileCanvasBuilderView: View {
    @Bindable var draft: ProfileDraft
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// Read so the destructive actions can authenticate against
    /// Supabase. The cloud-wipe paths short-circuit to a friendly
    /// alert when this is `nil` instead of silently dropping the
    /// network call.
    @Environment(AuthViewModel.self) private var auth
    /// Drives the compact-vs-regular sizing of the edit-mode chrome row.
    /// iPhone portrait reports `.compact`, which crowds against the
    /// centered title pill if the chrome stays at iPad-sized icons.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var document: ProfileDocument = .blank
    @State private var selectedID: UUID?
    /// Toggle that arms the canvas's "tap a chip to edit" mode. Driven
    /// by the floating Edit/Done capsule in the top-left of the canvas;
    /// turning it off automatically clears `selectedID` so the inspector
    /// drops back out of view when the user is done.
    @State private var editMode: Bool = false
    @State private var editingPageIndex: Int = 0
    @State private var pendingDeletePageIndex: Int?
    @State private var legacyDraft: Bool = false
    @State private var titleDraft: String = ""
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var sheets = CanvasSheetCoordinator()
    @State private var keyboardHeight: CGFloat = 0
    /// `true` while a text node on the canvas is in in-place editing
    /// (keyboard up, cursor in the box). Wired from the UIKit canvas's
    /// `onInlineTextEditingChanged`. Used to hide the bottom editor
    /// panel while the user is typing — the panel sits above the
    /// keyboard via `keyboardAwarePanelBottomPadding` and would
    /// otherwise cover the lifted text node.
    @State private var isInlineTextEditing: Bool = false
    /// Last non-collapsed UTF-16 selection reported by an actively edited
    /// text node. Cleared when node selection changes so a stale range never
    /// applies to a different element.
    @State private var selectedTextRangeByNodeID: [UUID: NSRange] = [:]
    @FocusState private var isTitleFieldFocused: Bool
    /// Snapshot stack for undo. Entries are full `ProfileDocument`
    /// snapshots taken just before a mutation; `performUndo` pops one
    /// and replaces the live document with it. The trailing snapshot
    /// equals the pre-mutation state, not the post-mutation one, so a
    /// single undo always reverses the user's most recent action.
    @State private var undoStack: [ProfileDocument] = []
    /// Counterpart redo stack. Pushed onto when the user undoes;
    /// cleared the moment a fresh mutation arrives so redo never
    /// resurrects state from a branch the user has moved past.
    @State private var redoStack: [ProfileDocument] = []
    /// Run-loop coalesce flag. CanvasMutator actions typically issue
    /// two or three sequential writes (insert + normalize + render
    /// rev bump) — without this guard each would land as its own
    /// undo entry and the user would have to tap Undo three times
    /// to reverse a single delete. Reset asynchronously so the next
    /// run-loop tick is treated as a new edit session.
    @State private var pendingCoalesce: Bool = false
    private let undoStackLimit = 60
    /// Height the bottom selection panel currently occupies. Driven
    /// by `EditorPanelHeightKey` so the canvas can pad its scroll
    /// inset to match and walk the selected node above the panel
    /// even as the panel reflows (HSV picker open/close, segmented
    /// tab switch, etc.).
    @State private var editorPanelHeight: CGFloat = 0
    // MARK: Reset Profile (full local + cloud wipe)
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    /// Set when the cloud half of `performReset()` failed (or was
    /// skipped because the user is signed out). Drives the secondary
    /// "Couldn't fully reset" alert; the local wipe still proceeded.
    @State private var resetErrorMessage: String?
    private let richTextToolbarReservedHeight: CGFloat = 58

    // MARK: Delete Published Profile (cloud-only wipe)
    @State private var showUnpublishConfirmation = false
    @State private var isUnpublishing = false
    @State private var unpublishErrorMessage: String?
    /// One `DraftStore` for the lifetime of this view. Initialized in
    /// `.onAppear` once the model context is available — never per
    /// property access (the previous computed-getter pattern allocated
    /// a fresh store on every read, including in hot paths like
    /// `body` and `.onChange`).
    @State private var store: DraftStore?

    /// Fallback wrapper that uses the cached store when present and
    /// builds a one-off otherwise. Reads-before-onAppear (rare) get the
    /// fallback; everything user-driven hits the cached instance.
    private var resolvedStore: DraftStore {
        store ?? DraftStore(context: context)
    }

    private var mutator: CanvasMutator {
        CanvasMutator(
            document: snapshottingDocumentBinding,
            selectedID: $selectedID,
            draft: draft,
            store: resolvedStore,
            context: context,
            rootPageIndex: editingPageIndex
        )
    }

    private var canUndo: Bool { !undoStack.isEmpty }
    private var canRedo: Bool { !redoStack.isEmpty }

    /// Push the current document onto the undo stack as a pre-mutation
    /// snapshot and clear redo (a fresh mutation invalidates any
    /// future-branch the user previously undid into). Skips the push
    /// when the head of the stack already matches `document`, which
    /// prevents duplicate entries when multiple capture sites all
    /// fire for the same logical edit (panel open + first slider tick,
    /// for instance).
    private func captureSnapshot() {
        if let last = undoStack.last, last == document { return }
        undoStack.append(document)
        if undoStack.count > undoStackLimit {
            undoStack.removeFirst(undoStack.count - undoStackLimit)
        }
        redoStack.removeAll()
    }

    /// Pop the most recent snapshot, push the current state onto redo,
    /// and replace the live document. Persists immediately via the
    /// draft store so the on-disk state stays in sync — we don't want
    /// undo to be a "ghost" that disappears next launch. Selection
    /// clears because the snapshot may not contain the currently
    /// selected node id.
    private func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(document)
        document = snapshot
        resolvedStore.updateDocument(draft, document: snapshot)
        selectedID = nil
        CucuHaptics.selection()
    }

    /// Inverse of `performUndo` — pop from redo, push current onto
    /// undo, replace document, persist, clear selection.
    private func performRedo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(document)
        document = snapshot
        resolvedStore.updateDocument(draft, document: snapshot)
        selectedID = nil
        CucuHaptics.selection()
    }

    /// Binding wrapper that captures an undo snapshot on first write
    /// per run-loop tick, then forwards subsequent same-tick writes
    /// to `document` without piling up extra entries. Drives every
    /// `CanvasMutator` mutation; canvas-gesture commits and panel-
    /// open snapshots use the explicit `captureSnapshot()` path
    /// because their writes are intentional one-shot replacements.
    private var snapshottingDocumentBinding: Binding<ProfileDocument> {
        Binding(
            get: { document },
            set: { newValue in
                guard newValue != document else { return }
                if !pendingCoalesce {
                    pendingCoalesce = true
                    captureSnapshot()
                    DispatchQueue.main.async {
                        pendingCoalesce = false
                    }
                }
                document = newValue
            }
        )
    }

    /// Where a new node will land if the user adds one right now. Mirrors
    /// the rule used inside `CanvasMutator.parentForInsertion`, so the
    /// AddNodeSheet's banner stays accurate.
    private var addDestination: AddNodeSheet.Destination {
        if StructuredProfileLayout.isStructured(document) {
            guard let sid = selectedID,
                  let node = document.nodes[sid],
                  !StructuredProfileLayout.isInSystemProfileSubtree(sid, in: document) else {
                return .structuredPage
            }
            if node.type == .carousel || carouselAncestor(containing: sid) != nil {
                return .carousel
            }
            if node.role == .sectionCard {
                return .sectionCard
            }
            if node.type == .container,
               StructuredProfileLayout.sectionCardAncestor(containing: sid, in: document) != nil {
                return .container
            }
            if StructuredProfileLayout.sectionCardAncestor(containing: sid, in: document) != nil {
                return .sectionCard
            }
            return .structuredPage
        }

        guard let sid = selectedID, let node = document.nodes[sid] else {
            return .page
        }
        switch node.type {
        case .container:
            if let parentID = document.parent(of: sid),
               document.nodes[parentID]?.type == .carousel {
                return .carousel
            }
            return .container
        case .carousel:  return .carousel
        default:
            return carouselAncestor(containing: sid) == nil ? .page : .carousel
        }
    }

    private func carouselAncestor(containing id: UUID) -> UUID? {
        var current: UUID? = id
        while let nodeID = current,
              let parentID = document.parent(of: nodeID) {
            if document.nodes[parentID]?.type == .carousel {
                return parentID
            }
            current = parentID
        }
        return nil
    }

    /// True when the canvas has zero nodes so the empty-state
    /// overlay should show. Both `rootChildrenIDs` and `nodes` get
    /// checked because a corrupt document could in theory have one
    /// without the other; an empty test that only checked one would
    /// leak through and hide the prompt.
    private var canvasIsEmpty: Bool {
        document.pages.allSatisfy { $0.rootChildrenIDs.isEmpty } && document.nodes.isEmpty
    }

    private var selectedCanDelete: Bool {
        guard let selectedID else { return false }
        return StructuredProfileLayout.canDelete(selectedID, in: document)
    }

    private var selectedCanDuplicate: Bool {
        guard let selectedID else { return false }
        return StructuredProfileLayout.canDuplicate(selectedID, in: document)
    }

    private var selectedCanReorder: Bool {
        guard let selectedID else { return false }
        return StructuredProfileLayout.canReorder(selectedID, in: document)
    }

    var body: some View {
        @Bindable var sheets = sheets

        ZStack {
            if legacyDraft {
                legacyView
            } else {
                CanvasEditorContainer(
                    document: $document,
                    selectedID: $selectedID,
                    onCommit: { doc in
                        var normalized = doc
                        StructuredProfileLayout.normalize(&normalized)
                        // Drag / resize / in-place text commits arrive
                        // here. Capture before the assignment so undo
                        // returns to the pre-gesture state, not a
                        // halfway-committed copy.
                        if normalized != document {
                            captureSnapshot()
                        }
                        document = normalized
                        resolvedStore.updateDocument(draft, document: normalized)
                    },
                    onAddPage: { appendPage() },
                    onDeletePageRequested: { index in
                        guard index > 0, document.pages.indices.contains(index), document.pages.count > 1 else { return }
                        editingPageIndex = index
                        pendingDeletePageIndex = index
                    },
                    onEditingPageChanged: { index in
                        editingPageIndex = index
                    },
                    editMode: editMode,
                    bottomChromeHeight: canvasBottomReservedHeight,
                    onRequestExitEditMode: {
                        // Two-tap-out pattern: first empty-canvas tap
                        // clears the selection, second one drops out
                        // of edit mode. Animation matches the entry
                        // toggle so the inset glow / chips fade out
                        // on the same curve they appeared on.
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            editMode = false
                            selectedID = nil
                        }
                    },
                    onInlineTextEditingChanged: { editing in
                        // Match the panel's spring so the hide / show
                        // tracks the same curve the keyboard rides on.
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            isInlineTextEditing = editing
                        }
                    },
                    onLiveTextChanged: { nodeID, text in
                        guard var node = document.nodes[nodeID],
                              node.type == .text else { return }
                        let oldText = node.content.text ?? ""
                        guard oldText != text else { return }
                        node.content.text = text
                        reconcileTextStyleSpans(afterTextChangeFrom: oldText, to: text, in: &node)
                        document.nodes[nodeID] = node
                    },
                    onTextSelectionRangeChanged: { nodeID, range in
                        guard selectedID == nodeID,
                              document.nodes[nodeID]?.type == .text,
                              let range,
                              range.length > 0 else {
                            selectedTextRangeByNodeID.removeValue(forKey: nodeID)
                            return
                        }
                        selectedTextRangeByNodeID = [nodeID: range]
                    }
                )
                .overlay(alignment: .topLeading) {
                    Group {
                        if editMode {
                            editModeLeftChrome
                        } else {
                            EditCanvasToggleButton(editMode: editMode) {
                                toggleEditMode()
                            }
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.top, 12)
                    .allowsHitTesting(!canvasIsEmpty)
                    .opacity(canvasIsEmpty ? 0 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    Group {
                        if editMode {
                            editModeDoneButton
                        } else {
                            CanvasModeStatusLabel(editMode: editMode)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 14)
                    .opacity(canvasIsEmpty ? 0 : 1)
                }
                .overlay(alignment: .top) {
                    // Title chip lives on the canvas instead of in
                    // the navigation bar so it sits in the same plane
                    // as the Edit / Editing chrome. The chevron suffix
                    // hints at the rename affordance — tap anywhere
                    // on the chip to focus the field.
                    canvasTitleOverlay
                        .padding(.top, 10)
                }

                // Empty-state overlay — fades on top of the (empty)
                // canvas, fades out the moment the user adds the
                // first node. Wrapped in `.allowsHitTesting` so taps
                // on the CTAs land here, not on the canvas surface
                // behind. Hit-testing flips to false once content
                // exists, so the overlay never blocks edits.
                if canvasIsEmpty {
                    CanvasEmptyStateView(
                        onAddElement: { sheets.showAddSheet = true },
                        onUseTemplate: { sheets.showApplyTemplateSheet = true },
                        onPreview: { sheets.showPreview = true }
                    )
                    .equatable()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
                }
            }
        }
        .animation(.easeOut(duration: 0.32), value: canvasIsEmpty)
        .overlay(alignment: .bottom) {
            if let target = activeRichTextSelection {
                richTextSelectionToolbar(nodeID: target.nodeID, range: target.range)
                    .padding(.horizontal, 12)
                    .padding(.bottom, keyboardAwarePanelBottomPadding)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // While a text node is in in-place editing the keyboard
            // is up and we lift just that text node above it (see
            // `keyboardWillChangeFrame` in `CanvasEditorView`). The
            // bottom panel also rides above the keyboard via
            // `keyboardAwarePanelBottomPadding`, which puts it right
            // on top of the lifted text node. Drop the panel for the
            // duration of the edit; it returns the moment the
            // keyboard dismisses.
            if !legacyDraft, !isInlineTextEditing, let id = selectedID, document.nodes[id] != nil {
                if StructuredProfileLayout.isStructured(document) {
                    structuredNodePanel(for: id, sheets: sheets)
                        .id(id)
                        .padding(.bottom, keyboardAwarePanelBottomPadding)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    // Legacy/freeform documents keep the previous
                    // selection surface exactly so old drafts retain
                    // their freeform editing behavior.
                    if sheets.isSelectionBarExpanded {
                        SelectionBottomBar(
                            document: document,
                            selectedID: id,
                            onSelect: { newID in selectedID = newID },
                            onEdit: { sheets.showInspector = true },
                            onDuplicate: { mutator.duplicateSelected() },
                            onBringToFront: { mutator.bringSelectedToFront() },
                            onSendBackward: { mutator.sendSelectedBackward() },
                            onLayers: { sheets.showLayersSheet = true },
                            onDelete: { mutator.deleteSelected() },
                            onCollapse: { sheets.isSelectionBarExpanded = false }
                        )
                        .equatable()
                    } else {
                        CollapsedSelectionBar(
                            document: document,
                            selectedID: id,
                            onExpand: { sheets.isSelectionBarExpanded = true },
                            onEdit: { sheets.showInspector = true },
                            onDuplicate: { mutator.duplicateSelected() },
                            onBringToFront: { mutator.bringSelectedToFront() },
                            onSendBackward: { mutator.sendSelectedBackward() },
                            onLayers: { sheets.showLayersSheet = true },
                            onDelete: { mutator.deleteSelected() }
                        )
                        .equatable()
                    }
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
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: sheets.isSelectionBarExpanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: editMode)
        .onChange(of: selectedID) { oldID, newID in
            // Capture once when the inspector is about to open. The
            // panel writes to `document` continuously while it's up
            // (slider drags, color edits, text input), so without a
            // pre-open snapshot every keystroke would have to push
            // its own undo entry. The snapshot here is the single
            // pre-edit state; one Undo tap reverts the whole panel
            // session.
            if oldID == nil && newID != nil {
                captureSnapshot()
            }
            sheets.handleSelectionChanged(newID: newID)
            // Reset measured panel height when nothing is selected so
            // the canvas's reserved chrome collapses immediately
            // instead of hanging on to last-selection's value.
            if newID == nil {
                editorPanelHeight = 0
            }
            if let oldID, oldID != newID {
                selectedTextRangeByNodeID.removeValue(forKey: oldID)
            }
            guard let newID,
                  document.nodes[newID]?.type == .text else {
                selectedTextRangeByNodeID.removeAll()
                return
            }
            selectedTextRangeByNodeID = selectedTextRangeByNodeID[newID].map { [newID: $0] } ?? [:]
        }
        .onPreferenceChange(EditorPanelHeightKey.self) { newValue in
            // The panel is only mounted while a selection exists, so a
            // zero value here means "no panel right now" — keep zero
            // and let the next selection re-publish.
            if abs(editorPanelHeight - newValue) > 0.5 {
                editorPanelHeight = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardHeight(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                keyboardHeight = 0
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(sheets: sheets) }
        // Edge-to-edge: tint the toolbar to the focused page's bg
        // colour so the status-bar / toolbar strip blends straight
        // into the page below it. No seam between the chrome and the
        // canvas; the editor reads as one continuous surface like the
        // published profile does. `.toolbarColorScheme` adapts the
        // toolbar buttons + title for legibility on dark page bgs
        // (e.g. Dusk Diary) — light icons on dark, dark on light.
        .toolbarBackground(focusedPageBackgroundColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(focusedPageIsDark ? .dark : .light, for: .navigationBar)
        .modifier(CanvasBuilderSheetsModifier(
            document: $document,
            selectedID: $selectedID,
            selectedTextRangeByNodeID: selectedTextRangeByNodeID,
            draft: draft,
            sheets: sheets,
            mutator: mutator,
            addDestination: addDestination,
            isStructured: StructuredProfileLayout.isStructured(document),
            editingPageIndex: editingPageIndex,
            onSaveTemplate: { name in mutator.saveTemplate(named: name) },
            onApplyTemplate: { template in
                mutator.applyTemplate(template) {
                    legacyDraft = false
                    sheets.handleTemplateApplied()
                }
            }
        ))
        .navigationDestination(item: $sheets.publishedViewerUsername) { username in
            PublishedProfileView(username: username)
        }
        .alert("Reset profile?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                Task { await performReset() }
            }
        } message: {
            Text(resetConfirmationMessage)
        }
        // Secondary alert for the partial-failure case — the local
        // wipe always finishes, but the cloud half can fail (signed
        // out, network blip). Bound through a derived `Bool` so the
        // optional `resetErrorMessage` doubles as the "alert open"
        // signal.
        .alert(
            "Couldn't fully reset",
            isPresented: Binding(
                get: { resetErrorMessage != nil },
                set: { if !$0 { resetErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { resetErrorMessage = nil }
        } message: {
            Text(resetErrorMessage ?? "")
        }
        .alert("Delete published profile?", isPresented: $showUnpublishConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task { await performUnpublish() }
            }
        } message: {
            Text(unpublishConfirmationMessage)
        }
        .alert(
            "Couldn't delete published profile",
            isPresented: Binding(
                get: { unpublishErrorMessage != nil },
                set: { if !$0 { unpublishErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { unpublishErrorMessage = nil }
        } message: {
            Text(unpublishErrorMessage ?? "")
        }
        .alert(
            deletePageAlertTitle,
            isPresented: Binding(
                get: { pendingDeletePageIndex != nil },
                set: { if !$0 { pendingDeletePageIndex = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDeletePageIndex = nil }
            Button("Delete Page", role: .destructive) {
                if let index = pendingDeletePageIndex {
                    deletePage(at: index)
                }
                pendingDeletePageIndex = nil
            }
        } message: {
            Text(deletePageAlertMessage)
        }
        .onAppear {
            // Cache the draft store once for the lifetime of this view.
            // The model context isn't available at init time, so this is
            // the earliest point where we can resolve it.
            if store == nil {
                store = DraftStore(context: context)
            }
            loadDraft()
        }
        .onDisappear {
            flushTitleSave()
        }
    }

    private var keyboardAwarePanelBottomPadding: CGFloat {
        keyboardHeight > 0 ? keyboardHeight + 8 : 8
    }

    private var activeRichTextSelection: (nodeID: UUID, range: NSRange)? {
        guard isInlineTextEditing,
              let selectedID,
              let node = document.nodes[selectedID],
              node.type == .text,
              let selection = selectedTextRangeByNodeID[selectedID],
              selection.length > 0 else {
            return nil
        }
        let range = normalizedRange(selection: selection, text: node.content.text ?? "")
        guard range.length > 0 else { return nil }
        return (selectedID, range)
    }

    /// Left-side chrome row shown in edit mode in place of the
    /// EditCanvasToggleButton: × close + undo + redo, in plain icon
    /// form (no capsule). The × shares a destination with the Done
    /// button on the trailing edge — both flip `editMode` off and
    /// clear `selectedID` — so users have an exit affordance on
    /// either side of the title pill.
    @ViewBuilder
    private var editModeLeftChrome: some View {
        let compact = horizontalSizeClass == .compact
        let iconSize: CGFloat = compact ? 16 : 19
        let frameSide: CGFloat = compact ? 26 : 30
        let rowSpacing: CGFloat = compact ? 8 : 18
        HStack(spacing: rowSpacing) {
            Button {
                toggleEditMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: frameSide, height: frameSide)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit edit mode")

            Button {
                performUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundStyle(Color.cucuInk.opacity(canUndo ? 1 : 0.28))
                    .frame(width: frameSide, height: frameSide)
            }
            .buttonStyle(.plain)
            .disabled(!canUndo)
            .accessibilityLabel("Undo")

            Button {
                performRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundStyle(Color.cucuInk.opacity(canRedo ? 1 : 0.28))
                    .frame(width: frameSide, height: frameSide)
            }
            .buttonStyle(.plain)
            .disabled(!canRedo)
            .accessibilityLabel("Redo")
        }
    }

    /// Trailing "Done" button shown in edit mode in place of the
    /// Live/Editing status label. Bare text — matches the reference
    /// where Done sits as a single airy word rather than a chip.
    private var editModeDoneButton: some View {
        Button {
            toggleEditMode()
        } label: {
            Text("Done")
                .font(.cucuSans(17, weight: .medium))
                .foregroundStyle(Color.cucuInk)
                .frame(height: 30)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done editing")
    }

    /// Centered title pill that sits at the top of the canvas
    /// between the Edit toggle (top-left) and the Editing/Live
    /// status label (top-right). The text field stays editable in
    /// place — same `titleDraft` binding the navigation bar used to
    /// own — and the trailing chevron is a visual cue, not a menu
    /// trigger (rename is the only affordance the title currently
    /// surfaces).
    @ViewBuilder
    private var canvasTitleOverlay: some View {
        if !canvasIsEmpty && !legacyDraft {
            HStack(spacing: 5) {
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.cucuSans(17, weight: .medium))
                    .foregroundStyle(Color.cucuInk)
                    .focused($isTitleFieldFocused)
                    .submitLabel(.done)
                    .frame(minWidth: 60, maxWidth: 220)
                    .fixedSize(horizontal: true, vertical: false)
                    .onChange(of: titleDraft) { _, newValue in
                        scheduleTitleSave(newValue)
                    }
                    .onSubmit {
                        flushTitleSave()
                        isTitleFieldFocused = false
                    }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.cucuInk.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            // Reference uses bare text directly on the canvas — but our
            // canvas can ship any image / dark theme behind the title,
            // so we keep a near-invisible card backing that only
            // becomes visible while the user is editing. Idle: pure
            // text. Focused: thin pill so the field reads as "armed".
            .background(
                Capsule(style: .continuous)
                    .fill(Color.cucuCard.opacity(isTitleFieldFocused ? 0.95 : 0.0))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.cucuInk.opacity(isTitleFieldFocused ? 0.40 : 0.0),
                            lineWidth: isTitleFieldFocused ? 1.5 : 0)
            )
            .animation(.easeInOut(duration: 0.18), value: isTitleFieldFocused)
            .contentShape(Capsule(style: .continuous))
            .onTapGesture {
                isTitleFieldFocused = true
            }
        }
    }

    /// Bottom area the canvas should treat as covered chrome. When a
    /// selection panel is up, this is its measured height plus the
    /// keyboard-aware padding the panel itself adds; when nothing is
    /// selected, the chrome height is zero so the canvas reverts to a
    /// full-height scroll surface. Threaded into `CanvasEditorView`'s
    /// scroll inset so the selected node always lands above the panel.
    /// During in-place text editing the panel is hidden and the
    /// canvas's keyboard avoidance lifts just the editing node — so
    /// we report zero here too, otherwise the scroll inset would
    /// reserve space for an invisible panel.
    private var canvasBottomReservedHeight: CGFloat {
        if activeRichTextSelection != nil {
            return richTextToolbarReservedHeight
        }
        guard selectedID != nil, editorPanelHeight > 0, !isInlineTextEditing else { return 0 }
        return editorPanelHeight + keyboardAwarePanelBottomPadding
    }

    private func updateKeyboardHeight(from notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let visibleHeight = max(0, UIScreen.main.bounds.height - frame.minY)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            keyboardHeight = visibleHeight
        }
    }

    /// Flips the canvas's edit mode and keeps the inspector state
    /// consistent: leaving edit mode always closes the per-node panel
    /// (matches the JSX prototype's "Done → clear selectedID" rule),
    /// while entering edit mode preserves any active selection so the
    /// inspector survives the morph.
    private func toggleEditMode() {
        let next = !editMode
        CucuHaptics.selection()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            editMode = next
            if !next {
                selectedID = nil
            }
        }
    }

    /// Extracts the structured profile's bottom inspector panel
    /// builder so the parent `body` doesn't have to type-check a
    /// dozen inline closures simultaneously — without this split,
    /// SwiftUI's compiler hits its "unable to type-check in
    /// reasonable time" cap on the body expression.
    @ViewBuilder
    private func structuredNodePanel(for id: UUID,
                                     sheets: CanvasSheetCoordinator) -> some View {
        NodeEditingPanelView(
            document: $document,
            selectedID: id,
            selectedTextRange: selectedTextRangeByNodeID[id],
            onCommit: commitPanelDocument,
            onAddElement: { sheets.showAddSheet = true },
            onOpenInspector: { sheets.showInspector = true },
            onDuplicate: { mutator.duplicateSelected() },
            onLayers: { sheets.showLayersSheet = true },
            onDelete: { mutator.deleteSelected() },
            onSetContainerBackground: { nodeID, data in
                mutator.setContainerBackgroundImage(for: nodeID, with: data)
            },
            onClearContainerBackground: { nodeID in
                mutator.clearContainerBackgroundImage(for: nodeID)
            },
            onEditContainerBackground: { nodeID in
                sheets.requestEditContainerEffects(for: nodeID)
            },
            onReplaceImage: { nodeID, data in
                mutator.replaceImage(for: nodeID, with: data)
            },
            onMoveUp: { mutator.moveSelectedUp() },
            onMoveDown: { mutator.moveSelectedDown() },
            canMoveUp: { mutator.canMoveSelectedUp() },
            canMoveDown: { mutator.canMoveSelectedDown() },
            onAppendGalleryPhotos: { nodeID, dataList in
                mutator.appendGalleryImages(for: nodeID, with: dataList)
            },
            onClose: {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    selectedID = nil
                }
            }
        )
    }

    private func richTextSelectionToolbar(nodeID: UUID, range: NSRange) -> some View {
        RichTextSelectionToolbar(
            textColorHex: richTextColorBinding(nodeID: nodeID, range: range),
            highlightColorHex: richTextHighlightBinding(nodeID: nodeID, range: range),
            boldActive: inlineBoolActive(nodeID: nodeID, range: range, reader: inlineBold),
            italicActive: inlineBoolActive(nodeID: nodeID, range: range, reader: inlineItalic),
            underlineActive: inlineBoolActive(nodeID: nodeID, range: range, reader: inlineUnderline),
            onBold: {
                mutateRichTextSpan(nodeID: nodeID, range: range) { node, normalized in
                    applyBold(range: normalized, to: &node)
                }
            },
            onItalic: {
                mutateRichTextSpan(nodeID: nodeID, range: range) { node, normalized in
                    applyItalic(range: normalized, to: &node)
                }
            },
            onUnderline: {
                mutateRichTextSpan(nodeID: nodeID, range: range) { node, normalized in
                    applyUnderline(range: normalized, to: &node)
                }
            },
            onClearStyle: {
                mutateRichTextSpan(nodeID: nodeID, range: range) { node, normalized in
                    clearInlineStyles(range: normalized, from: &node)
                }
            }
        )
    }

    private func richTextColorBinding(nodeID: UUID, range: NSRange) -> Binding<String> {
        Binding(
            get: {
                guard let node = document.nodes[nodeID] else { return "#1A140E" }
                let normalized = normalizedRange(selection: range, text: node.content.text ?? "")
                return inlineTextColorHex(in: node, range: normalized)
                    ?? node.style.textColorHex
                    ?? "#1A140E"
            },
            set: { newValue in
                mutateRichTextSpan(nodeID: nodeID, range: range) { node, normalized in
                    applyTextColor(hex: newValue, range: normalized, to: &node)
                }
            }
        )
    }

    private func richTextHighlightBinding(nodeID: UUID, range: NSRange) -> Binding<String> {
        Binding(
            get: {
                guard let node = document.nodes[nodeID] else { return "#DDF1D5" }
                let normalized = normalizedRange(selection: range, text: node.content.text ?? "")
                return inlineHighlightHex(in: node, range: normalized) ?? "#DDF1D5"
            },
            set: { newValue in
                mutateRichTextSpan(nodeID: nodeID, range: range) { node, normalized in
                    applyHighlight(hex: newValue, range: normalized, to: &node)
                }
            }
        )
    }

    private func inlineBoolActive(nodeID: UUID,
                                  range: NSRange,
                                  reader: (CanvasNode, NSRange) -> Bool?) -> Bool {
        guard let node = document.nodes[nodeID] else { return false }
        let normalized = normalizedRange(selection: range, text: node.content.text ?? "")
        return reader(node, normalized) == true
    }

    private func mutateRichTextSpan(nodeID: UUID,
                                    range: NSRange,
                                    update: (inout CanvasNode, NSRange) -> Void) {
        guard var node = document.nodes[nodeID], node.type == .text else { return }
        let normalized = normalizedRange(selection: range, text: node.content.text ?? "")
        guard normalized.length > 0 else { return }
        update(&node, normalized)
        document.nodes[nodeID] = node
        selectedTextRangeByNodeID = [nodeID: normalized]
    }

    private func commitPanelDocument(_ doc: ProfileDocument) {
        var normalized = doc
        StructuredProfileLayout.normalize(&normalized)
        document = normalized
        resolvedStore.updateDocument(draft, document: normalized)
    }

    @ToolbarContentBuilder
    private func toolbarContent(sheets: CanvasSheetCoordinator) -> some ToolbarContent {
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

        // Title moved out of the navigation bar onto the canvas
        // surface (see `canvasTitleOverlay`) so it sits as part of
        // the editing chrome instead of fighting for room with the
        // five trailing buttons. Principal slot is intentionally left
        // empty — iOS centers the title there by default, and an
        // empty principal lets the trailing group claim the freed
        // width on small iPhones.
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
            Button { sheets.showAddSheet = true } label: {
                Image(systemName: "plus.square")
            }
            .disabled(legacyDraft)
            .accessibilityLabel("Add Element")

            Button { sheets.showPreview = true } label: {
                Image(systemName: "eye")
            }
            .disabled(legacyDraft || canvasIsEmpty)
            .accessibilityLabel("Preview")

            Button { sheets.showPublishSheet = true } label: {
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
                    sheets.showPageBackgroundSheet = true
                }
                if canDeleteEditingPage {
                    Button("Delete Page \(editingPageIndex + 1)…",
                           systemImage: "trash",
                           role: .destructive) {
                        pendingDeletePageIndex = editingPageIndex
                    }
                }
                Button("Layers", systemImage: "square.3.layers.3d") { sheets.showLayersSheet = true }
                Divider()
                Button("Duplicate", systemImage: "plus.square.on.square") { mutator.duplicateSelected() }
                    .disabled(!selectedCanDuplicate)
                Button("Bring to Front", systemImage: "square.stack.3d.up") { mutator.bringSelectedToFront() }
                    .disabled(!selectedCanReorder)
                Button("Send Backward", systemImage: "square.stack.3d.down.right") { mutator.sendSelectedBackward() }
                    .disabled(!selectedCanReorder)
                Button("Edit Properties…", systemImage: "slider.horizontal.3") { sheets.showInspector = true }
                    .disabled(selectedID == nil)
                Divider()
                Button("Save as Template", systemImage: "square.and.arrow.down") {
                    sheets.showSaveTemplateSheet = true
                }
                Button("Apply Template", systemImage: "square.on.square") {
                    sheets.showApplyTemplateSheet = true
                }
                Button("Theme…", systemImage: "paintpalette") {
                    sheets.showThemePickerSheet = true
                }
                Divider()
                if let published = draft.publishedUsername, !published.isEmpty {
                    Button("View Published", systemImage: "eye") {
                        sheets.publishedViewerUsername = published
                    }
                    // Cloud-only delete is gated on a signed-in
                    // session — the wipe authenticates against
                    // Supabase, so showing the action without an
                    // account would just lead to a confusing error.
                    if auth.currentUser != nil {
                        Button("Delete Published Profile…",
                               systemImage: "xmark.icloud",
                               role: .destructive) {
                            showUnpublishConfirmation = true
                        }
                        .disabled(isUnpublishing)
                    }
                }
                Button("Open Profile by Username", systemImage: "person.crop.circle.badge.questionmark") {
                    sheets.showOpenProfileSheet = true
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { mutator.deleteSelected() }
                    .disabled(!selectedCanDelete)
                Divider()
                // Full reset — local canvas + (when signed in and
                // published) the cloud copy. Always available so an
                // unpublished draft can still wipe its in-memory
                // state without first signing in.
                Button("Reset Profile…",
                       systemImage: "arrow.counterclockwise.circle",
                       role: .destructive) {
                    showResetConfirmation = true
                }
                .disabled(isResetting)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(legacyDraft)
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
            Text("Starting fresh will replace its contents with a structured profile page. The current data will be overwritten only after you confirm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Start fresh canvas") {
                document = .structuredProfileBlank
                editingPageIndex = 0
                legacyDraft = false
                resolvedStore.updateDocument(draft, document: document)
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
            var loaded = doc
            if StructuredProfileLayout.isEmptyCanvas(loaded) {
                loaded = .structuredProfileBlank
                resolvedStore.updateDocument(draft, document: loaded)
            } else {
                let original = loaded
                StructuredProfileLayout.normalize(&loaded)
                if loaded != original {
                    resolvedStore.updateDocument(draft, document: loaded)
                }
            }
            document = loaded
            editingPageIndex = 0
            legacyDraft = false
        case .legacy:
            // Don't overwrite. Show banner; user opts in to blank canvas.
            legacyDraft = true
        case .empty:
            // Brand-new or wiped — seed a structured profile doc and persist
            // so subsequent launches go straight to .document.
            document = .structuredProfileBlank
            editingPageIndex = 0
            legacyDraft = false
            resolvedStore.updateDocument(draft, document: document)
        }
    }

    private func persistedTitle(from value: String) -> String {
        value.isEmpty ? "Untitled" : value
    }

    private func scheduleTitleSave(_ value: String) {
        titleSaveTask?.cancel()
        let store = resolvedStore
        let draft = draft
        let title = persistedTitle(from: value)
        titleSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            store.updateTitle(draft, title: title)
        }
    }

    private func flushTitleSave() {
        titleSaveTask?.cancel()
        titleSaveTask = nil
        resolvedStore.updateTitle(draft, title: persistedTitle(from: titleDraft))
    }

    // MARK: - Pages

    private var canDeleteEditingPage: Bool {
        // Page 1 is the durable landing page for old viewers and cannot be
        // deleted. Later pages can be removed when more than one page exists.
        document.pages.count > 1 && editingPageIndex > 0
    }

    /// Hex of the currently-focused page's background. Falls back to
    /// the document's legacy `pageBackgroundHex` when the editing
    /// index isn't a valid page (transient state during page deletion
    /// / template swap). Drives the toolbar tint so the editor chrome
    /// reads as part of the page rather than a system bar floating
    /// above it.
    private var focusedPageBackgroundHex: String {
        let pages = document.pages
        let index = max(0, min(editingPageIndex, pages.count - 1))
        guard pages.indices.contains(index) else { return document.pageBackgroundHex }
        return pages[index].backgroundHex
    }

    /// Toolbar fill colour, derived from the focused page bg.
    private var focusedPageBackgroundColor: Color {
        Color(hex: focusedPageBackgroundHex)
    }

    /// True when the focused page has a low-luminance background
    /// (e.g. the Dusk Diary theme). The toolbar flips to dark mode
    /// in that case so its title + buttons + status-bar glyphs read
    /// as light-on-dark instead of disappearing into the chrome.
    /// Same Rec. 709 luminance check as `ThemePickerSheet.isDark`.
    private var focusedPageIsDark: Bool {
        let trimmed = focusedPageBackgroundHex.hasPrefix("#")
            ? String(focusedPageBackgroundHex.dropFirst())
            : focusedPageBackgroundHex
        guard trimmed.count == 6 || trimmed.count == 8,
              let value = UInt32(trimmed.prefix(6), radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum < 0.5
    }

    private func appendPage() {
        document.appendPage(inheritingFrom: document.pages.count - 1)
        editingPageIndex = max(0, document.pages.count - 1)
        resolvedStore.updateDocument(draft, document: document)
        try? context.save()
        CucuHaptics.success()
    }

    private func deletePage(at index: Int) {
        guard document.pages.indices.contains(index), index > 0, document.pages.count > 1 else { return }
        let removedIDs = Set(document.pages[index].rootChildrenIDs.flatMap { document.subtree(rootedAt: $0) })
        var removedAssetPaths = document.pages[index].rootChildrenIDs.reduce(into: Set<String>()) { paths, rootID in
            paths.formUnion(CanvasMutator.assetPaths(inSubtreeRootedAt: rootID, document: document))
        }
        if let backgroundPath = document.pages[index].backgroundImagePath, !backgroundPath.isEmpty {
            removedAssetPaths.insert(backgroundPath)
        }
        document.removePage(at: index)
        for path in removedAssetPaths where !CanvasMutator.assetPathIsReferenced(path, in: document) {
            LocalCanvasAssetStore.delete(relativePath: path)
        }
        if let selectedID, removedIDs.contains(selectedID) {
            self.selectedID = nil
        }
        editingPageIndex = min(editingPageIndex, max(0, document.pages.count - 1))
        resolvedStore.updateDocument(draft, document: document)
        try? context.save()
        CucuHaptics.delete()
    }

    private var deletePageAlertTitle: String {
        guard let index = pendingDeletePageIndex else { return "Delete page?" }
        return "Delete page \(index + 1)?"
    }

    private var deletePageAlertMessage: String {
        guard let index = pendingDeletePageIndex,
              document.pages.indices.contains(index) else {
            return "This can't be undone."
        }
        let count = Set(document.pages[index].rootChildrenIDs.flatMap { document.subtree(rootedAt: $0) }).count
        if count == 0 {
            return "This blank page will be removed. This can't be undone."
        }
        return "Delete page \(index + 1) and its \(count) node\(count == 1 ? "" : "s")? This can't be undone."
    }

    // MARK: - Reset / Unpublish

    /// Confirmation copy for the destructive Reset action. Branches on
    /// whether the draft was ever published — the published case warns
    /// about the cloud wipe in addition to the local one.
    private var resetConfirmationMessage: String {
        if draft.publishedProfileId != nil {
            return "Local reset: remove every node and image on this draft. Cloud delete: take down your published profile and delete uploaded images if you're signed in. This can't be undone."
        }
        return "Local reset only: remove every node and image on this draft. No published profile is connected to this draft. This can't be undone."
    }

    /// Confirmation copy for the cloud-only Delete Published Profile
    /// action. Names the username when available so the user knows
    /// exactly which profile is being removed; always reassures them
    /// that the local canvas is untouched.
    private var unpublishConfirmationMessage: String {
        let target: String
        if let username = draft.publishedUsername, !username.isEmpty {
            target = "@\(username)"
        } else {
            target = "your published profile"
        }
        return "This will remove \(target) and every image you've uploaded for it from the cloud. Your local canvas, images, and title stay intact."
    }

    /// Full reset: cloud (best-effort) + local. The local wipe always
    /// runs regardless of the cloud outcome, because the user clicked
    /// Reset and the in-memory state should reflect that. The cloud
    /// failure is surfaced as a secondary alert and `publishedProfileId`
    /// stays set so a retry knows what to wipe.
    private func performReset() async {
        isResetting = true
        defer { isResetting = false }

        var cloudWipeSucceeded = true
        var partialError: String?

        // 1. Cloud half — only attempted when the draft was ever
        //    published. Signed-out users get a clean message rather
        //    than a silent skip; the published_id is preserved so
        //    they can sign in and Reset again.
        if let publishedId = draft.publishedProfileId, !publishedId.isEmpty {
            if let user = auth.currentUser {
                do {
                    try await ProfileResetService(user: user, profileId: publishedId).wipe()
                } catch let err as ProfileResetError {
                    cloudWipeSucceeded = false
                    partialError = err.errorDescription
                } catch {
                    cloudWipeSucceeded = false
                    partialError = error.localizedDescription
                }
            } else {
                cloudWipeSucceeded = false
                partialError = "Local data was reset, but you'll need to sign in and Reset again to remove your published profile from the cloud."
            }
        }

        // 2. Local half — runs unconditionally so the canvas always
        //    reflects the user's choice. Asset folder + in-memory
        //    document + every transient view-state flag.
        LocalCanvasAssetStore.deleteDraftAssets(draftID: draft.id)
        document = .structuredProfileBlank
        selectedID = nil
        editingPageIndex = 0
        legacyDraft = false
        sheets.showInspector = false
        sheets.showLayersSheet = false
        sheets.isSelectionBarExpanded = false
        titleDraft = "Untitled"

        // 3. Persist the draft mutations. Title always resets;
        //    published-* fields only clear on cloud success so a
        //    retry after a failed cloud wipe still knows what to
        //    delete.
        draft.title = "Untitled"
        if cloudWipeSucceeded {
            draft.publishedProfileId = nil
            draft.publishedUsername = nil
            draft.lastPublishedAt = nil
        }
        draft.updatedAt = .now

        // `updateDocument` short-circuits when the encoded JSON is
        // unchanged (a blank-on-blank reset hits this). The catch-all
        // `try? context.save()` makes sure the title / published-id
        // mutations above land regardless.
        resolvedStore.updateDocument(draft, document: document)
        try? context.save()

        CucuHaptics.delete()

        if let partialError {
            resetErrorMessage = partialError
        }
    }

    /// Cloud-only delete: removes the published profile + uploaded
    /// images, leaves the local canvas / images / title intact. On
    /// failure the local state is untouched so the user can retry
    /// without re-staging anything.
    private func performUnpublish() async {
        guard let publishedId = draft.publishedProfileId, !publishedId.isEmpty,
              let user = auth.currentUser else {
            unpublishErrorMessage = "You need to be signed in with the account that published this profile."
            return
        }

        isUnpublishing = true
        defer { isUnpublishing = false }

        do {
            try await ProfileResetService(user: user, profileId: publishedId).wipe()
        } catch let err as ProfileResetError {
            unpublishErrorMessage = err.errorDescription
            return
        } catch {
            unpublishErrorMessage = error.localizedDescription
            return
        }

        // Success only — local document and assets stay untouched on
        // purpose. Just clear the publish-side bookkeeping so the
        // toolbar reverts and a future Publish writes a fresh row.
        draft.publishedProfileId = nil
        draft.publishedUsername = nil
        draft.lastPublishedAt = nil
        draft.updatedAt = .now
        try? context.save()

        CucuHaptics.delete()
    }
}

private struct RichTextSelectionToolbar: View {
    @Binding var textColorHex: String
    @Binding var highlightColorHex: String

    let boldActive: Bool
    let italicActive: Bool
    let underlineActive: Bool
    let onBold: () -> Void
    let onItalic: () -> Void
    let onUnderline: () -> Void
    let onClearStyle: () -> Void

    /// Drives the popover that hosts the highlight palette. State kept
    /// on the toolbar (not lifted) because the popover is a transient
    /// presentation owned by the picker control itself.
    @State private var showingHighlightPalette: Bool = false
    /// Drives the standalone sheet that hosts the system color picker.
    /// Kept separate from `showingHighlightPalette` (and presented from
    /// the toolbar's `.sheet` rather than from inside the popover) so
    /// the system picker isn't nested under the popover — that nesting
    /// is what produced the flicker on exit, since SwiftUI re-renders
    /// popover contents during dismissal and the embedded `ColorPicker`
    /// would briefly re-trigger its UIKit presentation.
    @State private var showingCustomColorPicker: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                colorControl(
                    title: "Text Color",
                    systemImage: "textformat",
                    hex: $textColorHex,
                    supportsAlpha: false
                )
                highlightPaletteControl
                toolbarButton(title: "Bold", active: boldActive, action: onBold) {
                    Text("B")
                        .font(.system(size: 14, weight: .heavy))
                }
                toolbarButton(title: "Italic", active: italicActive, action: onItalic) {
                    Text("I")
                        .font(.custom("Georgia-Italic", size: 14))
                        .italic()
                }
                toolbarButton(title: "Underline", active: underlineActive, action: onUnderline) {
                    Text("U")
                        .font(.system(size: 14, weight: .semibold))
                        .underline()
                }
                toolbarButton(title: "Clear Style", active: false, action: onClearStyle) {
                    Image(systemName: "eraser")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .scrollClipDisabled()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cucuCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.cucuInkRule, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
        .sheet(isPresented: $showingCustomColorPicker) {
            SystemColorPickerSheet(
                hex: $highlightColorHex,
                isPresented: $showingCustomColorPicker,
                supportsAlpha: true
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    /// Pencil.tip button mirroring the `colorControl` chrome but
    /// hosting the grayscale palette inside its popover instead of
    /// deferring to UIKit's `UIColorPickerViewController`. The palette
    /// itself shares hexes with `TextInspectorV2.grayscaleHighlightHexes`
    /// so both inspectors stay in sync. `presentationCompactAdaptation`
    /// forces a real popover on iPhone — without it, iOS would fall
    /// back to a sheet, which would push the keyboard down and break
    /// the in-flight selection.
    private var highlightPaletteControl: some View {
        Button {
            showingHighlightPalette.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 13, weight: .semibold))
                Circle()
                    .fill(Color(hex: highlightColorHex))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.cucuInk.opacity(0.25), lineWidth: 0.5))
            }
            .foregroundStyle(Color.cucuInk)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.cucuInk.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Highlight")
        .popover(isPresented: $showingHighlightPalette,
                 attachmentAnchor: .point(.top),
                 arrowEdge: .bottom) {
            highlightPalettePopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var highlightPalettePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grayscale")
                .font(.cucuSans(13, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
            HStack(spacing: 6) {
                ForEach(TextInspectorV2.grayscaleHighlightHexes, id: \.self) { hex in
                    Button {
                        highlightColorHex = hex
                        showingHighlightPalette = false
                    } label: {
                        let selected = highlightColorHex.uppercased() == hex.uppercased()
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.cucuInk.opacity(selected ? 1 : 0.18),
                                            lineWidth: selected ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Highlight \(hex)")
                }
            }
            Divider()
            // "Custom color" is a plain Button — not a SwiftUI
            // `ColorPicker` — so the system picker isn't owned by this
            // popover. Tapping it closes the popover, then schedules
            // the system picker to present from the toolbar's own
            // `.sheet` modifier on the next animation tick. The delay
            // gives the popover time to finish dismissing first;
            // otherwise SwiftUI tries to animate the popover collapse
            // while a sheet is rising from the same view tree, which
            // is what made the picker visibly "pop" during exit.
            Button {
                showingHighlightPalette = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showingCustomColorPicker = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.cucuInk)
                    Text("Custom color")
                        .font(.cucuSans(13, weight: .medium))
                        .foregroundStyle(Color.cucuInk)
                    Spacer()
                    Circle()
                        .fill(Color(hex: highlightColorHex))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.cucuInk.opacity(0.25), lineWidth: 0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.cucuCard)
    }

    private func colorControl(title: String,
                              systemImage: String,
                              hex: Binding<String>,
                              supportsAlpha: Bool) -> some View {
        ColorPicker(selection: hex.asColor(), supportsOpacity: supportsAlpha) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Circle()
                    .fill(Color(hex: hex.wrappedValue))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.cucuInk.opacity(0.25), lineWidth: 0.5))
            }
            .foregroundStyle(Color.cucuInk)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.cucuInk.opacity(0.06))
            )
        }
        .accessibilityLabel(title)
    }

    private func toolbarButton<Label: View>(title: String,
                                            active: Bool,
                                            action: @escaping () -> Void,
                                            @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? Color.cucuCard : Color.cucuInk)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.cucuInk : Color.cucuInk.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// UIKit bridge for the system color picker. We can't open SwiftUI's
/// `ColorPicker` programmatically (it only presents on user tap of its
/// own view), so when the highlight popover wants to defer to the full
/// picker we present `UIColorPickerViewController` ourselves through a
/// state-driven `.sheet`. This keeps the picker out of the popover's
/// view tree entirely — no nested presentation, no flicker on exit.
private struct SystemColorPickerSheet: UIViewControllerRepresentable {
    @Binding var hex: String
    @Binding var isPresented: Bool
    var supportsAlpha: Bool

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let vc = UIColorPickerViewController()
        vc.delegate = context.coordinator
        vc.supportsAlpha = supportsAlpha
        vc.selectedColor = UIColor(Color(hex: hex))
        return vc
    }

    func updateUIViewController(_ uiViewController: UIColorPickerViewController, context: Context) {
        // Re-sync only when the hex actually drifted from outside (e.g.
        // the user picked a swatch in another surface). Skipping equal
        // assignments avoids a feedback loop where setting the same
        // color re-fires `didSelect` and bounces the binding.
        let target = UIColor(Color(hex: hex))
        if uiViewController.selectedColor != target {
            uiViewController.selectedColor = target
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let parent: SystemColorPickerSheet
        init(_ parent: SystemColorPickerSheet) { self.parent = parent }

        func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                       didSelect color: UIColor,
                                       continuously: Bool) {
            parent.hex = Color(uiColor: color).toHex()
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.isPresented = false
        }
    }
}
