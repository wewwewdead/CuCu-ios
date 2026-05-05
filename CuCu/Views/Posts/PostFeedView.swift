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
    @Environment(CucuPostFlightCoordinator.self) private var flightCoordinator
    @State private var vm: PostFeedViewModel
    /// Process-wide app-chrome theme. Reading `chrome.theme` re-renders
    /// the page on every `setTheme` because `AppChromeStore` is
    /// `@Observable` — see `Persistence/AppChromeStore.swift`.
    @State private var chrome = AppChromeStore.shared
    @State private var showCompose: Bool = false
    /// Drives the paper-stock picker sheet. Hosted at the feed level
    /// (rather than nested deep) so the sheet sits over a live page
    /// the user can preview against between taps.
    @State private var showThemePicker: Bool = false
    @State private var threadDestination: Post? = nil
    @State private var reportTarget: Post? = nil
    @State private var blockTarget: Post? = nil
    @State private var toastMessage: String? = nil
    /// Navigation push target for the author profile route. Set
    /// when the viewer taps a row's avatar or `@handle`. Wrapped
    /// in a tiny Identifiable struct because SwiftUI's
    /// `.navigationDestination(item:)` requires the bound value
    /// to be Identifiable, and a bare `String?` doesn't satisfy
    /// that without a global extension we'd rather not add.
    @State private var profileDestination: AuthorRoute? = nil
    /// Author-username → hero-avatar URL map, shared across the feed
    /// and any thread the user pushes onto the navigation stack so the
    /// same author isn't re-fetched twice when navigating between
    /// surfaces. The store owns the debounce + completed-set bookkeeping
    /// internally; views read from `overrides` and call `requestLazy`.
    private var avatarStore: AvatarOverrideStore { AvatarOverrideStore.shared }
    /// Drives the anticipation scale-up on the row about to be
    /// deleted. Held for one frame so the row visibly pops before
    /// the squish-fade transition takes it out.
    @State private var poppingPostId: String? = nil

    /// Last id that was inserted via the flight coordinator's
    /// landing. Used to gate the column's transition swap so only
    /// *that* row uses the materialise-in-place transition; every
    /// other insertion keeps the standard top-edge slide.
    @State private var lastLandedPostId: String? = nil

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
            CucuRefinedPageBackdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    flightAnchor
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
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
        .cucuRefinedNav(displayTitle)
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
            if showsCompose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(chrome.theme.inkPrimary)
                    }
                    .accessibilityLabel("Compose post")
                }
            }
        }
        .sheet(isPresented: $showThemePicker) {
            AppChromeThemeSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCompose) {
            // `usesFlight: true` hands the inserted post off to the
            // flight coordinator instead of prepending immediately.
            // The row materialises down below in
            // `onChange(of: flightCoordinator.landedPostId)` once
            // the ghost arrives — so the user sees the card "fly"
            // from the compose sheet up into its slot in the feed.
            ComposePostSheet(parentId: nil, usesFlight: true)
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
        .navigationDestination(item: $profileDestination) { route in
            PublishedProfileView(username: route.username)
        }
        .navigationDestination(item: $threadDestination) { post in
            PostThreadView(
                rootId: post.rootId ?? post.id,
                onRootDeleted: { deletedRoot in
                    // Thread view already ran the squish + retreat,
                    // and it's about to dismiss. Scrub the row from
                    // the feed (without re-running the in-feed pop)
                    // and fire the delete here so the rollback
                    // snapshot lives next to the column it'd be
                    // re-inserted into.
                    handleRootDeletedFromThread(deletedRoot)
                }
            )
        }
        .cucuToast(message: $toastMessage)
        .onReceive(
            NotificationCenter.default.publisher(for: .cucuPostOptimisticallyDeleted)
        ) { notification in
            // Cross-surface delete fan-out: any view that pulls a
            // post out of its own column broadcasts the id, and we
            // mirror the removal here so the feed stays in sync
            // without a refetch. `removeLocally` is idempotent —
            // posts that aren't in this column just no-op, which
            // keeps the per-user feed and the global feed safely
            // subscribing to the same channel.
            guard let id = CucuPostEvents.deletedPostId(from: notification) else {
                return
            }
            guard vm.posts.contains(where: { $0.id == id }) else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                vm.removeLocally(postId: id)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .cucuProfileAvatarDidChange)
        ) { notification in
            guard let username = CucuProfileEvents.avatarUsername(from: notification) else {
                return
            }
            Task { await avatarStore.refresh(username: username) }
        }
        .onChange(of: flightCoordinator.landedPostId) { _, newValue in
            // Flight ghost just reached the destination. Prepend
            // the post the coordinator is carrying with the
            // bouncy materialise-in-place transition so the row
            // appears to *be* the ghost rather than a separate
            // top-edge slide. The cucuPostLanding transition is
            // gated below on `lastLandedPostId == post.id` so only
            // this insertion uses the spring scale-up; subsequent
            // server pushes still slide in from the top.
            guard let id = newValue,
                  let post = flightCoordinator.post,
                  post.id == id else { return }
            lastLandedPostId = id
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                vm.prepend(post)
            }
        }
        // Note: thread → feed dismissal used to refetch the affected
        // post row to pick up edits / reply counters. That cost a
        // wire round-trip on every thread visit. The thread
        // viewmodel mutates the in-memory post optimistically (likes,
        // edits via `editPost`, reply counter via `incrementReplyCount`)
        // and other surfaces broadcast deletions through
        // `cucuPostOptimisticallyDeleted`, so the feed's local copy
        // is correct in the dominant cases. The user can pull-to-
        // refresh for canonical state when needed.
        .task(id: auth.currentUser?.id.lowercased()) {
            avatarStore.reset()
            await vm.reloadForViewerChange()
            // Visible rows pull their own avatars lazily via
            // `.onAppear`. The masthead puck is the one
            // exception: it points at the *signed-in viewer*,
            // who almost never has a post on the global feed's
            // first page, so its avatar wouldn't be triggered by
            // any row appearing — fetch it directly so the puck
            // paints with the right photo.
            if let me = auth.currentUser?.username, !me.isEmpty {
                avatarStore.requestLazy(for: me)
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

    /// Invisible flight-coordinator anchor. The post-compose flight
    /// overlay needs a fixed point at the top of the feed where
    /// freshly-prepended rows will land — under the previous design
    /// it sat at the bottom of the masthead's hairline rule. Now
    /// that the masthead is gone, the anchor is a 1pt clear strip at
    /// the top of the scroll content. Keeps the flight landing
    /// behaviour identical without resurrecting the editorial chrome.
    private var flightAnchor: some View {
        Color.clear
            .frame(height: 1)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            let frame = geo.frame(in: .global)
                            flightCoordinator.registerDestination(
                                CGPoint(x: frame.midX, y: frame.maxY + 36)
                            )
                        }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            flightCoordinator.registerDestination(
                                CGPoint(x: newFrame.midX, y: newFrame.maxY + 36)
                            )
                        }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayTitle: String {
        switch vm.feedSource {
        case .global: return "Feed"
        case .byAuthor: return title
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
                    avatarURL: avatarStore.avatarURL(for: post.authorUsername),
                    onTap: { threadDestination = post },
                    onLike: { vm.toggleLike(postId: post.id) },
                    onReply: { threadDestination = post },
                    onDelete: { handleDelete(post) },
                    onReport: { reportTarget = post },
                    onBlock: { blockTarget = post },
                    onAuthorTap: {
                        profileDestination = AuthorRoute(
                            username: post.authorUsername
                        )
                    }
                )
                .scaleEffect(rowScaleEffect(for: post.id), anchor: .center)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: poppingPostId)
                .animation(.spring(response: 0.32, dampingFraction: 0.5), value: flightCoordinator.pulsingPostId)
                // Use the materialise-in-place transition only for
                // the row that just received the flight; every
                // other insertion (refresh, server push) keeps the
                // standard top-edge slide.
                .transition(
                    lastLandedPostId == post.id
                        ? .cucuPostLanding
                        : .cucuPostPop
                )
                .zIndex(
                    poppingPostId == post.id || flightCoordinator.pulsingPostId == post.id
                        ? 1
                        : 0
                )
                .onAppear {
                    avatarStore.requestLazy(for: post.authorUsername)
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
                        .tint(chrome.theme.inkMuted)
                    Text("Loading more")
                        .font(.cucuSans(13, weight: .regular))
                        .foregroundStyle(chrome.theme.inkFaded)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if !vm.posts.isEmpty && !vm.isLoadingMore {
                endOfFeed
            }
        }
        .animation(.spring(response: 0.46, dampingFraction: 0.7), value: vm.posts.map(\.id))
        .padding(.top, 14)
        .padding(.horizontal, 20)
    }

    /// Quiet end-of-feed marker. Refined-minimalist: drops the
    /// sparkle brackets in favour of a flat sentence-case label
    /// in faded ink. The end of the feed is information, not a
    /// flourish.
    private var endOfFeed: some View {
        Text("End of feed")
            .font(.cucuSans(13, weight: .regular))
            .foregroundStyle(chrome.theme.inkFaded)
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
        VStack(spacing: 8) {
            Spacer(minLength: 60)
            Text(emptyTitle)
                .font(.cucuSans(18, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(emptySubtitle)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            if showsCompose {
                CucuRefinedPillButton("Write the first entry") {
                    showCompose = true
                }
                .padding(.top, 12)
                .padding(.horizontal, 32)
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
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Text("Couldn't reach the feed")
                .font(.cucuSans(18, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(message)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            CucuRefinedPillButton("Try again") {
                Task { await vm.initialLoad() }
            }
            .padding(.top, 6)
            .padding(.horizontal, 32)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    /// Resolves the per-row scale across two competing animations:
    /// the delete anticipation pop (1.06 swell before squish-fade)
    /// and the flight-landing pulse (1.06 spring overshoot just
    /// after the ghost dissolves into the row). The two never fire
    /// on the same row at the same time, so a simple "whichever
    /// matches wins" branch keeps the math straightforward.
    private func rowScaleEffect(for postId: String) -> CGFloat {
        if poppingPostId == postId { return 1.06 }
        if flightCoordinator.pulsingPostId == postId { return 1.06 }
        return 1.0
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

    /// Counterpart to `handleDelete` for the case where the user
    /// deleted the *root* of a thread from `PostThreadView`. The
    /// thread view has already run its anticipation pop, squish,
    /// and closing-flourish locally, and is about to dismiss; the
    /// feed's job is to scrub the row from its column and fire
    /// the delete with a rollback path that lands the
    /// snapshot right back in place if the server rejects.
    ///
    /// Skipping the feed's own anticipation pop is intentional —
    /// the user is mid-dismiss and never sees the feed during the
    /// thread-side animation, so a second swell here would be a
    /// pointless flash through the slide. The springy `removeLocally`
    /// still fires inside `withAnimation` so the feed paints clean
    /// once it's revealed.
    private func handleRootDeletedFromThread(_ post: Post) {
        let snapshotIndex = vm.posts.firstIndex(where: { $0.id == post.id })
        let snapshot = post

        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            vm.removeLocally(postId: post.id)
        }
        // Cross-surface fan-out so any other PostFeedView instance
        // (per-user feed showing the same author's posts, etc.)
        // mirrors the removal without waiting for a refetch.
        CucuPostEvents.broadcastDeletion(postId: post.id)

        Task {
            do {
                try await PostService().deletePost(
                    postId: post.id,
                    authorId: post.authorId
                )
            } catch {
                await MainActor.run {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        if let idx = snapshotIndex {
                            vm.reinsert(snapshot, at: idx)
                        } else {
                            vm.prepend(snapshot)
                        }
                    }
                    if let err = error as? PostError {
                        toastMessage = err.errorDescription ?? "Couldn't delete the post."
                    } else {
                        toastMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleDelete(_ post: Post) {
        let currentUserId = auth.currentUser?.id.lowercased() ?? "<nil>"
        print("[CuCu/handleDelete] tapped delete on postId=\(post.id) post.authorId=\(post.authorId) currentUserId=\(currentUserId) isOwn=\(post.authorId.lowercased() == currentUserId)")
        let snapshotIndex = vm.posts.firstIndex(where: { $0.id == post.id })
        let snapshot = post
        CucuHaptics.delete()

        // Phase 1: anticipation pop — flag the row so its
        // `.scaleEffect` swells. Phase 2: after a short hold the
        // squish-fade removal runs inside a bouncy spring so the
        // surrounding rows snap up into the gap.
        poppingPostId = post.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                vm.removeLocally(postId: post.id)
            }
            poppingPostId = nil
            // Fan out to any other post-list surface that might
            // be holding the same row in memory (per-user feed
            // sheet, profile column).
            CucuPostEvents.broadcastDeletion(postId: post.id)
        }

        Task {
            do {
                try await PostService().deletePost(postId: post.id, authorId: post.authorId)
                print("[CuCu/handleDelete] deletePost returned without throwing for postId=\(post.id)")
            } catch {
                // Server didn't accept the delete (RLS reject,
                // network drop, etc.). Roll the optimistic
                // removal back and tell the user — without the
                // toast the row would just bounce back into the
                // column on the next refresh with no
                // explanation.
                print("[CuCu/handleDelete] caught error rolling back postId=\(post.id) error=\(error)")
                await MainActor.run {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        if let idx = snapshotIndex {
                            vm.reinsert(snapshot, at: idx)
                        } else {
                            vm.prepend(snapshot)
                        }
                    }
                    if let err = error as? PostError {
                        toastMessage = err.errorDescription ?? "Couldn't delete the post."
                    } else {
                        toastMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - Author route

/// Navigation push target for the "tap a post's profile" intent.
/// The username doubles as the identity (post authors are unique by
/// handle in the schema), so it satisfies `Identifiable` directly
/// without a separate id field — keeps the bound `@State` cheap.
private struct AuthorRoute: Identifiable, Hashable {
    let username: String
    var id: String { username }
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
    /// Process-wide app-chrome theme. The skeleton mirrors a real
    /// `PostRowView` card geometry, so the surface + skeleton bars
    /// follow the same theme — a dark theme makes the placeholders
    /// dark, not cream-on-dark.
    @State private var chrome = AppChromeStore.shared

    /// Skeleton-bar tint. Uses the chrome's in-card primary ink at
    /// low opacity so a dark card gets light-grey bars and a light
    /// card gets dark-grey bars without keeping a separate token.
    private var barFill: Color {
        chrome.theme.cardInkPrimary.opacity(0.18)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(barFill)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(barFill)
                        .frame(width: 130, height: 11)
                    Capsule()
                        .fill(barFill)
                        .frame(width: 70, height: 8)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                Capsule()
                    .fill(barFill)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                Capsule()
                    .fill(barFill)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                Capsule()
                    .fill(barFill)
                    .frame(width: 200, height: 10)
            }
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Capsule()
                    .fill(barFill)
                    .frame(width: 28, height: 10)
                Capsule()
                    .fill(barFill)
                    .frame(width: 28, height: 10)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(chrome.theme.cardColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(chrome.theme.cardStroke, lineWidth: 1)
        )
        .opacity(phase ? 1.0 : 0.55)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}
