import SwiftData
import SwiftUI

/// App entry point. The product is single-document: the app opens
/// straight into the canvas builder for the most recently updated
/// `ProfileDraft`, auto-creating one on first launch if none exists.
///
/// The earlier prototype showed a "drafts page" toolbar (`+` menu for
/// blank/template, alert for failed creation, sheet for picking a
/// template) — all of that's been removed because the product is
/// single-doc now. The Explore entry that lived here is gone too;
/// it's reachable from the canvas builder's own toolbar instead.
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
