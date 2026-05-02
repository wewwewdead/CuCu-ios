import SwiftUI

/// Explore feed: a single-column list of published profiles with
/// Latest/Hottest modes. Aesthetic continues the editorial-scrapbook direction
/// the rest of the editor uses — cream paper backdrop, ink-stroked
/// cream cards per profile, mono small-caps timestamps, italic-
/// serif bios, ❦ fleurons between paginated batches.
///
/// State surfaces:
///   - **loading** — initial fetch in flight (centered spinner)
///   - **loaded** — feed renders; tap a card to push the viewer
///   - **empty (feed)** — RLS allowed reads but nothing's published
///   - **empty (search)** — query has no matches
///   - **error** — Supabase / network failure (Retry button)
///
/// Pagination is cursor-based via the service: as the last visible
/// row scrolls into view, we ask for the next page using its
/// `sortDate` as a "before" cursor. The cursor approach beats
/// offset-based here because new publishes inserted at the top
/// don't shift the page window mid-scroll.
struct PublishedProfilesListView: View {
    @State private var profiles: [PublishedProfileSummary] = []
    @State private var status: Status = .loading
    @State private var query: String = ""
    @State private var feedMode: FeedMode = .latest
    @State private var canLoadMore: Bool = true
    @State private var isLoadingMore: Bool = false
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

