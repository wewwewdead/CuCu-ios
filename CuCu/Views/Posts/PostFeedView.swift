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
    /// Phase 7 — drives the report sheet. The whole post is held
    /// (not just `id`) so the sheet can render the body / author
    /// without a refetch.
    @State private var reportTarget: Post? = nil
    /// Drives the destructive "Block @user?" confirmation dialog.
    @State private var blockTarget: Post? = nil
    /// Toast surface — bound by `cucuToast` so a successful
    /// report / block / dismiss flashes a brief confirmation.
    @State private var toastMessage: String? = nil

    private let title: String
    /// Hide the compose pencil + the empty-state Compose button on
    /// surfaces where authoring doesn't make sense (e.g. someone
    /// else's posts list). The global Feed and your own posts list
    /// keep it on.
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
        Group {
            switch vm.status {
            case .loading where vm.posts.isEmpty:
                loadingState
            case .empty:
                emptyState
            case .error(let message):
                errorState(message)
            case .loading, .loaded:
                feedColumn
            }
        }
        .navigationTitle(title)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsCompose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Compose post")
                }
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposePostSheet(parentId: nil) { post in
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
        .task { await vm.initialLoad() }
        .refreshable { await vm.refresh() }
    }

    private var blockDialogTitle: String {
        if let target = blockTarget {
            return "Block @\(target.authorUsername)?"
        }
        return "Block user?"
    }

    // MARK: - Column

    private var feedColumn: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.posts) { post in
                    PostRowView(
                        post: post,
                        style: .full,
                        viewerHasLiked: vm.viewerLikedIds.contains(post.id),
                        isOwnPost: post.authorId == auth.currentUser?.id.lowercased(),
                        onTap: { threadDestination = post },
                        onLike: { vm.toggleLike(postId: post.id) },
                        onReply: { threadDestination = post },
                        onDelete: { handleDelete(post) },
                        onReport: { reportTarget = post },
                        onBlock: { blockTarget = post }
                    )
                    .onAppear {
                        // Trigger pagination when the *last* row
                        // shows up. Comparing by id rather than
                        // index keeps this safe across the head-
                        // mutating `prepend` path.
                        if post.id == vm.posts.last?.id {
                            Task { await vm.loadMore() }
                        }
                    }
                    Divider()
                        .padding(.leading, 16)
                }
                if vm.isLoadingMore {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
        }
    }

    // MARK: - State surfaces

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No posts yet")
                .font(.title3.weight(.semibold))
            Text(showsCompose ? "Be the first to share something." : "This user hasn't posted yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if showsCompose {
                Button {
                    showCompose = true
                } label: {
                    Label("Compose", systemImage: "square.and.pencil")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load the feed")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await vm.initialLoad() }
            } label: {
                Text("Try again")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - Actions

    /// Map a `ReportPostSheet` outcome into a feed-level toast.
    /// `cancelled` is silent — the user chose to abandon, no
    /// confirmation needed.
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

    /// Block flow: hit the service, then scrub the loaded column
    /// in place so the user sees the block take effect without a
    /// full refresh. Service failure surfaces via the toast as a
    /// gentle "Couldn't block — try again", and the column stays
    /// untouched.
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

    /// Optimistic delete: pull the post out of the column right
    /// away, then call the service. The view-model owns the
    /// rollback if the service rejects, but for now we assume the
    /// happy path — feed-level delete is rare enough that a
    /// failure surfaces as the row reappearing on next refresh.
    private func handleDelete(_ post: Post) {
        let snapshotIndex = vm.posts.firstIndex(where: { $0.id == post.id })
        let snapshot = post
        vm.removeLocally(postId: post.id)
        Task {
            do {
                try await PostService().softDelete(postId: post.id)
            } catch {
                // Re-insert at the same spot it came out of so the
                // user sees the row come back rather than land at
                // the top.
                if let idx = snapshotIndex {
                    vm.reinsert(snapshot, at: idx)
                } else {
                    vm.prepend(snapshot)
                }
            }
        }
    }
}

