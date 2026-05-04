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
        .tint(Color.cucuInk)
        .toolbarBackground(Color.cucuPaper, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
///
/// **Per-user draft scoping.** SwiftData isn't user-scoped, so on
/// a device that hosts more than one Supabase account we filter
/// the visible draft to ones the current account either owns
/// (`draft.ownerUserId == auth.currentUser?.id`) or hasn't claimed
/// yet (`ownerUserId == nil`, i.e. an anonymous draft from before
/// sign-in). Without this, signing out → signing in as a different
/// account would surface the previous user's design — and tapping
/// Publish would write that design to the new user's profile.
/// Anonymous drafts get claimed (`ownerUserId` stamped) the first
/// time a signed-in user views them, after which they're scoped to
/// that account.
private struct BuildTab: View {
    @Environment(\.modelContext) private var context
    @Environment(AuthViewModel.self) private var auth
    @Query(sort: \ProfileDraft.updatedAt, order: .reverse) private var drafts: [ProfileDraft]

    /// Drafts visible to the currently signed-in account. When
    /// signed out, every draft is visible — anonymous editing
    /// stays untouched. When signed in, the filter has two layers:
    ///
    ///   1. Explicit `ownerUserId` match — the canonical "this draft
    ///      is mine" signal, set on bootstrap or first-edit claim.
    ///   2. For drafts that lack an explicit owner stamp (legacy +
    ///      anonymous), look at `publishedOwnerUserId` — if a prior
    ///      publish stamped a *different* account, the draft was
    ///      authored by that account and a new sign-in shouldn't
    ///      inherit it. This is the hole that produced the
    ///      "I published a profile and Explore opens another
    ///      user's content" symptom: pre-fix, a fresh sign-in could
    ///      pick up a draft Alice had published, edit it, and
    ///      republish under the new user's handle — leaving two
    ///      visually-similar published rows on the cloud.
    ///
    /// Truly-anonymous drafts (no owner stamp, no prior publish)
    /// stay claimable so an offline-then-sign-up flow doesn't
    /// orphan the user's pre-account work.
    private var visibleDrafts: [ProfileDraft] {
        let canonical = auth.currentUser?.id.lowercased()
        return drafts.filter { draft in
            guard let canonical else { return true }
            if let owner = draft.ownerUserId { return owner == canonical }
            if let pubOwner = draft.publishedOwnerUserId,
               pubOwner != canonical {
                return false
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            if let draft = visibleDrafts.first {
                ProfileCanvasBuilderView(draft: draft)
                    .onAppear { claimIfUnowned(draft) }
            } else {
                // First-launch bootstrap (or first-launch-for-this-
                // account, since per-user filtering can return an
                // empty list even when other users' drafts exist on
                // disk). Insert one canvas draft stamped to the
                // current user (if any), then `@Query` updates and
                // the branch above renders the builder.
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

    /// Stamp the current user's id onto a draft that has none yet.
    /// Lets anonymous drafts (created pre-sign-in or before this
    /// field existed) flip into the user's scoped set on first
    /// view, instead of staying available to every future account
    /// on the device.
    private func claimIfUnowned(_ draft: ProfileDraft) {
        guard draft.ownerUserId == nil,
              let canonical = auth.currentUser?.id.lowercased() else { return }
        draft.ownerUserId = canonical
        try? context.save()
    }

    private func ensureDraftExists() {
        guard visibleDrafts.isEmpty else { return }
        let store = DraftStore(context: context)
        let canonical = auth.currentUser?.id.lowercased()
        if let draft = try? store.createCanvasDraft() {
            // Stamp ownership immediately when a user is signed
            // in so the new draft is scoped from creation. When
            // signed out, leave the field nil — first signed-in
            // viewer claims it.
            if let canonical {
                draft.ownerUserId = canonical
                try? context.save()
            }
        }
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
