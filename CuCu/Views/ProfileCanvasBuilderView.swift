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

    @State private var document: ProfileDocument = .blank
    @State private var selectedID: UUID?
    @State private var legacyDraft: Bool = false
    @State private var titleDraft: String = ""
    @State private var sheets = CanvasSheetCoordinator()
    // MARK: Reset Profile (full local + cloud wipe)
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    /// Set when the cloud half of `performReset()` failed (or was
    /// skipped because the user is signed out). Drives the secondary
    /// "Couldn't fully reset" alert; the local wipe still proceeded.
    @State private var resetErrorMessage: String?

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
            document: $document,
            selectedID: $selectedID,
            draft: draft,
            store: resolvedStore,
            context: context
        )
    }

    /// Where a new node will land if the user adds one right now. Mirrors
    /// the rule used inside `CanvasMutator.parentForInsertion`, so the
    /// AddNodeSheet's banner stays accurate.
    private var addDestination: AddNodeSheet.Destination {
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
        document.rootChildrenIDs.isEmpty && document.nodes.isEmpty
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
                        document = doc
                        resolvedStore.updateDocument(draft, document: doc)
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
                        if sheets.anyModalActive { return }
                        selectedID = id
                        sheets.showInspector = true
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
            // Bottom selection surface — collapsed (small chevron pill)
            // by default, full bar when the user expands it. Floats
            // above the canvas (no safeAreaInset) so the canvas bounds
            // stay constant regardless of which form is showing.
            if !legacyDraft, let id = selectedID, document.nodes[id] != nil {
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
        // Opt the entire view tree out of SwiftUI's automatic
        // keyboard safe-area shrink. We don't want the canvas's
        // allotted space to change when the keyboard appears — the
        // canvas keeps its full size, and only the *editing text
        // node* lifts itself (via a transform inside the UIKit
        // canvas) to sit above the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: selectedID)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: sheets.isSelectionBarExpanded)
        .onChange(of: selectedID) { _, newID in
            sheets.handleSelectionChanged(newID: newID)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(sheets: sheets) }
        .modifier(CanvasBuilderSheetsModifier(
            document: $document,
            selectedID: $selectedID,
            draft: draft,
            sheets: sheets,
            mutator: mutator,
            addDestination: addDestination,
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
        .onAppear {
            // Cache the draft store once for the lifetime of this view.
            // The model context isn't available at init time, so this is
            // the earliest point where we can resolve it.
            if store == nil {
                store = DraftStore(context: context)
            }
            loadDraft()
        }
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

        ToolbarItem(placement: .principal) {
            TextField("Untitled", text: $titleDraft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
                .onChange(of: titleDraft) { _, newValue in
                    resolvedStore.updateTitle(draft, title: newValue.isEmpty ? "Untitled" : newValue)
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
                Button("Layers", systemImage: "square.3.layers.3d") { sheets.showLayersSheet = true }
                Divider()
                Button("Duplicate", systemImage: "plus.square.on.square") { mutator.duplicateSelected() }
                    .disabled(selectedID == nil)
                Button("Bring to Front", systemImage: "square.stack.3d.up") { mutator.bringSelectedToFront() }
                    .disabled(selectedID == nil)
                Button("Send Backward", systemImage: "square.stack.3d.down.right") { mutator.sendSelectedBackward() }
                    .disabled(selectedID == nil)
                Button("Edit Properties…", systemImage: "slider.horizontal.3") { sheets.showInspector = true }
                    .disabled(selectedID == nil)
                Divider()
                Button("Save as Template", systemImage: "square.and.arrow.down") {
                    sheets.showSaveTemplateSheet = true
                }
                Button("Apply Template", systemImage: "square.on.square") {
                    sheets.showApplyTemplateSheet = true
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
                    .disabled(selectedID == nil)
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
            Text("Starting fresh will replace its contents with a blank canvas. The current data will be overwritten only after you confirm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Start fresh canvas") {
                document = .blank
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
            resolvedStore.updateDocument(draft, document: document)
        }
    }

    // MARK: - Reset / Unpublish

    /// Confirmation copy for the destructive Reset action. Branches on
    /// whether the draft was ever published — the published case warns
    /// about the cloud wipe in addition to the local one.
    private var resetConfirmationMessage: String {
        if draft.publishedProfileId != nil {
            return "This will remove every node and image on your canvas, take down your published profile, and delete every image you've uploaded from the cloud. This can't be undone."
        }
        return "This will remove every node and image on your canvas. This can't be undone."
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
        document = .blank
        selectedID = nil
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
