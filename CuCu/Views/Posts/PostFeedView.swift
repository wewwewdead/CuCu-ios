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
                    feedMasthead
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                    flightAnchor
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    stateContent
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
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
        .onReceive(
            NotificationCenter.default.publisher(for: .cucuPostReplyPosted)
        ) { notification in
            // A reply landed in the thread VM (or any other surface
            // that broadcasts the same event); bump the local
            // replyCount on any of our rows that match. Idempotent
            // per-id check keeps it safe to subscribe from every
            // feed surface — non-matching rows just no-op.
            //
            // Also kick a server-side refetch as a backstop so the
            // canonical denormalised counter wins if the optimistic
            // bump missed for any reason (e.g., the row was paginated
            // out and back in between the bump and re-render).
            let ids = CucuPostEvents.replyAncestorIds(from: notification)
            for id in ids {
                vm.incrementReplyCount(postId: id)
            }
            Task {
                for id in ids {
                    await vm.refreshPost(id: id)
                }
            }
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

    // MARK: - Editorial masthead
    //
    // Premium pass: the page opens with an editorial masthead that
    // gives the feed real weight before the scroll begins. A tracked
    // monospaced spec line carries a printer's-mark date / section
    // label; below it sits a Fraunces-italic display title (the page
    // identity) on the leading edge with a small bookplate avatar
    // puck on the trailing edge that points at the signed-in viewer.
    // A fleuron-rule closes the masthead and hands off to the flight
    // anchor + feed column. The whole masthead scrolls with the
    // content — it's a magazine spread's opener, not a sticky bar.

    /// Notebook masthead — playful display title in a chunky cut
    /// (Caprasimo) on the leading edge, viewer avatar puck on the
    /// trailing edge, with a tracked-mono spec line above. Scrolls
    /// with the content rather than pinning, so the page reads as
    /// a notebook spread that gives the feed its own opening real
    /// estate.
    private var feedMasthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.cucuCherry)
                        .frame(width: 5, height: 5)
                    Text(mastheadSpec)
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(2.4)
                        .foregroundStyle(chrome.theme.inkMuted)
                }
                Spacer(minLength: 8)
                Text(mastheadFolio)
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(2.4)
                    .foregroundStyle(chrome.theme.inkFaded)
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(displayTitle)
                    .font(.custom("Caprasimo-Regular", size: 36))
                    .foregroundStyle(chrome.theme.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                viewerPuck
            }
        }
    }

    /// Tracked uppercased spec — today's date for the global feed,
    /// "JOURNAL" for per-user surfaces. Reads as a printer's mark
    /// rather than a section heading.
    private var mastheadSpec: String {
        switch vm.feedSource {
        case .global:   return Self.mastheadDateString()
        case .byAuthor: return "JOURNAL"
        }
    }

    /// Trailing folio — the masthead's right-edge counterpart to the
    /// spec line. Uses an italic-friendly numeral for the global
    /// feed ("№ DAILY") and the running post count for per-user
    /// surfaces, so each surface has its own quiet identifier.
    private var mastheadFolio: String {
        switch vm.feedSource {
        case .global:
            return "№ DAILY"
        case .byAuthor:
            let count = vm.posts.count
            if count == 0 { return "№ —" }
            return "№ \(String(format: "%03d", count))"
        }
    }

    /// Trailing avatar puck — a small bookplate tile that points at
    /// the signed-in viewer. Tapping it opens the viewer's own
    /// published profile, mirroring the in-row avatar idiom. When
    /// the viewer hasn't published a profile yet (or the avatar
    /// hasn't resolved) the tile falls through to a Fraunces-italic
    /// initial on a paper-toned fill.
    @ViewBuilder
    private var viewerPuck: some View {
        if let username = auth.currentUser?.username, !username.isEmpty {
            Button {
                CucuHaptics.selection()
                profileDestination = AuthorRoute(username: username)
            } label: {
                Group {
                    if let urlString = avatarStore.avatarURL(for: username),
                       let url = CucuImageTransform.resized(urlString, square: 36) {
                        CachedRemoteImage(url: url, contentMode: .fill) {
                            mastheadLetterTile(for: username)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(chrome.theme.inkPrimary.opacity(0.35), lineWidth: 0.8)
                        )
                    } else {
                        mastheadLetterTile(for: username)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View your profile")
        }
    }

    private func mastheadLetterTile(for username: String) -> some View {
        ZStack {
            Circle()
                .fill(PostRowView.avatarColor(for: username))
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .strokeBorder(chrome.theme.inkPrimary.opacity(0.35), lineWidth: 0.8)
                )
            Text(PostRowView.avatarInitial(for: username))
                .font(.custom("Caprasimo-Regular", size: 17))
                .foregroundStyle(Color.cucuInk)
        }
    }

    /// Today's date in editorial-mono format ("WEDNESDAY · MAY 06,
    /// 2026"). Recomputed each render so a feed left open across
    /// midnight repaints with the correct stamp on the next refresh.
    private static func mastheadDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · MMM d, yyyy"
        return f.string(from: Date()).uppercased()
    }

    /// Invisible flight-coordinator anchor. The post-compose flight
    /// overlay needs a fixed point at the top of the feed where
    /// freshly-prepended rows will land. Sits just below the
    /// editorial masthead's fleuron rule, so the destination it
    /// registers tracks the top of the feed column itself — flight
    /// landing behaviour stays unchanged.
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
        LazyVStack(spacing: 0) {
            ForEach(Array(vm.posts.enumerated()), id: \.element.id) { index, post in
                VStack(spacing: 0) {
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
                    if index < vm.posts.count - 1 {
                        Rectangle()
                            .fill(chrome.theme.rule)
                            .frame(height: 1)
                            .padding(.leading, 18)
                            .padding(.trailing, 18)
                    }
                }
                .scaleEffect(rowScaleEffect(for: post.id), anchor: .center)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: poppingPostId)
                .animation(.spring(response: 0.32, dampingFraction: 0.5), value: flightCoordinator.pulsingPostId)
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
        .padding(.top, 6)
    }

    /// Notebook end-of-feed sign-off. A single fleuron between two
    /// hairline rules, with a handwritten "you're all caught up"
    /// note below — softer than the editorial spec stamps the page
    /// used to close on, and a closer match to the page-of-a-diary
    /// aesthetic the row vocabulary now establishes.
    private var endOfFeed: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(chrome.theme.rule)
                    .frame(height: 1)
                Text("❦")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cucuCherry)
                Rectangle()
                    .fill(chrome.theme.rule)
                    .frame(height: 1)
            }
            Text("you're all caught up — pull to refresh")
                .font(.custom("Caveat-Regular", size: 18))
                .foregroundStyle(chrome.theme.inkFaded)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
    }

    // MARK: - State surfaces

    /// Skeleton column — three placeholder rows that ghost the real
    /// row geometry (rainbow stripe + round avatar + handle / body /
    /// action bars). Pulses opacity rather than running a shimmer
    /// band, which feels more refined and less "loading gif" energy.
    private var skeletonColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { idx in
                FeedSkeletonCard()
                if idx < 2 {
                    Rectangle()
                        .fill(chrome.theme.rule)
                        .frame(height: 1)
                        .padding(.horizontal, 18)
                }
            }
        }
        .padding(.top, 6)
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

