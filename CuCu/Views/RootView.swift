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
    /// Process-wide chrome theme. The TabView shell reads this so the
    /// tab bar repaints in lock-step with the page above it — Feed's
    /// background and the bar underneath should never disagree on
    /// what stock the room is painted in. The Build tab still owns
    /// its own surface (per-page `PageStyle.backgroundHex`), so the
    /// bar is the only seam this store needs to bridge.
    @State private var chrome = AppChromeStore.shared

    /// Three tabs that survive a relaunch via `@AppStorage`.
    /// Storing the rawValue keeps the persisted value
    /// human-readable for debugging.
    enum Tab: String, CaseIterable {
        case build
        case feed
        case explore
    }

    var body: some View {
        ZStack {
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
            .tint(chrome.theme.inkPrimary)
            .toolbarBackground(chrome.theme.pageColor, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            // Match the bar's `colorScheme` to the chrome mood so
            // SwiftUI picks the right glyph variants for the tab
            // icons — a midnight backdrop reads dark, snow reads
            // light, and the Build tab's own light look isn't
            // affected because it draws its own page bg above this.
            .toolbarColorScheme(chrome.theme.preferredColorScheme, for: .tabBar)

            // Post-submission flight overlay. Sits above the TabView
            // so the ghost card and its particle burst paint on top
            // of the feed once the compose sheet has dismissed.
            // The overlay self-hides when the coordinator is idle
            // and never blocks input (`.allowsHitTesting(false)`),
            // so it's safe to leave mounted permanently.
            CucuPostFlightOverlay()
                .allowsHitTesting(false)
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
    /// Drives the `BuildTabLoadingView` branch in `body`. True while
    /// a signed-in account has no visible local draft yet, which is
    /// exactly when bootstrap may be pulling that user's published
    /// profile from Supabase or creating their first empty draft.
    ///
    ///   - **No local draft for this user yet.** If a draft is
    ///     already on screen we don't want to flash the loading
    ///     view over it; only `else`-branch states qualify.
    /// Signed-out users skip the loading view entirely — anonymous
    /// editing is supposed to be instant, so the empty-draft
    /// fallback paints immediately.
    private var isLoadingProfile: Bool {
        guard visibleDrafts.isEmpty else { return false }
        guard auth.currentUser != nil else { return false }
        return true
    }

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
                    // Force a fresh view instance when the underlying
                    // draft changes (e.g. sign-out → sign-in as a
                    // different account on the same device). Without
                    // this, SwiftUI reuses the existing view and its
                    // `@State document` keeps the previous user's
                    // decoded design — so the new user sees the old
                    // user's profile until relaunch.
                    .id(draft.id)
            } else if isLoadingProfile {
                // Brief window between sign-in and the user's design
                // becoming available locally. An editorial pulse keeps
                // the user oriented instead of showing a blank canvas.
                BuildTabLoadingView()
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            } else {
                // Anonymous (signed-out) bootstrap, or the rare
                // case where session resolved with no draft and
                // no published profile to seed from. The keyed
                // `.task` below will insert the empty draft on
                // its next tick; this is just a clean fallback
                // surface for that single frame.
                Color.clear
            }
        }
        // Re-run draft bootstrap on every session change so a
        // sign-in to a different account picks up that account's
        // published profile from Supabase (when one exists) instead
        // of inheriting another local account's draft.
        .task(id: auth.currentUser?.id) {
            await ensureDraftExists()
        }
    }

    /// Stamp the current user's id onto a draft that has none yet, but
    /// only after the bootstrap has checked Supabase for a published
    /// profile. That ordering keeps stale anonymous drafts on a shared
    /// phone from winning over the signed-in user's cloud profile.
    private func claimIfUnowned(_ draft: ProfileDraft, canonical: String) {
        guard draft.ownerUserId == nil,
              auth.currentUser?.id.lowercased() == canonical else { return }
        draft.ownerUserId = canonical
        try? context.save()
    }

    /// Two-path bootstrap that handles both fresh-launch and
    /// account-switch scenarios.
    ///
    /// **Path A — no draft yet.** First try to seed from the user's
    /// published profile on Supabase (if they have one) so a
    /// returning user lands on their actual design instead of an
    /// empty canvas. Falls back to a fresh empty draft when there's
    /// no published profile or the network call fails — anonymous
    /// editing must always work.
    ///
    /// **Path B — a replaceable draft exists.** If the only visible
    /// draft is anonymous or pristine, the user's published profile
    /// gets a chance to replace it before the draft is claimed.
    ///
    /// Re-validates the user identity *after* every `await` so a
    /// rapid sign-out / sign-in mid-fetch can't write the wrong
    /// account's design into the new account's draft.
    private func ensureDraftExists() async {
        let canonical = auth.currentUser?.id.lowercased()

        // Path A: no local draft for this user yet.
        if visibleDrafts.isEmpty {
            // Try to seed from the server-side published profile by
            // user id. This works on a fresh phone before username
            // hydration has completed, and it ignores stale local
            // username state entirely.
            if let canonical {
                if let profile = await fetchPublishedProfile(userId: canonical),
                   visibleDrafts.isEmpty {
                    seedDraft(from: profile, canonical: canonical)
                    return
                }
            }

            // Re-check after the await — another path may have
            // beaten us to draft creation.
            guard visibleDrafts.isEmpty else { return }

            // Fallback: fresh empty draft. Stamp ownership
            // immediately when signed in so the new draft is
            // scoped from creation; when signed out, leave the
            // field nil — first signed-in viewer claims it.
            let store = DraftStore(context: context)
            if let draft = try? store.createCanvasDraft() {
                if let canonical {
                    draft.ownerUserId = canonical
                    try? context.save()
                }
            }
            return
        }

        // Path B: a draft exists. If it is an unowned anonymous
        // draft, or the auto-created pristine empty draft, first ask
        // Supabase whether this signed-in account already published a
        // profile. Published cloud state wins over anonymous local
        // leftovers on shared devices. If no profile exists, the
        // anonymous draft is claimed for the current account.
        guard let canonical,
              let draft = visibleDrafts.first else { return }
        let canReplaceWithCloud = draft.ownerUserId == nil || isPristine(draft)
        guard canReplaceWithCloud else { return }

        if let profile = await fetchPublishedProfile(userId: canonical),
           auth.currentUser?.id.lowercased() == canonical,
           visibleDrafts.first?.id == draft.id,
           (draft.ownerUserId == nil || isPristine(draft)) {
            // Delete + recreate so the builder re-mounts cleanly
            // with the new designJSON. Mutating the existing draft's
            // designJSON in place wouldn't work — the editor's
            // already-decoded `@State document` would survive.
            let store = DraftStore(context: context)
            store.deleteDraft(draft)
            seedDraft(from: profile, canonical: canonical)
        } else {
            claimIfUnowned(draft, canonical: canonical)
        }
    }

    private func fetchPublishedProfile(userId canonical: String) async -> PublishedProfile? {
        guard auth.currentUser?.id.lowercased() == canonical else { return nil }
        guard let profile = try? await PublishedProfileService()
            .fetch(userId: canonical),
              profile.userId.lowercased() == canonical,
              auth.currentUser?.id.lowercased() == canonical else {
            return nil
        }
        return profile
    }

    /// Pristine = the auto-created empty draft we just bootstrapped.
    /// Defined narrowly so genuine in-progress work (any edit, any
    /// prior publish) can never be swept away by the published
    /// hydration path.
    private func isPristine(_ draft: ProfileDraft) -> Bool {
        return draft.designJSON == CanvasDocumentCodec.fallbackJSON
            && draft.publishedProfileId == nil
    }

    /// Insert a fresh draft seeded with the published profile's
    /// `design_json`, stamping all the publish-metadata fields so
    /// a subsequent re-publish upserts the same server row instead
    /// of inserting a duplicate.
    private func seedDraft(from profile: PublishedProfile, canonical: String) {
        let store = DraftStore(context: context)
        guard let draft = try? store.createCanvasDraft() else { return }
        let json = (try? CanvasDocumentCodec.encode(profile.document))
            ?? CanvasDocumentCodec.fallbackJSON
        draft.designJSON = json
        draft.title = profile.username
        draft.ownerUserId = canonical
        draft.publishedProfileId = profile.id
        draft.publishedUsername = profile.username
        draft.publishedOwnerUserId = canonical
        draft.lastPublishedAt = profile.publishedAt
        draft.updatedAt = .now
        try? context.save()
    }
}

