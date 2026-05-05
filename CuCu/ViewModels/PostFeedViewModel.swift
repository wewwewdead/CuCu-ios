import Foundation
import Observation

/// Drives `PostFeedView`'s state machine. Same shape as
/// `PostThreadViewModel` — both expose `status` + `viewerLikedIds`
/// + a thin set of mutation methods so the views stay declarative.
///
/// Cursor pagination mirrors `PublishedProfilesListView`'s pattern:
/// the last-loaded post's `createdAt` is the cursor, fed back to
/// `PostService.fetchFeed(before:)` for the next page. New posts
/// inserted at the head don't shift the cursor window.
@MainActor
@Observable
final class PostFeedViewModel {
    enum Status: Equatable {
        case loading
        case loaded
        case empty
        case error(String)
    }

    /// Which slice of `posts` the VM should fetch.
    ///
    /// `.global` is the original Latest feed (all top-level posts);
    /// `.byAuthor(id)` narrows to a single user's top-level posts so
    /// the same view + pagination machinery powers the per-profile
    /// "Posts" surfaces. The cases are mutually exclusive — switching
    /// between them is not supported on a live VM, callers
    /// instantiate a fresh one for each surface.
    enum FeedSource: Equatable {
        case global
        case byAuthor(String)
    }

    private(set) var posts: [Post] = []
    private(set) var status: Status = .loading
    private(set) var canLoadMore: Bool = true
    private(set) var isLoadingMore: Bool = false
    /// Set of post ids the current viewer has liked. Hydrated in
    /// batch after each fetch so heart state paints with the
    /// initial render rather than fading in per-row.
    private(set) var viewerLikedIds: Set<String> = []

    let feedSource: FeedSource

    private let service = PostService()
    private let likeService = PostLikeService()
    private var likeOperationTokens = OptimisticMutationTokens()
    private var viewerGeneration = UUID()

    init(feedSource: FeedSource = .global) {
        self.feedSource = feedSource
    }

    /// True for the very first load (or a refresh that emptied the
    /// column). Distinguishing this from "loading more" lets the
    /// view show a centered spinner only when there's nothing to
    /// look at; subsequent refreshes ride the system pull-to-
    /// refresh affordance.
    var isInitialLoading: Bool {
        status == .loading && posts.isEmpty
    }

