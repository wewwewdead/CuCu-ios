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
    @State private var profiles: [PublishedProfileSummary] = []
    @State private var topPicks: [PublishedProfileSummary] = []
    @State private var status: Status = .loading
    @State private var query: String = ""
    @State private var feedMode: FeedMode = .suggested
    @State private var category: ExploreCategory = .all
    @State private var canLoadMore: Bool = true
    @State private var isLoadingMore: Bool = false
    @State private var dismissed: Set<String> = []
    /// Lazy banner enrichment — JSONB-extracted from `design_json`
    /// after the lightweight summary lands. Keyed by `profile.id`.
    /// Until the row's enrichment arrives, the card's seed gradient
    /// covers the gap; once it lands, SwiftUI re-renders only that
    /// card because we feed the override through the view-tree.
    @State private var backgroundOverrides: [String: PublishedProfileService.BackgroundFragment] = [:]
    /// Debounce token for the search field — re-fired on every
    /// keystroke and cancelled before re-arming so 'amelia' only
    /// hits the network once.
    @State private var searchTask: Task<Void, Never>?

    private enum Status: Equatable {
        case loading
        case loaded
        case emptyFeed
        case emptySearch
        case error(String)
    }

    /// Three primary sub-filters surfaced under the category row.
    /// Suggested/Recents map onto the existing Hottest/Latest service
    /// calls; Online renders an empty state until a presence channel
    /// exists, which is fine for now — the segment is the right
    /// hook to add it later without re-shuffling chrome.
    private enum FeedMode: String, CaseIterable, Identifiable {
        case suggested = "Suggested"
        case recents = "Recents"
        case online = "Online"

        var id: String { rawValue }
    }

    /// Local taxonomy used for the category strip. The backend has no
    /// equivalent column yet, so picks are visual-only — the active
    /// pill just changes the underline. Listed here (instead of being
    /// server-fetched) because the design needs immediate, predictable
    /// chips rather than a "loading…" placeholder above the feed.
    private enum ExploreCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case anime = "Anime"
        case aot = "AOT"
        case journaling = "Journaling"
        case kpop = "K-Pop"
        case student = "Student"
        case art = "Art"
        case music = "Music"
        case writing = "Writing"

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
            Color.cucuPaper.ignoresSafeArea()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { EmptyView() } }
        .toolbarBackground(Color.cucuPaper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(Color.cucuInk)
        .onChange(of: query) { _, newValue in
            scheduleSearch(rawQuery: newValue)
        }
        .onChange(of: feedMode) { _, _ in
            Task { await initialLoad() }
        }
        .refreshable { await initialLoad() }
        .task {
            await initialLoad()
            await loadTopPicks()
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
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
                titleRow
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                searchField
                    .padding(.horizontal, 20)
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
            Text("Top This Week")
                .font(.cucuSerif(20, weight: .bold))
                .foregroundStyle(Color.cucuInk)
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

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Finds")
                .font(.cucuSerif(34, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            // Small puck — placeholder for the signed-in user's
            // avatar. Until `AppUser` carries a thumbnail URL, this
            // reads as a friendly cucu-tinted disc instead of a
            // generic chip, and gives the title row the same
            // visual cadence as the screenshot.
            Circle()
                .fill(Color.cucuRose)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.cucuBurgundy)
                )
                .frame(width: 38, height: 38)
                .overlay(
                    Circle().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
                )
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.cucuInkFaded)
            TextField("Browse Profiles", text: $query)
                .font(.cucuSans(15, weight: .regular))
                .foregroundStyle(Color.cucuInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Capsule().fill(Color.cucuCardSoft)
        )
        .overlay(
            Capsule().strokeBorder(Color.cucuInk.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Top This Week

    private var topThisWeekSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top This Week")
                .font(.cucuSerif(20, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(topPicks.prefix(8)) { pick in
                        NavigationLink {
                            PublishedProfileView(username: pick.username)
                        } label: {
                            TopPickTile(
                                profile: pick,
                                backgroundImageURLOverride: backgroundOverrides[pick.id]?.backgroundImageURL,
                                backgroundHexOverride: backgroundOverrides[pick.id]?.backgroundHex
                            )
                        }
                        .buttonStyle(CucuPressableButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Categories

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 18) {
                ForEach(ExploreCategory.allCases) { cat in
                    Button {
                        category = cat
                    } label: {
                        VStack(spacing: 6) {
                            Text(cat.rawValue)
                                .font(.cucuSerif(15, weight: cat == category ? .bold : .semibold))
                                .foregroundStyle(cat == category ? Color.cucuInk : Color.cucuInkFaded)
                            Rectangle()
                                .fill(cat == category ? Color.cucuInk : Color.clear)
                                .frame(height: 2)
                                .frame(width: cat == category ? 28 : 0)
                                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: category)
                        }
                    }
                    .buttonStyle(.plain)
                }
                // Trailing chevron — visual cue that more categories
                // exist past the right edge, even though horizontal
                // scroll would already imply it.
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cucuInkFaded)
                    .padding(8)
                    .overlay(
                        Circle().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Mode segment

    private var modeSegment: some View {
        HStack(spacing: 8) {
            ForEach(FeedMode.allCases) { mode in
                Button {
                    feedMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.cucuSans(14, weight: .semibold))
                        .foregroundStyle(mode == feedMode ? Color.white : Color.cucuInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(mode == feedMode
                                           ? Color.cucuInk
                                           : Color.cucuCardSoft)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                mode == feedMode ? Color.clear : Color.cucuInk.opacity(0.12),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(CucuPressableButtonStyle())
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
                    NavigationLink {
                        PublishedProfileView(username: profile.username)
                    } label: {
                        PreviewBannerCard(
                            profile: profile,
                            backgroundImageURLOverride: backgroundOverrides[profile.id]?.backgroundImageURL,
                            backgroundHexOverride: backgroundOverrides[profile.id]?.backgroundHex,
                            avatarImageURLOverride: backgroundOverrides[profile.id]?.heroAvatarURL,
                            onDismiss: { dismiss(profile) }
                        )
                    }
                    .buttonStyle(CucuPressableButtonStyle())
                    .onAppear { maybeLoadMore(triggeredBy: profile) }
                }

                if isLoadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.cucuInkSoft)
                        Text("loading more…")
                            .font(.cucuSans(13, weight: .regular))
                            .foregroundStyle(Color.cucuInkFaded)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if !canLoadMore && !visibleProfiles.isEmpty {
                    Text("✦  end of the feed  ✦")
                        .font(.cucuSerif(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
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

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 14) {
            Text("✦")
                .font(.cucuSerif(40, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text(title)
                .font(.cucuSerif(18, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(subtitle)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.cucuCherry)
            Text("Couldn't load the feed")
                .font(.cucuSerif(17, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(message)
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await initialLoad() }
            } label: {
                Text("Try again")
                    .font(.cucuSans(15, weight: .semibold))
                    .foregroundStyle(Color.cucuCard)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.cucuInk))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var emptyFeedTitle: String {
        switch feedMode {
        case .suggested: return "No suggestions yet"
        case .recents:   return "Nothing published yet"
        case .online:    return "Online presence is coming"
        }
    }

    private var emptyFeedSubtitle: String {
        switch feedMode {
        case .suggested: return "Published profiles will surface here once they catch a wave."
        case .recents:   return "Be the first — publish a draft and it'll show up here."
        case .online:    return "We'll light this up once a live presence channel ships."
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
            switch feedMode {
            case .suggested:
                next = try await PublishedProfileService().fetchHottest()
                canLoadMore = false
            case .recents:
                next = try await PublishedProfileService().fetchLatest()
                canLoadMore = next.count >= PublishedProfileService.listPageSize
            case .online:
                // No presence backend yet — surface an empty state.
                next = []
                canLoadMore = false
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

    /// Lazy banner enrichment. Asks Postgres for just the page
    /// background fields out of `design_json` (via JSONB `->>`),
    /// keyed by id. Failures are silent — the card already has a
    /// seed-gradient fallback, so a network blip on the enrichment
    /// pass is invisible to the user. Runs after the lightweight
    /// summary lands so the feed paints immediately and banners
    /// fill in as the override resolves.
    private func enrichBackgrounds(for batch: [PublishedProfileSummary]) async {
        // Drop ids we already have — re-asking the same row on every
        // refresh would waste a roundtrip when the row hasn't changed
        // since first load.
        let needed = batch.map(\.id).filter { backgroundOverrides[$0] == nil }
        guard !needed.isEmpty else { return }
        do {
            let fragments = try await PublishedProfileService().fetchBackgrounds(for: needed)
            // Merge rather than replace so a Latest re-fetch doesn't
            // drop already-resolved Hottest overrides (and vice
            // versa). The dictionary's keyed by profile.id, so a
            // refresh of the same row is a no-op.
            backgroundOverrides.merge(fragments) { _, new in new }
        } catch {
            // Silent — the seed gradient is the fallback.
        }
    }

    /// Triggered by the last visible row appearing. Bails when search
    /// is active (those results aren't paginated by the service) or
    /// when the previous page didn't fill the requested limit (no
    /// more rows are available).
    private func maybeLoadMore(triggeredBy profile: PublishedProfileSummary) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard feedMode == .recents else { return }
        guard canLoadMore, !isLoadingMore else { return }
        guard let last = profiles.last, last.id == profile.id else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard let cursor = profiles.last?.sortDate else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await PublishedProfileService().fetchLatest(before: cursor)
            // Filter duplicates defensively — if two profiles share an
            // identical `published_at` timestamp, the cursor query
            // can re-include the boundary row.
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
            let results = try await PublishedProfileService().search(query: trimmed)
            profiles = results
            canLoadMore = false
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
        if let urlString = resolvedBackgroundImageURL,
           let url = URL(string: urlString),
           !urlString.isEmpty {
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
