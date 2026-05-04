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
            .tint(Color.cucuInk)
            .toolbarBackground(Color.cucuPaper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)

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

    /// True while `ensureDraftExists` is awaiting the published-profile
    /// fetch. Combined with the "signed-in but username still
    /// hydrating" check below to drive `isLoadingProfile` and the
    /// editorial loading view — without it, the user would briefly
    /// see a blank canvas during the network round-trip after a
    /// fresh sign-in.
    @State private var isFetchingPublished: Bool = false

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
    /// the bootstrap is doing real work the user shouldn't see a
    /// blank canvas during. Three signals collapse into one flag:
    ///
    ///   - **No local draft for this user yet.** If a draft is
    ///     already on screen we don't want to flash the loading
    ///     view over it; only `else`-branch states qualify.
    ///   - **Signed in but `username` still nil.** A fresh sign-in
    ///     lands with `username` unhydrated for a beat —
    ///     `hydrateUsername()` runs after `signIn` resolves. The
    ///     keyed `.task` will re-fire when it lands; until then,
    ///     show the loading view.
    ///   - **Active published-profile fetch.** `ensureDraftExists`
    ///     toggles `isFetchingPublished` around the network round-
    ///     trip so the loading view stays put across the await.
    ///
    /// Signed-out users skip the loading view entirely — anonymous
    /// editing is supposed to be instant, so the empty-draft
    /// fallback paints immediately.
    private var isLoadingProfile: Bool {
        guard visibleDrafts.isEmpty else { return false }
        guard auth.currentUser != nil else { return false }
        if (auth.currentUser?.username ?? "").isEmpty { return true }
        return isFetchingPublished
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
                    .onAppear { claimIfUnowned(draft) }
            } else if isLoadingProfile {
                // Two cases land here, both during the brief window
                // between sign-in and the user's design becoming
                // available locally:
                //   - waiting on `hydrateUsername()` to finish
                //   - the published-profile fetch is in flight
                // An editorial pulse keeps the user oriented instead
                // of showing a blank canvas during that beat.
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
        // of stranding the user on a blank canvas. Keyed on both
        // userId and username because brand-new sign-ins land with
        // username=nil and `hydrateUsername()` populates it
        // asynchronously — without re-firing on the username
        // arrival, we'd miss the published-profile fetch and create
        // an empty draft anyway.
        .task(id: SessionKey(
            userId: auth.currentUser?.id,
            username: auth.currentUser?.username
        )) {
            await ensureDraftExists()
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

    /// Two-path bootstrap that handles both fresh-launch and
    /// account-switch scenarios.
    ///
    /// **Path A — no draft yet.** First try to seed from the user's
    /// published profile on Supabase (if they have one) so a
    /// returning user lands on their actual design instead of an
    /// empty canvas. Falls back to a fresh empty draft when there's
    /// no username, no published profile, or the network call
    /// fails — anonymous editing must always work.
    ///
    /// **Path B — a draft exists but is pristine.** Covers the
    /// common race where path A ran before `hydrateUsername()`
    /// resolved (so it created an empty draft and bailed); when
    /// the username arrives the keyed `.task` re-fires, finds the
    /// pristine draft, and swaps in the published design. We
    /// implement the swap by deleting + recreating so SwiftUI
    /// re-mounts `ProfileCanvasBuilderView` (its `@State document`
    /// would otherwise keep the old decoded JSON).
    ///
    /// Re-validates the user identity *after* every `await` so a
    /// rapid sign-out / sign-in mid-fetch can't write the wrong
    /// account's design into the new account's draft.
    private func ensureDraftExists() async {
        let canonical = auth.currentUser?.id.lowercased()
        let username = auth.currentUser?.username

        // Path A: no local draft for this user yet.
        if visibleDrafts.isEmpty {
            // Signed in but username still hydrating — wait for
            // the next .task fire (when username arrives) so we
            // don't create an empty draft we'd just have to throw
            // away. Anonymous (signed-out) users skip the wait
            // and get the empty draft immediately.
            if canonical != nil && (username?.isEmpty ?? true) {
                return
            }

            // Try to seed from the server-side published profile.
            // Toggle `isFetchingPublished` around the await so the
            // loading view stays mounted across the round-trip.
            if let canonical, let username, !username.isEmpty {
                isFetchingPublished = true
                let fetched = try? await PublishedProfileService()
                    .fetch(username: username)
                isFetchingPublished = false
                if let profile = fetched,
                   profile.userId.lowercased() == canonical,
                   auth.currentUser?.id.lowercased() == canonical,
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

        // Path B: a draft exists. If it's the auto-created
        // pristine empty (no edits, no prior publish) AND the
        // user now has a username AND the server has a published
        // profile for them, swap in the published design. This
        // is the recovery path for the "username hydrated after
        // path A already created the empty draft" race.
        guard let canonical, let username, !username.isEmpty,
              let draft = visibleDrafts.first,
              isPristine(draft) else { return }
        guard let profile = try? await PublishedProfileService()
            .fetch(username: username),
              profile.userId.lowercased() == canonical,
              auth.currentUser?.id.lowercased() == canonical,
              isPristine(draft) else { return }

        // Delete + recreate so the builder re-mounts cleanly
        // with the new designJSON. Mutating the existing draft's
        // designJSON in place wouldn't work — the editor's
        // already-decoded `@State document` would survive.
        let store = DraftStore(context: context)
        store.deleteDraft(draft)
        seedDraft(from: profile, canonical: canonical)
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
/// design is being pulled across the wire (or while we're waiting
/// for the auth view-model's `hydrateUsername()` to resolve so we
/// can even start the fetch). Three layered details carry the
/// "we're setting your page" feel without resorting to a generic
/// spinner:
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

/// Composite key driving `BuildTab`'s session-aware bootstrap.
/// Both fields participate so the keyed `.task` re-fires twice
/// across a typical sign-in flow: once when `userId` flips from
/// nil → the new account, and again when `hydrateUsername()`
/// resolves and `username` flips from nil → the claimed handle.
/// Equatable derivation does the right thing — only string
/// comparisons.
private struct SessionKey: Hashable {
    let userId: String?
    let username: String?
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
