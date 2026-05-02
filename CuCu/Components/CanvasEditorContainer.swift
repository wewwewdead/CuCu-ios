import SwiftUI
import UIKit

/// SwiftUI bridge to the UIKit `CanvasEditorView`. Drives reconciliation in
/// one direction (SwiftUI → UIView via `apply(document:selectedID:)`) and
/// reports user-driven mutations in the other (UIView → SwiftUI via the
/// `onSelectionChanged` and `onCommit` closures).
///
/// `isInteractive` toggles between the editor (default) and the read-only
/// viewer used by `PublishedProfileView`. In viewer mode no editing
/// gestures are attached; only `.link` nodes get a tap recognizer that
/// surfaces their URL via `onOpenURL`.
struct CanvasEditorContainer: UIViewRepresentable {
    @Binding var document: ProfileDocument
    @Binding var selectedID: UUID?

    /// Called on gesture-end commits. Caller persists to `ProfileDraft`.
    var onCommit: (ProfileDocument) -> Void

    /// Editor-only callback from the dashed affordance below the page stack.
    var onAddPage: (() -> Void)? = nil

    /// Editor-only callback from per-page chrome. Host confirms deletion.
    var onDeletePageRequested: ((Int) -> Void)? = nil

    /// Reports which page the host's page settings UI should target.
    var onEditingPageChanged: ((Int) -> Void)? = nil

    /// `false` puts the canvas into read-only viewer mode (used by
    /// `PublishedProfileView`). Defaults to the editor.
    var isInteractive: Bool = true

    /// When `true` the canvas paints the per-node edit chrome —
    /// dashed accent outlines, labelled chips above each top-level
    /// node, and an inset stroke around every page so the surface
    /// reads as "armed". Off by default; bound from the SwiftUI host.
    var editMode: Bool = false

    /// Height of the bottom chrome (selection panel + keyboard
    /// avoidance padding) the SwiftUI host is reserving above the
    /// canvas. The canvas pads its scroll view's bottom inset by this
    /// amount and walks the selected node above it on every change,
    /// so the inspector subject is never hidden behind the panel.
    /// `0` means no panel is showing.
    var bottomChromeHeight: CGFloat = 0

    /// Called when a `.link` node is tapped while `isInteractive` is
    /// `false`. Receives the resolved URL — strings that don't parse
    /// or are obviously not URLs are filtered upstream so the host
    /// can directly hand the value to `openURL` / `UIApplication.open`.
    var onOpenURL: ((URL) -> Void)? = nil

    /// Called when a `.gallery` tile is tapped while `isInteractive` is
    /// `false`. Receives the gallery's full URL list and the index of
    /// the tapped image so the host can present a paginated lightbox.
    var onOpenImage: (([URL], Int) -> Void)? = nil

    /// Called when a Journal Card container is tapped while
    /// `isInteractive` is `false`. The host pulls the card's title +
    /// body out of the document and presents the journal modal.
    var onOpenJournal: ((UUID) -> Void)? = nil

    /// Called when the "View Gallery" chip is tapped while
    /// `isInteractive` is `false`. Receives the gallery's full URL
    /// list so the host can present the paginated grid.
    var onOpenFullGallery: (([URL]) -> Void)? = nil

    /// Fires when the user taps an empty canvas area in edit mode
    /// with nothing selected — the second tap of the two-tap-out
    /// pattern. Host clears its `editMode` state so the canvas
    /// returns to the live preview.
    var onRequestExitEditMode: (() -> Void)? = nil

    /// Viewer-only page scope. nil renders the full editable page stack.
    var viewerPageIndex: Int? = nil

    func makeUIView(context: Context) -> CanvasEditorView {
        let view = CanvasEditorView()
        view.isInteractive = isInteractive
        view.viewerPageIndex = viewerPageIndex
        view.onSelectionChanged = { id in
            // Avoid feedback loops: only push if it actually changed.
            if selectedID != id {
                selectedID = id
            }
        }
        view.onCommit = { doc in
            document = doc
            onCommit(doc)
        }
        view.onAddPage = {
            onAddPage?()
        }
        view.onDeletePageRequested = { index in
            onDeletePageRequested?(index)
        }
        view.onEditingPageChanged = { index in
            onEditingPageChanged?(index)
        }
        view.onOpenURL = { url in
            onOpenURL?(url)
        }
        view.onOpenImage = { urls, index in
            onOpenImage?(urls, index)
        }
        view.onOpenJournal = { id in
            onOpenJournal?(id)
        }
        view.onOpenFullGallery = { urls in
            onOpenFullGallery?(urls)
        }
        view.onRequestExitEditMode = {
            onRequestExitEditMode?()
        }
        view.setEditMode(editMode)
        view.setBottomChromeHeight(bottomChromeHeight)
        view.apply(document: document, selectedID: selectedID)
        return view
    }

    func updateUIView(_ view: CanvasEditorView, context: Context) {
        // Re-bind closures on every update so SwiftUI captures stay
        // current with the latest `@State` / `@Environment`. Cheap —
        // just closure assignment, no UIView mutation. `isInteractive`
        // is set once at make-time; flipping editor↔viewer at runtime
        // would require re-attaching gestures, which neither the
        // editor nor the viewer currently does.
        view.viewerPageIndex = viewerPageIndex
        view.onAddPage = {
            onAddPage?()
        }
        view.onDeletePageRequested = { index in
            onDeletePageRequested?(index)
        }
        view.onEditingPageChanged = { index in
            onEditingPageChanged?(index)
        }
        view.onOpenURL = { url in
            onOpenURL?(url)
        }
        view.onOpenImage = { urls, index in
            onOpenImage?(urls, index)
        }
        view.onOpenJournal = { id in
            onOpenJournal?(id)
        }
        view.onOpenFullGallery = { urls in
            onOpenFullGallery?(urls)
        }
        view.onRequestExitEditMode = {
            onRequestExitEditMode?()
        }
        view.setEditMode(editMode)
        view.setBottomChromeHeight(bottomChromeHeight)
        view.apply(document: document, selectedID: selectedID)
    }
}