// MARK: - Masthead fleuron rule

/// Hairline rule with a centred fleuron, theme-aware. Sits beneath
/// the editorial masthead and the thread masthead so the social
/// surfaces share one closing-flourish idiom — same vocabulary the
/// editor's `CucuFleuronDivider` uses inside cards, but tinted to
/// the on-page chrome (cardless surface) instead of the cream-card
/// ink palette.
struct CucuFeedFleuronRule: View {
    @State private var chrome = AppChromeStore.shared
    var glyph: String = "❦"

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(chrome.theme.rule)
                .frame(height: 1)
            Text(glyph)
                .font(.cucuSerif(12, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
            Rectangle()
                .fill(chrome.theme.rule)
                .frame(height: 1)
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
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(barFill)
                .frame(width: 4, height: 96)
                .padding(.trailing, 14)
            Circle()
                .fill(barFill)
                .frame(width: 40, height: 40)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(barFill)
                        .frame(width: 110, height: 14)
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(barFill)
                        .frame(width: 24, height: 9)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(barFill)
                        .frame(height: 10)
                        .frame(maxWidth: .infinity)
                    Capsule()
                        .fill(barFill)
                        .frame(width: 220, height: 10)
                }
                HStack(spacing: 18) {
                    Capsule()
                        .fill(barFill)
                        .frame(width: 36, height: 10)
                    Capsule()
                        .fill(barFill)
                        .frame(width: 36, height: 10)
                    Capsule()
                        .fill(barFill)
                        .frame(width: 22, height: 10)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(phase ? 1.0 : 0.55)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}