    private enum FeedMode: String, CaseIterable, Identifiable {
        case latest = "Latest"
        case hottest = "Hottest"

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                modePicker
                content
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                principalTitle
            }
        }
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.cucuPaper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .tint(Color.cucuInk)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "search profiles"
        )
        .autocorrectionDisabled()
        #if os(iOS) || os(visionOS)
        .textInputAutocapitalization(.never)
        #endif
        .onChange(of: query) { _, newValue in
            scheduleSearch(rawQuery: newValue)
        }
        .onChange(of: feedMode) { _, _ in
            Task { await initialLoad() }
        }
        .refreshable {
            await initialLoad()
        }
        .task {
            // `.task` re-runs if `id` changes — we don't pass one, so
            // it runs exactly once per appear, the right time for the
            // initial feed fetch.
            await initialLoad()
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    // MARK: - Title

    private var principalTitle: some View {
        VStack(spacing: 1) {
            Text("explore")
                .font(.cucuSerif(20, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text("FIG. 05 · PROFILES")
                .font(.cucuMono(9, weight: .medium))
                .tracking(2)
                .foregroundStyle(Color.cucuInkFaded)
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:    loadingState
        case .loaded:     feedList
        case .emptyFeed:  emptyState(title: emptyFeedTitle, subtitle: emptyFeedSubtitle)
        case .emptySearch: emptyState(
            title: "No profiles match",
            subtitle: "Try a different name or word."
        )
        case .error(let msg): errorState(msg)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.cucuInk)
            Text("loading the feed…")
                .font(.cucuSerif(15, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Text("✦")
                .font(.cucuSerif(40, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text(title)
                .font(.cucuSerif(18, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(subtitle)
                .font(.cucuSerif(14, weight: .regular))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .font(.cucuSerif(13, weight: .regular))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await initialLoad() }
            } label: {
                Text("Try again")
                    .font(.cucuSerif(15, weight: .bold))
                    .foregroundStyle(Color.cucuCard)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.cucuInk))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modePicker: some View {
        Picker("Feed", selection: $feedMode) {
            ForEach(FeedMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var emptyFeedTitle: String {
        switch feedMode {
        case .latest: return "Nothing published yet"
        case .hottest: return "No votes yet"
        }
    }

    private var emptyFeedSubtitle: String {
        switch feedMode {
        case .latest: return "Be the first — publish a draft and it'll show up here."
        case .hottest: return "Published profiles will appear here once votes arrive."
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        ScrollView {

            LazyVStack(spacing: 14) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    NavigationLink {
                        PublishedProfileView(username: profile.username)
                    } label: {
                        ExploreProfileRow(profile: profile)
                    }
                    .buttonStyle(CucuPressableButtonStyle())
                    .onAppear {
                        maybeLoadMore(triggeredBy: profile)
                    }

                    // Sprinkle a fleuron every ten cards — gives the
                    // long-scroll view a bit of editorial cadence
                    // instead of a uniform list. Reads as "section
                    // break" without being intrusive.
                    if (index + 1) % 10 == 0, index < profiles.count - 1 {
                        CucuFleuronDivider()
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                    }
                }

                if isLoadingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.cucuInkSoft)
                        Text("loading more…")
                            .font(.cucuSerif(13, weight: .regular))
                            .foregroundStyle(Color.cucuInkFaded)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if !canLoadMore && !profiles.isEmpty {
                    Text("✦  end of the feed  ✦")
                        .font(.cucuSerif(12, weight: .regular))
                        .foregroundStyle(Color.cucuInkFaded)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
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
        status = .loading
        do {
            let next: [PublishedProfileSummary]
            switch feedMode {
            case .latest:
                next = try await PublishedProfileService().fetchLatest()
                canLoadMore = next.count >= PublishedProfileService.listPageSize
            case .hottest:
                next = try await PublishedProfileService().fetchHottest()
                canLoadMore = false
            }
            profiles = next
            isLoadingMore = false
            status = next.isEmpty ? .emptyFeed : .loaded
        } catch let err as PublishedProfileError {
            status = .error(err.errorDescription ?? "Something went wrong.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Triggered by the last visible row appearing. Bails when search
    /// is active (those results aren't paginated by the service) or
    /// when the previous page didn't fill the requested limit (no
    /// more rows are available).
    private func maybeLoadMore(triggeredBy profile: PublishedProfileSummary) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard feedMode == .latest else { return }
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
        } catch let err as PublishedProfileError {
            status = .error(err.errorDescription ?? "Search failed.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}

// MARK: - Row card

/// One profile rendered as a magazine-clipping card. Tappable as a
/// whole; the wrapping `NavigationLink` provides the press feedback.
struct ExploreProfileRow: View {
    let profile: PublishedProfileSummary

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            avatarTile
            VStack(alignment: .leading, spacing: 6) {
                Text("@\(profile.username)")
                    .font(.cucuSerif(18, weight: .bold))
                    .foregroundStyle(Color.cucuBurgundy)
                    .lineLimit(1)

                Text(timestampLabel)
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(voteCountLabel)
                    .font(.cucuMono(10, weight: .medium))
            }
            .foregroundStyle(Color.cucuCherry)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cucuInkFaded)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cucuCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1)
        )
        .shadow(color: Color.cucuInk.opacity(0.10), radius: 6, x: 0, y: 3)
    }

    // MARK: - Avatar tile
    //
    // 64×64 ink-stroked square. Three fallback paths:
    //   1. `thumbnail_url` is set + decodes → cached image fills the tile.
    //   2. `thumbnail_url` is nil → tinted plate + first letter of
    //      username in big serif italic. Tint cycles through the cucu
    //      palette by hash of the username so the same user always
    //      lands on the same color.
    //   3. Loading / failure states fall through to (2)
    //      via the `placeholder` arm.

    @ViewBuilder
    private var avatarTile: some View {
        let tint = avatarTint(for: profile.username)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint)

            if let thumbString = profile.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thumbString.isEmpty,
               CanvasImageLoader.isRemote(thumbString),
               let thumbnailURL = URL(string: thumbString) {
                CachedRemoteImage(url: thumbnailURL, contentMode: .fill) {
                    avatarInitial(tint: tint)
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                avatarInitial(tint: tint)
            }
        }
        .frame(width: 64, height: 64)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1)
        )
    }

    private func avatarInitial(tint: Color) -> some View {
        Text(initialLetter)
            .font(.cucuSerif(28, weight: .bold))
            .foregroundStyle(Color.cucuBurgundy)
    }

    private var initialLetter: String {
        guard let first = profile.username.first else { return "?" }
        return String(first).uppercased()
    }

    /// Hash-stable tint pick from the cucu palette so the same user
    /// always lands on the same color across launches.
    private func avatarTint(for username: String) -> Color {
        let palette: [Color] = [
            .cucuRose,
            .cucuMossSoft,
            .cucuShell,
            .cucuCardSoft,
        ]
        let hash = username.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    private var timestampLabel: String {
        guard let date = profile.sortDate else { return "RECENT" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: .now)
        return relative.uppercased()
    }

    private var voteCountLabel: String {
        if profile.voteCount >= 1_000 {
            return "\(profile.voteCount / 1_000)K"
        }
        return "\(profile.voteCount)"
    }
}
