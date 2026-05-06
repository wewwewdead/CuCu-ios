import SwiftUI

/// "Finds" — explore feed for published profiles. Each row reads as a
/// preview banner that mirrors the user's hero (background + display
/// name + bio in their authored font / color), with a small avatar tile
/// to the left. The page composes:
///
///   1. **Title row** — large display title + small avatar puck on
///      the trailing edge.
///   2. **Search field** — pill-shaped, paper-toned, with an inline
///      magnifying glass.
///   3. **Top This Week carousel** — short banner pills of the hottest
///      published profiles. Tappable like the main cards.
///   4. **Category pills** — horizontal scroll of soft-tone tags. The
///      list is local for now (no backend taxonomy); the active pill
///      shows an ink underline. Picks fall through to a no-op until
///      we wire category filtering server-side.
///   5. **Suggested / Recents / Online segment** — the three primary
///      sub-filters. Suggested + Recents map to the existing Hottest
///      + Latest fetches; Online is a placeholder until we ship a
///      presence channel (renders an empty state with a clear note).
///   6. **Banner card column** — paginated list of `PreviewBannerCard`
///      rows. Pull-to-refresh, infinite scroll, dismiss-per-row, and
///      tap-to-view all live here.
///
/// State surfaces:
///   - **loading** — initial fetch in flight (centered spinner)
///   - **loaded** — feed renders; tap a card to push the viewer
///   - **empty (feed)** — RLS allowed reads but nothing's published
///   - **empty (search)** — query has no matches
///   - **error** — Supabase / network failure (Retry button)
struct PublishedProfilesListView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var profiles: [PublishedProfileSummary] = []
    @State private var topPicks: [PublishedProfileSummary] = []
    @State private var status: Status = .loading
    @State private var query: String = ""
    @State private var feedMode: FeedMode = .suggested
    /// Active vibe filter. `nil` is "All" — the selector treats the
    /// "All" pill as the absence of a category constraint, so old
    /// rows that never got vibe-stamped still surface under it.
    @State private var category: ProfileVibe?
    @State private var canLoadMore: Bool = true
    @State private var isLoadingMore: Bool = false
    @State private var dismissed: Set<String> = []
    /// Lazy banner enrichment — JSONB-extracted from `design_json`
    /// after the lightweight summary lands. Backed by the process-wide
    /// `ProfileBackgroundStore` so explore-list remounts (tab swap,
    /// drill-and-back) read fragments the previous mount already
    /// paid for. Reading the singleton directly means SwiftUI's
    /// `@Observable` tracking re-renders cards as fragments land.
    private var backgroundStore: ProfileBackgroundStore { ProfileBackgroundStore.shared }
    /// Debounce token for the search field — re-fired on every
    /// keystroke and cancelled before re-arming so 'amelia' only
    /// hits the network once.
    @State private var searchTask: Task<Void, Never>?
    /// True after the first `.task`-driven load completes. Lets the
    /// `.onAppear` hook below skip the redundant fetch on first
    /// paint (`.onAppear` fires before `.task`) and only refresh on
    /// subsequent re-appears — i.e. when the user comes back to the
    /// tab after publishing from Build, so their new card lands on
    /// screen without requiring a manual pull-to-refresh.
    @State private var hasInitiallyLoaded: Bool = false
    /// Hero avatar URL of the signed-in user, surfaced inside
    /// `ownProfilePuck`. Mirrors the pattern in `PostFeedView`: fetched
    /// from the published profile's `design_json` so the puck shows the
    /// user's actual hero avatar instead of the rose fallback. Refreshed
    /// on first load, tab re-entry, account swap, and the
    /// `cucuProfileAvatarDidChange` broadcast that `PublishSheet` fires
    /// after a successful publish.
    @State private var ownAvatarURL: String?
    /// Username the user just tapped on a feed card. Drives a
    /// programmatic push via `.navigationDestination(item:)` —
    /// `NavigationLink { … } label: { card }` was failing to fire on
    /// iOS 17/18 inside the LazyVStack/ZStack composition we ended up
    /// with (the custom `.buttonStyle` + nested overlays competed for
    /// the link's gesture). A plain `Button` setting state and a
    /// destination bound to that state is bulletproof — the tap
    /// gesture is owned by SwiftUI's standard Button, and the push
    /// happens reactively when the binding flips.
    @State private var pushTarget: ProfileNavTarget?
    /// Process-wide app-chrome theme. Drives the page bg, navigation
    /// chrome, and on-page text colour so a tap on the picker tile
    /// re-paints the explore page in lock-step with the feed.
    @State private var chrome = AppChromeStore.shared
    /// Drives the paper-stock picker sheet. Hosted here (and on the
    /// feed) so users have an entry point from each social tab — no
    /// need to drill into a settings page.
    @State private var showThemePicker: Bool = false
    /// Profile summary the long-press sneak-peek overlay is currently
    /// showing. `nil` while no peek is up — the overlay is only
    /// rendered when this is non-nil. Set in the per-row long-press
    /// gesture, cleared by the overlay's dismiss / open callbacks.
    @State private var peekTarget: PublishedProfileSummary?

    /// Hashable + Identifiable wrapper around a username so
    /// `.navigationDestination(item:)` can drive the push. Plain
    /// `String` works for `Hashable` but not `Identifiable`, and using
    /// a wrapper also documents intent.
    private struct ProfileNavTarget: Hashable, Identifiable {
        let username: String
        var id: String { username }
    }

    private enum Status: Equatable {
        case loading
        case loaded
        case emptyFeed
        case emptySearch
        case error(String)
    }

    /// Two primary sub-filters surfaced under the category row.
    /// Suggested/Recents map onto the existing Hottest/Latest service
    /// calls.
    ///
    /// **Online removed.** The previous Online segment was a
    /// placeholder for a presence channel we never shipped — it
    /// surfaced an empty state with copy promising a future
    /// feature, which read as broken to first-time users. Per the
    /// "no more social-graph features" sprint constraint we drop
    /// the segment entirely; presence can ship later as its own
    /// project alongside any backend it actually needs.
    private enum FeedMode: String, CaseIterable, Identifiable {
        case suggested = "Top this week"
        case recents = "Freshly published"

        var id: String { rawValue }
    }

    private var visibleProfiles: [PublishedProfileSummary] {
        profiles.filter { !dismissed.contains($0.id) }
    }

    /// True for the very first feed load (or a feed-mode swap that
    /// emptied the column). Distinguishing this from "loading more"
    /// or "refreshing" lets us swap in skeletons only when there's
    /// nothing to show; subsequent refreshes keep the prior data on
    /// screen + the spinner-in-toolbar surface that `.refreshable`
    /// already manages.
    private var isInitialLoading: Bool {
        status == .loading && profiles.isEmpty
    }

    var body: some View {
        ZStack {
            chrome.theme.pageColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.32), value: chrome.theme.id)
            content
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showThemePicker = true
                } label: {
                    Image(systemName: "circle.lefthalf.filled.righthalf.striped.horizontal")
                        .foregroundStyle(chrome.theme.inkPrimary)
                }
                .accessibilityLabel("Change theme")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ownProfilePuck
            }
        }
        .cucuRefinedNav("Finds")
        .tint(chrome.theme.inkPrimary)
        .sheet(isPresented: $showThemePicker) {
            AppChromeThemeSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(rawQuery: newValue)
        }
        .onChange(of: feedMode) { _, _ in
            Task { await initialLoad() }
        }
        .onChange(of: category) { _, _ in
            // Category swap re-runs the initial-load path so the
            // visible feed lines up with the active vibe. Search
            // queries take precedence — if a query is active the
            // category filter is folded in by `runSearch` /
            // `loadMore` once we add it; in v1 search is global
            // across vibes.
            Task { await initialLoad() }
        }
        .refreshable {
            // User-initiated refresh bypasses the 60s snapshot cache
            // so the wire result is canonical regardless of the
            // last automatic load.
            await ExploreListCache.shared.invalidateAll()
            await initialLoad()
        }
        .task {
            // First-paint load. Guarded so subsequent `.task` fires
            // (e.g. from a SwiftData refresh, view-tree churn) don't
            // double-fetch — `.onAppear` below owns the
            // tab-re-entry refresh.
            if !hasInitiallyLoaded {
                await initialLoad()
                await loadTopPicks()
                await loadOwnAvatar()
                hasInitiallyLoaded = true
            }
        }
        .onAppear {
            // Tab re-entry refresh. `.onAppear` fires before
            // `.task` on first paint, so the `hasInitiallyLoaded`
            // guard skips the redundant fetch then. On every
            // re-appear after that (user goes Explore → Build →
            // publishes → Explore), this picks up their fresh row
            // without requiring a manual pull-to-refresh.
            if hasInitiallyLoaded {
                Task {
                    await initialLoad()
                    await loadTopPicks()
                    await loadOwnAvatar()
                }
            }
        }
        // Re-pull the feed when the signed-in account changes
        // (sign-out → sign-in, or sign-up + claim) so a brand-new
        // user's card lands on the page without requiring a manual
        // pull-to-refresh.
        .onChange(of: auth.currentUser?.id) { _, _ in
            ownAvatarURL = nil
            Task {
                await initialLoad()
                await loadTopPicks()
                await loadOwnAvatar()
            }
        }
        // Hero avatar broadcast — `PublishSheet` fires this after a
        // successful publish. Refresh the puck so the user sees their
        // new avatar without leaving the tab.
        .onReceive(
            NotificationCenter.default.publisher(for: .cucuProfileAvatarDidChange)
        ) { notification in
            guard let username = CucuProfileEvents.avatarUsername(from: notification),
                  username == canonicalSelfUsername else {
                return
            }
            Task { await refreshOwnAvatar() }
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
        // Programmatic push for feed cards + Top picks. The destination
        // resets `pushTarget` to nil on dismiss automatically (binding
        // round-trip), so re-tapping the same card re-pushes cleanly.
        .navigationDestination(item: $pushTarget) { target in
            PublishedProfileView(username: target.username)
        }
        // Long-press sneak peek. Sits above the scroll view + the
        // toolbar so the sticker can dim the entire surface without
        // having to thread a ZStack down into every layout slot.
        // The overlay self-handles its entrance/dismiss animation;
        // we only mount/unmount when `peekTarget` flips.
        .overlay {
            if let target = peekTarget {
                ProfilePeekOverlay(
                    profile: target,
                    backgroundImageURL: backgroundStore.fragment(for: target.id)?.backgroundImageURL,
                    backgroundHex: backgroundStore.fragment(for: target.id)?.backgroundHex,
                    avatarImageURL: backgroundStore.fragment(for: target.id)?.heroAvatarURL,
                    isOwn: isOwn(profile: target),
                    onOpen: {
                        // Stage: clear the peek first (lets its own
                        // dismiss animation finish), then push.
                        // Pushing while the overlay is still mounted
                        // would put the new view *under* the dimmed
                        // backdrop on devices with slow nav-stack
                        // commits.
                        let username = target.username
                        peekTarget = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            pushTarget = ProfileNavTarget(username: username)
                        }
                    },
                    onDismiss: {
                        peekTarget = nil
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: peekTarget?.id)
    }

    // MARK: - Top-level layout

    @ViewBuilder
    private var content: some View {
        // Wrap the state-dependent body in an animation so the
        // skeleton-to-data swap reads as a fade rather than a
        // hard cut. `.animation(_:value:)` here listens to both
        // status and a derived "have-cards" flag so the transition
        // also fires when an empty/search-error state resolves.
        Group {
            switch status {
            case .loading where profiles.isEmpty:
                scrollableShell {
                    loadingState
                        .transition(.opacity)
                }
            case .loaded, .loading:
                scrollableShell {
                    feedBody
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            case .emptyFeed:
                scrollableShell {
                    emptyState(title: emptyFeedTitle, subtitle: emptyFeedSubtitle)
                }
            case .emptySearch:
                scrollableShell {
                    emptyState(
                        title: "No profiles match",
                        subtitle: "Try a different name or word."
                    )
                }
            case .error(let msg):
                scrollableShell { errorState(msg) }
            }
        }
        .animation(.easeInOut(duration: 0.32), value: profiles.isEmpty)
        .animation(.easeInOut(duration: 0.32), value: topPicks.isEmpty)
    }

    /// One scroll container hosts the entire page so the title /
    /// search / Top This Week / categories scroll *with* the feed.
    /// Locking the header to the top would steal vertical room on
    /// the small iPhones the rest of the app already runs on.
    private func scrollableShell<Inner: View>(@ViewBuilder content: () -> Inner) -> some View {
        ScrollView {
            LazyVStack(spacing: 18, pinnedViews: []) {
                searchField
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                topThisWeekRegion
                categoryRow
                modeSegment
                    .padding(.horizontal, 20)
                content()
                    .padding(.top, 2)
            }
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Top This Week rows the user sees during the page's three
    /// realistic states: the real carousel when picks are loaded,
    /// a skeleton carousel during the initial load (so the page's
    /// vertical rhythm stays stable while data arrives), and
    /// nothing at all when we're done loading but the carousel is
    /// empty (so a profile-search result doesn't carry a stale
    /// hero strip above it).
    @ViewBuilder
    private var topThisWeekRegion: some View {
        if feedMode == .suggested && query.isEmpty {
            if !topPicks.isEmpty {
                topThisWeekSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isInitialLoading {
                topThisWeekSkeletonSection
                    .transition(.opacity)
            }
        }
    }

    /// Skeleton sibling of `topThisWeekSection`. Same header,
    /// same horizontal scroll, same tile geometry — the visual
    /// difference is the shimmering placeholder fill instead of
    /// the user's banner art. Picks count is fixed at four so the
    /// carousel feels populated without committing to a specific
    /// page count.
    private var topThisWeekSkeletonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top styles this week")
                .font(.cucuSerif(20, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        TopPickTileSkeleton()
                    }
                }
                .padding(.horizontal, 20)
            }
            .disabled(true)
        }
    }

    // MARK: - Avatar puck (trailing toolbar)

    /// Trailing avatar puck that doubles as a one-tap route to the
    /// signed-in user's own published profile. Without this, finding
    /// "your card" in a busy feed of look-alike templates is genuinely
    /// hard — two profiles started from the same template render
    /// nearly-identical banners. The puck is the unambiguous "this is
    /// you" affordance.
    @ViewBuilder
    private var ownProfilePuck: some View {
        let myUsername = auth.currentUser?.username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if !myUsername.isEmpty {
            Button {
                pushTarget = ProfileNavTarget(username: myUsername)
            } label: {
                puckChrome
            }
            .buttonStyle(CucuPressableButtonStyle())
            .accessibilityLabel("Your profile")
        } else {
            puckChrome
        }
    }

    @ViewBuilder
    private var puckChrome: some View {
        if let urlString = ownAvatarURL,
           let url = CucuImageTransform.resized(urlString, square: 38) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                puckFallback
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(chrome.theme.inkPrimary.opacity(0.22), lineWidth: 1)
            )
        } else {
            puckFallback
        }
    }

    private var puckFallback: some View {
        Circle()
            .fill(Color.cucuRose)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.cucuBurgundy)
            )
            .frame(width: 38, height: 38)
            .overlay(
                Circle().strokeBorder(chrome.theme.inkPrimary.opacity(0.22), lineWidth: 1)
            )
    }

    /// Lowercased signed-in username, or empty string when signed
    /// out. Centralised so the explore card's `isOwn` derivation
    /// stays in lock-step with the puck's destination — same
    /// normalization (whitespace + lowercase) as the SQL query that
    /// PublishedProfileView's fetch will run.
    private var canonicalSelfUsername: String {
        auth.currentUser?.username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    /// True when the row's username matches the signed-in user's
    /// claimed username (case-insensitive). Used to flag the user's
    /// own card with the "You" badge so they can pick it out of a
    /// feed of similar-looking templates without parsing every
    /// `@handle`.
    private func isOwn(profile: PublishedProfileSummary) -> Bool {
        let me = canonicalSelfUsername
        guard !me.isEmpty else { return false }
        return profile.username.lowercased() == me
    }

    // MARK: - Search

    /// Refined search field. Drops the cream `cucuCardSoft` fill in
    /// favour of a quiet step over the page (one notch of the chrome's
    /// ink against the page), so the field reads as a recess in the
    /// paper rather than a separate surface. Theme-aware: dark themes
    /// get a faint highlight; light themes get a faint shadow.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(chrome.theme.inkFaded)
            TextField("Browse Profiles", text: $query)
                .font(.cucuSans(15, weight: .regular))
                .foregroundStyle(chrome.theme.inkPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Capsule().fill(searchFill)
        )
    }

    /// Subtle ink-against-page recess. Matches the refined pill
    /// button's fill so the search and the primary action read as
    /// the same surface family.
    private var searchFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }

    // MARK: - Top This Week

    private var topThisWeekSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top styles this week")
                .font(.cucuSans(15, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(topPicks.prefix(8)) { pick in
                        Button {
                            pushTarget = ProfileNavTarget(username: pick.username)
                        } label: {
                            TopPickTile(
                                profile: pick,
                                backgroundImageURLOverride: backgroundStore.fragment(for: pick.id)?.backgroundImageURL,
                                backgroundHexOverride: backgroundStore.fragment(for: pick.id)?.backgroundHex
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CucuPressableButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Categories

    /// Refined category strip. Drops the trailing chevron-down
    /// circle (the horizontal scroll already implies "more past the
    /// edge"). Active label rides in the chrome's primary ink with
    /// a 2pt underline; inactive labels stay in faded ink. Cleaner
    /// rhythm than the previous bold-vs-semibold weight swap.
    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 22) {
                // Leading "All" pill — represents the absence of a
                // category constraint. Old rows that never got a
                // vibe stamp surface here, same as before.
                categoryPill(label: "All", isSelected: category == nil) {
                    category = nil
                }
                ForEach(ProfileVibe.allCases) { vibe in
                    categoryPill(label: vibe.label, isSelected: category == vibe) {
                        category = vibe
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    private func categoryPill(label: String,
                              isSelected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(label)
                    .font(.cucuSans(15, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? chrome.theme.inkPrimary : chrome.theme.inkFaded)
                Rectangle()
                    .fill(isSelected ? chrome.theme.inkPrimary : Color.clear)
                    .frame(height: 2)
                    .frame(width: isSelected ? 24 : 0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: category)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mode segment

    /// Refined mode segment — three underline tabs matching the
    /// category strip's idiom. Active label rides in the chrome's
    /// primary ink with a 2pt underline; inactive in faded ink.
    /// Drops the cream-pill / ink-pill swap that fought the refined
    /// chrome's flat aesthetic.
    private var modeSegment: some View {
        HStack(spacing: 22) {
            ForEach(FeedMode.allCases) { mode in
                Button {
                    feedMode = mode
                } label: {
                    VStack(spacing: 6) {
                        Text(mode.rawValue)
                            .font(.cucuSans(15, weight: mode == feedMode ? .bold : .regular))
                            .foregroundStyle(mode == feedMode ? chrome.theme.inkPrimary : chrome.theme.inkFaded)
                        Rectangle()
                            .fill(mode == feedMode ? chrome.theme.inkPrimary : Color.clear)
                            .frame(height: 2)
                            .frame(width: mode == feedMode ? 24 : 0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: feedMode)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Feed body

    @ViewBuilder
    private var feedBody: some View {
        if visibleProfiles.isEmpty && status == .loaded {
            emptyState(
                title: emptyFeedTitle,
                subtitle: emptyFeedSubtitle
            )
        } else {
            VStack(spacing: 12) {
                ForEach(visibleProfiles) { profile in
                    // Plain Button + programmatic push, ZStack layers
                    // the dismiss "X" on top as a sibling. The push is
                    // driven by `pushTarget` flipping; SwiftUI handles
                    // the navigation reactively. NavigationLink with a
                    // custom buttonStyle inside this LazyVStack was
                    // unreliably consuming taps on iOS 17/18 — this
                    // pattern routes the gesture through a vanilla
                    // Button, which is rock-solid.
                    ZStack(alignment: .topTrailing) {
                        Button {
                            // The long-press recognizer below races
                            // with this tap. When a long-press wins,
                            // it sets `peekTarget` and the user
                            // expects the tap *not* to also push —
                            // guard accordingly so a held card opens
                            // the peek without immediately also
                            // navigating.
                            guard peekTarget == nil else { return }
                            pushTarget = ProfileNavTarget(username: profile.username)
                        } label: {
                            PreviewBannerCard(
                                profile: profile,
                                backgroundImageURLOverride: backgroundStore.fragment(for: profile.id)?.backgroundImageURL,
                                backgroundHexOverride: backgroundStore.fragment(for: profile.id)?.backgroundHex,
                                avatarImageURLOverride: backgroundStore.fragment(for: profile.id)?.heroAvatarURL,
                                isOwn: isOwn(profile: profile)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CucuPressableButtonStyle())
                        // Hold-to-peek. Wired as a `simultaneousGesture`
                        // because SwiftUI's `Button` owns its own tap
                        // recognizer and a plain `.onLongPressGesture`
                        // modifier never gets the press — the Button
                        // consumes it first. With `simultaneousGesture`
                        // both recognizers run; if the user holds long
                        // enough the long-press fires the peek, if
                        // they release early the Button's tap fires
                        // the push (gated by the `peekTarget == nil`
                        // check above so a hold doesn't double-fire).
                        // 0.32s gives the user time to realize a press
                        // is in flight without making the gesture
                        // feel sluggish.
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.32, maximumDistance: 16)
                                .onEnded { _ in
                                    CucuHaptics.soft()
                                    peekTarget = profile
                                }
                        )

                        Button {
                            dismiss(profile)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide \(profile.username)")
                    }
                    .onAppear { maybeLoadMore(triggeredBy: profile) }
                }

                if isLoadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(chrome.theme.inkMuted)
                        Text("loading more…")
                            .font(.cucuSans(13, weight: .regular))
                            .foregroundStyle(chrome.theme.inkFaded)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if !canLoadMore && !visibleProfiles.isEmpty {
                    Text("End of feed")
                        .font(.cucuSans(13, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - State surfaces

    /// First-paint loading state. Skeleton column instead of a
    /// centered ProgressView — the user sees the page's structure
    /// immediately and the cards fill in over their own
    /// placeholders, which feels noticeably more premium than a
    /// blank backdrop with a spinner. Five rows cover the visible
    /// viewport on every iPhone we ship to without scrolling.
    private var loadingState: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                BannerCardSkeleton()
            }
        }
        .padding(.horizontal, 20)
        .accessibilityLabel("Loading the feed")
        .accessibilityHidden(false)
    }

    /// Refined empty state — drops the ✦ glyph and the
    /// Lexend-bold-with-italic-subtitle stack in favour of a quiet
    /// title-and-subtitle pair sized to match the section labels
    /// elsewhere on the page.
    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.cucuSans(17, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(subtitle)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// Refined error state — drops the cherry triangle in favour of
    /// a flat title + message + refined pill button. Reads as a
    /// recoverable hiccup rather than a system alert.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Couldn't load the feed")
                .font(.cucuSans(17, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(message)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            CucuRefinedPillButton("Try again") {
                Task { await initialLoad() }
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var emptyFeedTitle: String {
        if let category {
            return "No \(category.label) profiles yet"
        }
        switch feedMode {
        case .suggested: return "Find your next vibe"
        case .recents:   return "Nothing published yet"
        }
    }

    private var emptyFeedSubtitle: String {
        if category != nil {
            return "Try another vibe, or publish your own and tag it for others to discover."
        }
        switch feedMode {
        case .suggested: return "Top styles will surface here once published profiles catch a wave."
        case .recents:   return "Be the first — publish a draft and it'll show up here."
        }
    }

    // MARK: - Actions

    private func dismiss(_ profile: PublishedProfileSummary) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dismissed.insert(profile.id)
        }
    }

    // MARK: - Loading

    private func initialLoad() async {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await runSearch(trimmed)
            return
        }
        if profiles.isEmpty { status = .loading }
        do {
            let next: [PublishedProfileSummary]
            let categoryRaw = category?.rawValue
            switch feedMode {
            case .suggested:
                next = try await PublishedProfileService().fetchHottest(offset: 0, category: categoryRaw)
                canLoadMore = next.count >= PublishedProfileService.listPageSize
            case .recents:
                next = try await PublishedProfileService().fetchLatest(category: categoryRaw)
                canLoadMore = next.count >= PublishedProfileService.listPageSize
            }
            profiles = next
            isLoadingMore = false
            status = next.isEmpty ? .emptyFeed : .loaded
            await enrichBackgrounds(for: next)
        } catch let err as PublishedProfileError {
            status = .error(err.errorDescription ?? "Something went wrong.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Top-row carousel data. Always pulls Hottest, regardless of
    /// the active feed mode, so a user on Recents still gets to see
    /// the week's surfacing picks above the column. Failures here
    /// are silent — the carousel hides itself when `topPicks` is
    /// empty, which is the right surface for a non-blocking error.
    private func loadTopPicks() async {
        do {
            let picks = try await PublishedProfileService().fetchHottest()
            topPicks = picks
            await enrichBackgrounds(for: picks)
        } catch {
            topPicks = []
        }
    }

    /// First-paint avatar lookup for the masthead puck. Skips the
    /// fetch if we already have a cached URL — the broadcast hook
    /// owns invalidation when the user republishes with a new hero
    /// avatar.
    private func loadOwnAvatar() async {
        let key = canonicalSelfUsername
        guard !key.isEmpty, ownAvatarURL == nil else { return }
        do {
            let map = try await PublishedProfileService()
                .fetchAvatars(forUsernames: [key])
            if let url = map[key], !url.isEmpty {
                ownAvatarURL = url
            }
        } catch {
            // Silent — the rose puck fallback covers the gap.
        }
    }

    /// Force-refresh after a publish broadcast. Drops the stale URL
    /// before the network call so the puck flips back to the
    /// fallback during the brief in-flight window rather than
    /// continuing to render the previous avatar.
    private func refreshOwnAvatar() async {
        let key = canonicalSelfUsername
        guard !key.isEmpty else {
            ownAvatarURL = nil
            return
        }
        ownAvatarURL = nil
        do {
            let map = try await PublishedProfileService()
                .fetchAvatars(forUsernames: [key])
            if let url = map[key], !url.isEmpty {
                ownAvatarURL = url
            }
        } catch {
            // Silent — fallback is correct until the next refresh lands.
        }
    }

    /// Thin wrapper that delegates to `ProfileBackgroundStore.shared`.
    /// Kept here for the call-site readability — the four existing
    /// `enrichBackgrounds(for:)` invocations in this file describe
    /// *when* enrichment fires (post-fetch, post-pagination, post-
    /// search) and the indirection makes that explicit. The store
    /// itself dedupes ids that are already cached.
    private func enrichBackgrounds(for batch: [PublishedProfileSummary]) async {
        await backgroundStore.enrich(profiles: batch)
    }

    /// Triggered by the last visible row appearing. Bails on the
    /// Online placeholder (no data path) or when the previous page
    /// didn't fill the requested limit. Recents uses cursor-based
    /// pagination; Suggested + active search use offset pagination
    /// against `.range(from:to:)` server-side.
    private func maybeLoadMore(triggeredBy profile: PublishedProfileSummary) {
        guard canLoadMore, !isLoadingMore else { return }
        guard let last = profiles.last, last.id == profile.id else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = !trimmed.isEmpty
        // Snapshot mode + count up-front so a mid-flight feedMode /
        // query swap can't blend pages from two different sources.
        let mode = feedMode
        let offset = profiles.count
        let categoryRaw = category?.rawValue
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next: [PublishedProfileSummary]
            if isSearch {
                next = try await PublishedProfileService().search(query: trimmed, offset: offset)
            } else {
                switch mode {
                case .suggested:
                    next = try await PublishedProfileService().fetchHottest(offset: offset, category: categoryRaw)
                case .recents:
                    guard let cursor = profiles.last?.sortDate else { return }
                    next = try await PublishedProfileService().fetchLatest(before: cursor, category: categoryRaw)
                }
            }
            // Bail if the user changed modes / typed a new query while
            // this page was in flight — appending stale rows would
            // corrupt the visible feed.
            guard mode == feedMode,
                  isSearch == !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            // Filter duplicates defensively. Cursor pagination can
            // re-include the boundary row when timestamps tie; offset
            // pagination on Hottest can re-include rows whose
            // `hot_score` shifted between page fetches.
            let existing = Set(profiles.map(\.id))
            let fresh = next.filter { !existing.contains($0.id) }
            profiles.append(contentsOf: fresh)
            canLoadMore = next.count >= PublishedProfileService.listPageSize
            await enrichBackgrounds(for: fresh)
        } catch {
            // Don't crash the feed on a pagination error; just stop
            // trying to load more. The user can pull-to-refresh to
            // retry the whole feed.
            canLoadMore = false
        }
    }

    // MARK: - Search

    private func scheduleSearch(rawQuery: String) {
        searchTask?.cancel()
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Restore the unfiltered feed.
            Task { await initialLoad() }
            return
        }
        searchTask = Task {
            // 280ms debounce — long enough that a user typing a name
            // doesn't hammer the network on every keystroke, short
            // enough that the results feel live.
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ trimmed: String) async {
        status = .loading
        do {
            let results = try await PublishedProfileService().search(query: trimmed, offset: 0)
            profiles = results
            canLoadMore = results.count >= PublishedProfileService.listPageSize
            isLoadingMore = false
            status = results.isEmpty ? .emptySearch : .loaded
            await enrichBackgrounds(for: results)
        } catch let err as PublishedProfileError {
            status = .error(err.errorDescription ?? "Search failed.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}

// MARK: - Top pick tile

/// Horizontal-scroll banner used in the Top This Week carousel.
/// Smaller than the column card — 200×80, with the user's display
/// name on a darker bottom band so it scans as a thumbnail rather
/// than a full read.
private struct TopPickTile: View {
    let profile: PublishedProfileSummary
    var backgroundImageURLOverride: String? = nil
    var backgroundHexOverride: String? = nil

    private var metadata: PublishedProfileCardMetadata? { profile.cardMetadata }

    private var resolvedBackgroundImageURL: String? {
        if let url = backgroundImageURLOverride, !url.isEmpty { return url }
        return metadata?.backgroundImageURL
    }

    private var resolvedBackgroundHex: String? {
        if let hex = backgroundHexOverride, !hex.isEmpty { return hex }
        return metadata?.backgroundHex
    }

    var body: some View {
        // Same layout pattern as `PreviewBannerCard.bannerSurface`:
        // text drives the frame, the bg image and gradient sit
        // behind it as `.background { … }` modifiers so the image's
        // intrinsic aspect ratio doesn't push the typography out of
        // the 96pt visible band.
        textOverlay
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .frame(width: 196, height: 96)
            .background { gradientOverlay }
            .background { backgroundLayer }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.cucuInk.opacity(0.10), radius: 4, x: 0, y: 2)
    }

    /// Display name + handle stacked at the bottom-left of the
    /// tile. Two lines so the carousel reads like the reference
    /// (display name on top, the @handle directly below) instead
    /// of a single inline string.
    private var textOverlay: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(displayName)
                    .font(displayNameFont)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if metadata?.displayNameFontKey?.isEmpty == false {
                    // Sparkle ornament only for users who set a
                    // distinct hero font — same visual move the
                    // reference uses to lift "EJ ✦ PAGUNTALAN" above
                    // the rest of the carousel.
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            Text("@\(profile.username)")
                .font(.cucuSans(10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 0.5)
    }

    /// Bottom-heavy gradient identical in shape to the column
    /// banner card but slightly tighter — the tile is shorter and
    /// the type lives a little closer to the bottom edge.
    private var gradientOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.10), location: 0.0),
                .init(color: Color.black.opacity(0.45), location: 0.55),
                .init(color: Color.black.opacity(0.85), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        // Tile is 196×96; render through Supabase's image transform
        // so a megapixel hero photo doesn't get pulled down just to
        // be downsampled into a thumbnail-size carousel cell.
        if let urlString = resolvedBackgroundImageURL,
           let url = CucuImageTransform.resized(urlString, width: 196, height: 96) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                seedGradient
            }
        } else if let hex = resolvedBackgroundHex, !hex.isEmpty {
            Color(hex: hex)
        } else {
            seedGradient
        }
    }

    private var displayName: String {
        if let n = metadata?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { return n }
        return profile.username.prefix(1).uppercased() + profile.username.dropFirst()
    }

    private var displayNameFont: Font {
        let family: NodeFontFamily
        if let key = metadata?.displayNameFontKey,
           let resolved = NodeFontFamily(rawValue: key) {
            family = resolved
        } else {
            family = .fraunces
        }
        return family.swiftUIFont(size: 16, weight: .bold)
    }

    private var seedGradient: LinearGradient {
        let palette: [(Color, Color)] = [
            (.cucuBurgundy, .cucuRose),
            (.cucuMidnight, .cucuCobalt),
            (.cucuMoss, .cucuMatcha),
            (.cucuCherry, .cucuShell),
        ]
        let hash = profile.username.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let pair = palette[abs(hash) % palette.count]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
