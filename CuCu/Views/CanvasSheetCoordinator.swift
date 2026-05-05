import Foundation
import Observation

/// Holds every modal/transition flag that `ProfileCanvasBuilderView`
/// previously stored as standalone `@State` booleans, plus the chained
/// hand-offs between sheets.
///
/// Two chain patterns lived in the original view:
/// 1. **Page background → Effects.** Tapping "Edit Image" inside the
///    page-background sheet sets a pending flag and dismisses the page
///    sheet; on dismiss, we present the effects sheet. Doing this in
///    one tick caused SwiftUI's "can't present from a view that's being
///    dismissed" stutter.
/// 2. **Inspector → Container effects.** Same idea: tapping "Edit
///    Effects" inside the inspector for a container's background
///    closes the inspector with a pending flag, which `onDismiss`
///    converts into the container-effects sheet (after validating that
///    the target container still exists).
///
/// Both chains are owned here so the view can treat them as
/// `requestEdit…()` + `handle…Dismiss()` intent calls instead of
/// re-implementing the boolean dance per sheet.
@Observable
@MainActor
final class CanvasSheetCoordinator {
    // Sheets / covers
    var showAddSheet = false
    var showInspector = false
    var showPreview = false
    var showPublishSheet = false
    var showOpenProfileSheet = false
    var showPageBackgroundSheet = false
    var showBackgroundEffectsSheet = false
    var showLayersSheet = false
    var showThemePickerSheet = false
    var showContainerBackgroundEffectsSheet = false

    // Pending chain flags — set when the user requests a transition,
    // consumed by the next `onDismiss`.
    var pendingShowBackgroundEffects = false
    var pendingShowContainerBackgroundEffects = false
    /// Used by Step 5 — set when the user taps Publish from the
    /// preview cover, consumed by the cover's `onDismiss`.
    var pendingShowPublishSheet = false

    // Selection-tied surfaces
    /// Whether the bottom selection bar is in its expanded form. Resets
    /// to false on every selection change so a fresh tap surfaces the
    /// small chevron pill first.
    var isSelectionBarExpanded = false
    /// Container whose background-effects sheet is currently armed
    /// (pending) or live. Cleared whenever selection moves away or the
    /// effects sheet dismisses.
    var containerEffectsTargetID: UUID?

    // Navigation hand-off after publish
    var publishedViewerUsername: String?
    var shareProfileUsername: String?

    // MARK: - Page background → effects chain

    /// User tapped "Edit Image" inside `PageBackgroundSheet`. Arm the
    /// chain and dismiss the page sheet so its `onDismiss` can promote
    /// the pending flag to the live effects sheet.
    func requestEditPageEffects() {
        pendingShowBackgroundEffects = true
        showPageBackgroundSheet = false
    }

    /// `onDismiss` handler for `PageBackgroundSheet` — completes the
    /// chain by surfacing the effects sheet.
    func handlePageBackgroundDismiss() {
        if pendingShowBackgroundEffects {
            pendingShowBackgroundEffects = false
            showBackgroundEffectsSheet = true
        }
    }

    // MARK: - Inspector → container effects chain

    /// User tapped "Edit Effects" inside the property inspector for a
    /// container's background image. Arm the chain and dismiss the
    /// inspector.
    func requestEditContainerEffects(for nodeID: UUID) {
        containerEffectsTargetID = nodeID
        pendingShowContainerBackgroundEffects = true
        showInspector = false
    }

    /// `onDismiss` for the inspector — promotes the pending flag to
    /// the live effects sheet, validating the target still exists as a
    /// container so we never present a blank effects sheet.
    func handleInspectorDismiss(document: ProfileDocument) {
        guard pendingShowContainerBackgroundEffects else { return }
        pendingShowContainerBackgroundEffects = false
        guard let id = containerEffectsTargetID,
              document.nodes[id]?.type == .container else {
            containerEffectsTargetID = nil
            return
        }
        showContainerBackgroundEffectsSheet = true
    }

    /// `onDismiss` for the container effects sheet — clear the target
    /// so a stale ID can never resurface as a blank modal if SwiftUI
    /// re-presents this sheet later.
    func handleContainerEffectsDismiss() {
        containerEffectsTargetID = nil
    }

    // MARK: - Selection change

    /// Apply the side-effects of a `selectedID` transition. Mirrors
    /// the view's previous inline `.onChange` handler exactly:
    /// - collapse the selection bar
    /// - if newID is nil: tear down inspector + container effects target
    /// - if newID moved off the container effects target while the
    ///   effects sheet is up: dismiss the effects sheet
    func handleSelectionChanged(newID: UUID?) {
        isSelectionBarExpanded = false
        if newID == nil {
            showInspector = false
            showContainerBackgroundEffectsSheet = false
            pendingShowContainerBackgroundEffects = false
            containerEffectsTargetID = nil
        } else if newID != containerEffectsTargetID,
                  showContainerBackgroundEffectsSheet {
            showContainerBackgroundEffectsSheet = false
            containerEffectsTargetID = nil
        }
    }
}
