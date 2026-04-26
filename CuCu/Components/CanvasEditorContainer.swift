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

    /// Called when the user long-presses a node — the canvas already
    /// updated its own selection and fired a haptic; the host's job
    /// is to present the property inspector for that node.
    var onRequestEditNode: ((UUID) -> Void)? = nil

    /// `false` puts the canvas into read-only viewer mode (used by
    /// `PublishedProfileView`). Defaults to the editor.
    var isInteractive: Bool = true

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

    func makeUIView(context: Context) -> CanvasEditorView {
        let view = CanvasEditorView()
        view.isInteractive = isInteractive
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
        view.onRequestEditNode = { id in
            onRequestEditNode?(id)
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
        view.onRequestEditNode = { id in
            onRequestEditNode?(id)
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
        view.apply(document: document, selectedID: selectedID)
    }
}
