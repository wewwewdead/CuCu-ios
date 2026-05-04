import SwiftUI

/// Latest feed. Pull-to-refresh, infinite scroll on the last
/// visible row, compose-via-pencil in the nav bar, and tap-to-push
/// the thread view from any row.
///
/// Phase 6 generalised this from "global feed only" to a feed
/// surface parameterised by `FeedSource` — the same body powers
/// the global Latest tab and the per-user `UserPostsListView`.
/// The defaults match the original instantiation so existing call
/// sites compile unchanged.
struct PostFeedView: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var vm: PostFeedViewModel
    @State private var showCompose: Bool = false
    @State private var threadDestination: Post? = nil
    @State private var reportTarget: Post? = nil
    @State private var blockTarget: Post? = nil
    @State private var toastMessage: String? = nil
    /// Author-username → hero-avatar URL map. Filled by an
    /// enrichment pass that runs after the post page lands so the
    /// row's avatar can swap from the bookplate letter to the
    /// author's real published-profile photo. Authors who haven't
    /// published a profile (or didn't set a hero avatar) are simply
    /// absent from the dictionary; the row keeps its letter
    /// fallback. Keyed lowercased to match the SQL normalization.
    @State private var avatarOverrides: [String: String] = [:]
    /// Usernames that have appeared on screen since the last
    /// debounce tick fired, minus those already cached. Drains
    /// into a single batch fetch via `requestAvatarLazy`.
    @State private var pendingAvatarUsernames: Set<String> = []
    /// Leading-edge gate so a stream of `.onAppear`s during a
    /// scroll burst only spawns one debounce task at a time.
    @State private var avatarBatchInFlight: Bool = false

    private let title: String
    private let showsCompose: Bool

    init(
        feedSource: PostFeedViewModel.FeedSource = .global,
        title: String = "Feed",
        showsCompose: Bool = true
    ) {
        _vm = State(initialValue: PostFeedViewModel(feedSource: feedSource))
        self.title = title
        self.showsCompose = showsCompose
    }

    var body: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    masthead
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    stateContent
                }
                .padding(.bottom, 32)
            }
            .refreshable {
                // Visible rows after refresh will pull their own
                // avatars through the lazy `.onAppear` path.
                await vm.refresh()
            }
        }
        .navigationTitle(displayTitle)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.cucuPaper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            if showsCompose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(Color.cucuInk)
                    }
                    .accessibilityLabel("Compose post")
                }
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposePostSheet(parentId: nil) { post in
                // Prepended row will fire its own `.onAppear` and
                // pull its author's avatar through the lazy path.
                vm.prepend(post)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $reportTarget) { post in
            ReportPostSheet(post: post) { outcome in
                handleReportOutcome(outcome)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            blockDialogTitle,
            isPresented: Binding(
                get: { blockTarget != nil },
                set: { if !$0 { blockTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: blockTarget
        ) { post in
            Button("Block", role: .destructive) {
                CucuHaptics.delete()
                Task { await handleBlock(post) }
            }
            Button("Cancel", role: .cancel) { blockTarget = nil }
        } message: { post in
            Text("You won't see @\(post.authorUsername)'s posts or replies.")
        }
        .navigationDestination(item: $threadDestination) { post in
            PostThreadView(rootId: post.rootId ?? post.id)
        }
        .cucuToast(message: $toastMessage)
        .task {
            await vm.initialLoad()
            // Visible rows pull their own avatars lazily via
            // `.onAppear`. The masthead puck is the one
            // exception: it points at the *signed-in viewer*,
            // who almost never has a post on the global feed's
            // first page, so its avatar wouldn't be triggered by
            // any row appearing — fetch it directly so the puck
            // paints with the right photo.
            if let me = auth.currentUser?.username, !me.isEmpty {
                await fetchSignedInAvatar(username: me)
            }
        }
    }

    private var blockDialogTitle: String {
        if let target = blockTarget {
            return "Block @\(target.authorUsername)?"
        }
        return "Block user?"
    }

    // MARK: - Masthead
    //
    // Borrows Explore's title-row idiom: large editorial display
    // title on the leading edge, a small trailing avatar puck for
    // the signed-in user. Underneath sits a tracked mono spec line
    // (date for the global feed, "JOURNAL" / "POSTS" for per-user)
    // and a Fraunces-italic subtitle, closed off with a 1pt ink
    // hairline. Scrolls with the content rather than pinning, so
    // the page reads as a magazine spread that gives the feed its
    // own opening real estate.

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            Text(specLine)
                .font(.cucuMono(10, weight: .medium))
                .tracking(2.4)
                .foregroundStyle(Color.cucuInkFaded)
                .padding(.top, 2)
            Text(mastheadSubtitle)
                .font(.cucuEditorial(14, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .padding(.bottom, 12)
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Title row matches Explore's: 34pt serif bold display title
    /// on the leading edge, a 38pt avatar puck on the trailing
    /// edge. The puck shows the signed-in user's hero avatar when
    /// available; otherwise a person glyph in the rose palette.
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(displayTitle)
                .font(.cucuSerif(34, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            mastheadAvatarPuck
        }
    }

    @ViewBuilder
    private var mastheadAvatarPuck: some View {
        let myUsername = auth.currentUser?.username?.lowercased() ?? ""
        if !myUsername.isEmpty,
           let urlString = avatarOverrides[myUsername],
           !urlString.isEmpty,
           let url = URL(string: urlString) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                avatarPuckFallback
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
            )
        } else {
            avatarPuckFallback
        }
    }

    private var avatarPuckFallback: some View {
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

    private var displayTitle: String {
        switch vm.feedSource {
        case .global: return "Feed"
        case .byAuthor: return title
        }
    }

    private var specLine: String {
        switch vm.feedSource {
        case .global:
            let f = DateFormatter()
            f.dateFormat = "MMMM · yyyy"
            return f.string(from: Date()).uppercased()
        case .byAuthor:
            return showsCompose ? "JOURNAL" : "POSTS"
        }
    }

    private var mastheadSubtitle: String {
        switch vm.feedSource {
        case .global:
            return "Latest entries from the community."
        case .byAuthor:
            return showsCompose
                ? "Everything you've shared, oldest first to most recent."
                : "Their entries, in the order they were written."
        }
    }

    // MARK: - State content

    @ViewBuilder
    private var stateContent: some View {
        switch vm.status {
        case .loading where vm.posts.isEmpty:
            skeletonColumn
        case .empty:
            emptyState
        case .error(let message):
            errorState(message)
        case .loading, .loaded:
            feedColumn
        }
    }

    // MARK: - Column

    private var feedColumn: some View {
        LazyVStack(spacing: 10) {
            ForEach(vm.posts) { post in
                PostRowView(
                    post: post,
                    style: .full,
                    viewerHasLiked: vm.viewerLikedIds.contains(post.id),
                    isOwnPost: post.authorId == auth.currentUser?.id.lowercased(),
                    avatarURL: avatarOverrides[post.authorUsername.lowercased()],
                    onTap: { threadDestination = post },
                    onLike: { vm.toggleLike(postId: post.id) },
                    onReply: { threadDestination = post },
                    onDelete: { handleDelete(post) },
                    onReport: { reportTarget = post },
                    onBlock: { blockTarget = post }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
                .onAppear {
                    requestAvatarLazy(for: post.authorUsername)
                    if post.id == vm.posts.last?.id {
                        // Newly-paginated rows will lazy-load
                        // their own avatars as they enter view.
                        Task { await vm.loadMore() }
                    }
                }
            }
            if vm.isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.cucuInkSoft)
                    Text("loading more entries…")
                        .font(.cucuEditorial(12, italic: true))
                        .foregroundStyle(Color.cucuInkFaded)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if !vm.posts.isEmpty && !vm.isLoadingMore {
                endOfFeed
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: vm.posts.map(\.id))
        .padding(.top, 14)
        .padding(.horizontal, 20)
    }

    /// "End of feed" closing flourish — matches the Explore page's
    /// sparkle-bracketed marker but uses the same fleuron (❦) the
    /// rest of the design system speaks. Reads as a printed
    /// colophon rather than a hard stop.
    private var endOfFeed: some View {
        Text("✦  end of the feed  ✦")
            .font(.cucuSerif(12, weight: .regular))
            .foregroundStyle(Color.cucuInkFaded)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    // MARK: - State surfaces

    /// Skeleton column — three placeholder cards that ghost the
    /// real row geometry. Pulses opacity rather than running a
    /// shimmer band, which feels more refined and less "loading
    /// gif" energy.
    private var skeletonColumn: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                FeedSkeletonCard()
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 60)
            Text("❦")
                .font(.cucuSerif(48, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text(emptyTitle)
                .font(.cucuSerif(24, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(emptySubtitle)
                .font(.cucuEditorial(15, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            if showsCompose {
                CucuChip("Write the first entry", systemImage: "square.and.pencil") {
                    showCompose = true
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    private var emptyTitle: String {
        showsCompose ? "A blank page" : "Nothing here yet"
    }

    private var emptySubtitle: String {
        showsCompose
        ? "Be the first to leave a mark — your post will sit at the top of the feed."
        : "When this user posts, their entries will appear here."
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            Text("❦")
                .font(.cucuSerif(36, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text("Couldn't reach the feed")
                .font(.cucuSerif(22, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(message)
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            CucuChip("Try again", systemImage: "arrow.clockwise") {
                Task { await vm.initialLoad() }
            }
            .padding(.top, 4)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    // MARK: - Lazy avatar enrichment

    /// Per-row entry point. Each row calls this from its
    /// `.onAppear`; we accumulate misses for a 200ms window
    /// then drain the set in a single batched PostgREST call.
    /// Cache hits short-circuit at the top so re-appearing rows
    /// (scroll-back, recycle) cost nothing.
    ///
    /// The leading-edge gate (`avatarBatchInFlight`) ensures a
    /// scroll burst that fires dozens of `.onAppear`s only
    /// spawns one debounce task — every later request just adds
    /// to the pending set. After the fetch resolves, the gate
    /// drops and any *new* requests start a fresh window.
    private func requestAvatarLazy(for username: String) {
        let key = username.lowercased()
        guard !key.isEmpty, avatarOverrides[key] == nil else { return }
        pendingAvatarUsernames.insert(key)
        guard !avatarBatchInFlight else { return }
        avatarBatchInFlight = true
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let snapshot = pendingAvatarUsernames.subtracting(Set(avatarOverrides.keys))
            pendingAvatarUsernames.removeAll()
            avatarBatchInFlight = false
            guard !snapshot.isEmpty else { return }
            do {
                let map = try await PublishedProfileService()
                    .fetchAvatars(forUsernames: Array(snapshot))
                avatarOverrides.merge(map) { _, new in new }
            } catch {
                // Silent — letter fallback covers it.
            }
        }
    }

    /// Direct masthead-puck fetch for the signed-in viewer.
    /// Bypasses the lazy debounce because the puck is on screen
    /// before any row's `.onAppear` fires, and the viewer's own
    /// post is rarely in the first page of the global feed —
    /// waiting for a row to trigger the lookup would leave the
    /// puck in fallback indefinitely.
    private func fetchSignedInAvatar(username: String) async {
        let key = username.lowercased()
        guard !key.isEmpty, avatarOverrides[key] == nil else { return }
        do {
            let map = try await PublishedProfileService()
                .fetchAvatars(forUsernames: [key])
            avatarOverrides.merge(map) { _, new in new }
        } catch {
            // Silent — rose puck fallback covers it.
        }
    }

    // MARK: - Actions

    private func handleReportOutcome(_ outcome: ReportPostSheet.Outcome) {
        switch outcome {
        case .submitted:
            toastMessage = "Reported. Thanks — we review every report."
        case .alreadyReported:
            toastMessage = "Already reported. We'll review it soon."
        case .cancelled:
            break
        }
    }

    private func handleBlock(_ post: Post) async {
        blockTarget = nil
        do {
            try await UserBlockService().block(userId: post.authorId)
            vm.removeAllByAuthor(authorId: post.authorId)
            toastMessage = "Blocked @\(post.authorUsername)"
        } catch let err as UserBlockError {
            toastMessage = err.errorDescription ?? "Couldn't block right now."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    private func handleDelete(_ post: Post) {
        let snapshotIndex = vm.posts.firstIndex(where: { $0.id == post.id })
        let snapshot = post
        CucuHaptics.delete()
        vm.removeLocally(postId: post.id)
        Task {
            do {
                try await PostService().softDelete(postId: post.id)
            } catch {
                if let idx = snapshotIndex {
                    vm.reinsert(snapshot, at: idx)
                } else {
                    vm.prepend(snapshot)
                }
            }
        }
    }
}

// MARK: - Skeleton card

/// Loading-state placeholder — ghosts the real row geometry
/// (square avatar, two-line header, three text lines, action
/// row) and gently pulses opacity. Rendering the structure
/// rather than a shimmer band keeps the page from reflowing
/// when real data lands.
///
/// Module-internal so the thread view can reuse the same
/// pulsing card geometry for its loading state — keeps the
/// two surfaces visually identical while the data lands.
struct FeedSkeletonCard: View {
    @State private var phase: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.cucuCardSoft)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(Color.cucuCardSoft)
                        .frame(width: 130, height: 11)
                    Capsule()
                        .fill(Color.cucuCardSoft)
                        .frame(width: 70, height: 8)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(Color.cucuCardSoft)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                Capsule()
                    .fill(Color.cucuCardSoft)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                Capsule()
                    .fill(Color.cucuCardSoft)
                    .frame(width: 200, height: 10)
            }
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(Color.cucuCardSoft)
                    .frame(width: 28, height: 10)
                Capsule()
                    .fill(Color.cucuCardSoft)
                    .frame(width: 28, height: 10)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cucuCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cucuInkRule, lineWidth: 1)
        )
        .opacity(phase ? 1.0 : 0.55)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}
