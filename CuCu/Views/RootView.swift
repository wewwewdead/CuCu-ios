import SwiftData
import SwiftUI

/// App entry point. Phase 6 promotes the root from a single-screen
/// router to a three-tab `TabView`:
///
///   - **Build**   — the existing `ProfileCanvasBuilderView` flow
///                   (canvas editor + first-launch draft bootstrap).
///   - **Feed**    — global Latest posts (`PostFeedView`).
///   - **Explore** — published profiles directory
///                   (`PublishedProfilesListView`).
///
/// Each tab owns its own `NavigationStack` so pushes inside one tab
/// don't leak across tab swaps — push a thread on Feed, switch to
/// Build, switch back, and the thread is still there. The earlier
/// "drafts page" toolbar and the Feed entry that lived inside the
/// builder's overflow menu are gone — those surfaces are tabs now.
struct RootView: View {
    @AppStorage("cucu.selected_tab") private var selectedTabRaw: String = Tab.build.rawValue

    /// Three tabs that survive a relaunch via `@AppStorage`.
    /// Storing the rawValue keeps the persisted value
    /// human-readable for debugging.
    enum Tab: String, CaseIterable {
        case build
        case feed
        case explore
    }

    var body: some View {
        TabView(selection: tabBinding) {
            BuildTab()
                .tabItem {
                    Label("Build", systemImage: "paintbrush")
                }
                .tag(Tab.build)

            FeedTab()
                .tabItem {
                    Label("Feed", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.feed)

            ExploreTab()
                .tabItem {
                    Label("Explore", systemImage: "sparkles")
                }
                .tag(Tab.explore)
        }
        // The canvas builder lifts itself above the keyboard via a
        // SwiftUI `.offset`. The TabView must opt out of SwiftUI's
        // automatic keyboard safe-area shrink so the offset has
        // somewhere to lift into rather than being pre-shrunk.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Measure the scene's available width once at the root so
        // every surface below this point can branch on
        // `@Environment(\.cucuWidthClass)` without remeasuring.
        .cucuWidthClass()
    }

    /// `@AppStorage` exposes the raw string; SwiftUI's `TabView`
    /// wants a `Binding<Tab>`. The mapping rejects unknown values
    /// (a corrupted defaults blob, or a future enum case loaded by
    /// an older binary) by snapping back to `.build` — guaranteed
    /// to be a usable surface even when offline.
    private var tabBinding: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: selectedTabRaw) ?? .build },
            set: { selectedTabRaw = $0.rawValue }
        )
    }
}

// MARK: - Tabs

/// Build tab — wraps the existing canvas editor and owns the
/// first-launch draft bootstrap + default-template seeding.
/// Bootstrapping here (and not on the TabView shell) keeps the
/// offline-first invariant intact: signed out + no network + no
/// draft still launches into a usable empty editor.
private struct BuildTab: View {
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
        // Default templates: insert / refresh the seven prebuilt picks
        // so the "Apply Template" sheet always has them. Idempotent —
        // existing rows are skipped unless the bundled seed version
        // changed.
        .task { DefaultTemplateSeeder.seedIfNeeded(context: context) }
    }

    private func ensureDraftExists() {
        guard drafts.isEmpty else { return }
        let store = DraftStore(context: context)
        _ = try? store.createCanvasDraft()
    }
}

/// Feed tab — global Latest posts. Wrapped in its own
/// `NavigationStack` so pushing a thread inside Feed leaves the
/// other tabs' navigation state untouched.
private struct FeedTab: View {
    var body: some View {
        NavigationStack {
            PostFeedView()
        }
    }
}

/// Explore tab — published profiles directory. Same per-tab
/// navigation isolation as Feed: pushing a profile here doesn't
/// alter what the Build or Feed tabs look like.
private struct ExploreTab: View {
    var body: some View {
        NavigationStack {
            PublishedProfilesListView()
        }
    }
}
