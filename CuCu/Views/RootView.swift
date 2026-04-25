import SwiftData
import SwiftUI

/// App entry point. The product is single-document for now: the app opens
/// straight into the canvas builder for the most recently updated draft,
/// auto-creating one on first launch if none exists.
///
/// `ProfileDraft` is still the SwiftData record that owns `designJSON`,
/// image asset paths, and any future publish metadata — we just don't
/// surface a list screen.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProfileDraft.updatedAt, order: .reverse) private var drafts: [ProfileDraft]

    var body: some View {
        NavigationStack {
            if let draft = drafts.first {
                ProfileCanvasBuilderView(draft: draft)
            } else {
                // First-launch bootstrap: insert one canvas draft, then
                // `@Query` updates and the branch above renders the
                // builder. `Color.clear` keeps the screen blank for the
                // few milliseconds it takes SwiftData to fire the
                // refresh.
                Color.clear
                    .task { ensureDraftExists() }
            }
        }
        // The canvas builder lifts itself above the keyboard via a
        // SwiftUI `.offset`. The NavigationStack — being a full-screen
        // container — must opt out of SwiftUI's automatic keyboard
        // safe-area shrink, otherwise it pre-shrinks the entire view
        // and our offset has nothing to lift into.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func ensureDraftExists() {
        guard drafts.isEmpty else { return }
        let store = DraftStore(context: context)
        _ = try? store.createCanvasDraft()
    }
}
