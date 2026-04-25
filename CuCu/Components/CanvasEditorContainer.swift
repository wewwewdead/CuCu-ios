import SwiftUI
import UIKit

/// SwiftUI bridge to the UIKit `CanvasEditorView`. Drives reconciliation in
/// one direction (SwiftUI → UIView via `apply(document:selectedID:)`) and
/// reports user-driven mutations in the other (UIView → SwiftUI via the
/// `onSelectionChanged` and `onCommit` closures).
struct CanvasEditorContainer: UIViewRepresentable {
    @Binding var document: ProfileDocument
    @Binding var selectedID: UUID?

    /// Called on gesture-end commits. Caller persists to `ProfileDraft`.
    var onCommit: (ProfileDocument) -> Void

    func makeUIView(context: Context) -> CanvasEditorView {
        let view = CanvasEditorView()
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
        view.apply(document: document, selectedID: selectedID)
        return view
    }

    func updateUIView(_ view: CanvasEditorView, context: Context) {
        view.apply(document: document, selectedID: selectedID)
    }
}