// MARK: - Build tab loading view

/// Editorial loading state shown in the build tab while the user's
/// design is being pulled across the wire. Three layered details
/// carry the "we're setting your page" feel without resorting to a
/// generic spinner:
///
///   1. **Tracked spec line** — a printer's-mark style label that
///      tells the user *what* is happening, not just *that*
///      something is happening.
///   2. **Pulsing fleuron** — the same `❦` glyph used elsewhere in
///      the design system, scaled and dimmed in tandem so it reads
///      as a heartbeat rather than a loading sprite.
///   3. **Skeleton page bars** — three capsule rules of varying
///      widths that ghost the rough geometry of a profile masthead
///      + body, pulsing in lock-step with the fleuron so the page
///      breathes as one unit.
private struct BuildTabLoadingView: View {
    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("PULLING YOUR PROFILE")
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(3.0)
                    .foregroundStyle(Color.cucuInkFaded)

                Text("❦")
                    .font(.cucuSerif(56, weight: .regular))
                    .foregroundStyle(Color.cucuInk)
                    .scaleEffect(pulse ? 1.06 : 0.92)
                    .opacity(pulse ? 1.0 : 0.55)

                Text("Setting the page from your published draft.")
                    .font(.cucuEditorial(14, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(alignment: .center, spacing: 9) {
                    skeletonRule(width: 200)
                    skeletonRule(width: 240)
                    skeletonRule(width: 160)
                }
                .padding(.top, 8)
                .opacity(pulse ? 1.0 : 0.5)
            }
        }
        .onAppear {
            // Single pulse curve drives both the fleuron and the
            // skeleton bars — keeps the breathing rhythm coherent
            // instead of two competing timers drifting against
            // each other.
            withAnimation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
            ) {
                pulse = true
            }
        }
    }

    private func skeletonRule(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.cucuCardSoft)
            .frame(width: width, height: 8)
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