    func initialLoad() async {
        if posts.isEmpty { status = .loading }
        let generation = viewerGeneration
        likeOperationTokens.invalidateAll()
        do {
            let next = try await fetchPage(before: nil)
            guard !Task.isCancelled, generation == viewerGeneration else { return }
            let liked = await fetchLikedIds(for: next.map(\.id))
            guard !Task.isCancelled, generation == viewerGeneration else { return }
            posts = next
            viewerLikedIds = liked
            canLoadMore = next.count >= PostService.feedPageSize
            status = next.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch let err as PostError {
            status = .error(err.errorDescription ?? "Couldn't load the feed.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// User-initiated pull-to-refresh. Always reloads from the
    /// top — clears the existing column so a deleted post in the
    /// middle of the feed doesn't linger between cursor pages.
    func refresh() async {
        viewerGeneration = UUID()
        canLoadMore = true
        isLoadingMore = false
        await initialLoad()
    }

    /// Account/session boundary reload. Clears viewer-scoped state
    /// before fetching so stale optimistic callbacks and liked ids
    /// from the previous account cannot bleed into the new snapshot.
    func reloadForViewerChange() async {
        viewerGeneration = UUID()
        posts = []
        viewerLikedIds = []
        likeOperationTokens.invalidateAll()
        canLoadMore = true
        isLoadingMore = false
        status = .loading
        await initialLoad()
    }

    /// Triggered by the last visible row appearing in the view.
    /// No-op when we've already exhausted the feed, are mid-load,
    /// or have no anchor to paginate from.
    func loadMore() async {
        guard canLoadMore, !isLoadingMore else { return }
        guard let cursor = posts.last?.createdAt else { return }
        let generation = viewerGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let next = try await fetchPage(before: cursor)
            guard !Task.isCancelled, generation == viewerGeneration else { return }
            // Defensive duplicate filter — if two posts share a
            // sub-millisecond `created_at`, the cursor query can
            // re-include the boundary row.
            let existing = Set(posts.map(\.id))
            let fresh = next.filter { !existing.contains($0.id) }
            let liked = await fetchLikedIds(for: fresh.map(\.id))
            guard !Task.isCancelled, generation == viewerGeneration else { return }
            posts.append(contentsOf: fresh)
            viewerLikedIds.formUnion(liked)
            canLoadMore = next.count >= PostService.feedPageSize
        } catch {
            // Don't crash the feed on a pagination error; just
            // stop trying. Pull-to-refresh retries the lot.
            canLoadMore = false
        }
    }

    /// Single dispatch point for "fetch one page at this cursor",
    /// branching on `feedSource` so the rest of the VM stays source-
    /// agnostic. Both branches return newest-first top-level posts
    /// so pagination semantics are uniform.
    private func fetchPage(before cursor: Date?) async throws -> [Post] {
        switch feedSource {
        case .global:
            return try await service.fetchFeed(before: cursor)
        case .byAuthor(let authorId):
            return try await service.fetchUserPosts(authorId: authorId, before: cursor)
        }
    }

    /// Drop a post in to the head of the feed. Called by
    /// `ComposePostSheet`'s `onPosted` so a freshly-composed post
    /// shows up immediately without waiting for the next refresh.
    func prepend(_ post: Post) {
        // Skip if it's somehow already in the column (double-tap
        // race, or refresh raced with the optimistic insert).
        guard !posts.contains(where: { $0.id == post.id }) else { return }
        posts.insert(post, at: 0)
        if status == .empty { status = .loaded }
    }

    /// Pull a post out of the column without going back to the
    /// service. Used by the optimistic-delete flow — the server
    /// call still has to land, but the UI shouldn't have a row
    /// hanging around with a "Deleting…" spinner while it does.
    func removeLocally(postId: String) {
        posts.removeAll { $0.id == postId }
        viewerLikedIds.remove(postId)
        if posts.isEmpty && status == .loaded { status = .empty }
    }

    /// Pull every post by `authorId` out of the loaded column.
    /// Called by the parent feed after a successful block so the
    /// user sees the block take effect immediately without
    /// reloading. The server-side `is_blocked` predicate on
    /// `posts_select_visible` keeps subsequent fetches clean too;
    /// this is just the in-memory scrub.
    func removeAllByAuthor(authorId: String) {
        let canonical = authorId.lowercased()
        let beforeCount = posts.count
        posts.removeAll { $0.authorId.lowercased() == canonical }
        if posts.count != beforeCount {
            // Drop any like-state we'd hydrated for the now-missing
            // posts so a future re-fetch doesn't paint stale hearts.
            let remaining = Set(posts.map(\.id))
            viewerLikedIds = viewerLikedIds.intersection(remaining)
            if posts.isEmpty && status == .loaded { status = .empty }
        }
    }

    /// Re-insert a post at a specific index — used by the feed
    /// view's delete-rollback path so a server-rejected delete
    /// puts the row back where it came from rather than at the
    /// head of the column.
    func reinsert(_ post: Post, at index: Int) {
        guard !posts.contains(where: { $0.id == post.id }) else { return }
        let safeIndex = max(0, min(index, posts.count))
        posts.insert(post, at: safeIndex)
        if status == .empty { status = .loaded }
    }

    // MARK: - Optimistic mutations

    /// Tap-to-like: flip the heart and the count immediately, then
    /// run the service call. On failure, roll the local state
    /// back. The trigger maintains the canonical `like_count` on
    /// the row, so a successful round-trip lands us in the same
    /// place we already painted.
    func toggleLike(postId: String) {
        guard let idx = posts.firstIndex(where: { $0.id == postId }) else { return }
        let wasLiked = viewerLikedIds.contains(postId)
        let snapshot = posts[idx]
        let token = likeOperationTokens.begin(for: postId)

        // Apply the optimistic flip.
        if wasLiked {
            viewerLikedIds.remove(postId)
            posts[idx].likeCount = max(0, posts[idx].likeCount - 1)
        } else {
            viewerLikedIds.insert(postId)
            posts[idx].likeCount += 1
        }

        Task { [weak self, wasLiked, snapshot, token] in
            guard let self else { return }
            do {
                let result = try await self.likeService.toggle(postId: postId)
                guard self.likeOperationTokens.finish(token, for: postId) else { return }
                if let nowIdx = self.posts.firstIndex(where: { $0.id == result.postId }) {
                    self.posts[nowIdx].likeCount = result.likeCount
                }
                if result.viewerHasLiked {
                    self.viewerLikedIds.insert(result.postId)
                } else {
                    self.viewerLikedIds.remove(result.postId)
                }
            } catch {
                guard self.likeOperationTokens.finish(token, for: postId) else { return }
                // Roll back. Re-find the row (its index may have
                // shifted if the user paginated meanwhile) and
                // restore the snapshot's count + liked-set entry.
                if let nowIdx = self.posts.firstIndex(where: { $0.id == postId }) {
                    self.posts[nowIdx] = snapshot
                }
                if wasLiked {
                    self.viewerLikedIds.insert(postId)
                } else {
                    self.viewerLikedIds.remove(postId)
                }
            }
        }
    }

    /// Update reply counters in-place after a reply lands. Called
    /// by the thread VM when `replyPosted` runs while the feed is
    /// still mounted underneath — keeps the parent post's reply
    /// pip in sync without a refetch.
    func incrementReplyCount(postId: String) {
        guard let idx = posts.firstIndex(where: { $0.id == postId }) else { return }
        posts[idx].replyCount += 1
    }

    // MARK: - Helpers

    private func fetchLikedIds(for ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await likeService.fetchLikeState(postIds: ids)
    }
}
