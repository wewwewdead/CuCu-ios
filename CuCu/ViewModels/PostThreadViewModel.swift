import Foundation
import Observation

/// Drives `PostThreadView` for the lazy-load era.
///
/// The view-model owns a `PostThread` whose state grows on
/// demand: initial load brings in the root + the first page of
/// direct replies, and the user expands deeper subtrees by
/// tapping "View N replies" / "Show more replies" on the rows
/// they care about. The view never inspects the dictionaries
/// itself — `PostThread.flattenForRender()` produces the row
/// stream, and the VM's mutations are the only writers.
@MainActor
@Observable
final class PostThreadViewModel {
    enum Status: Equatable {
        case loading
        case loaded
        case error(String)
    }

    private(set) var thread: PostThread?
    private(set) var status: Status = .loading
    /// Like state for every post we've loaded. Hydrated in
    /// batches as new subtrees are fetched so the heart paints
    /// correctly the moment the new rows show up.
    private(set) var viewerLikedIds: Set<String> = []

    /// Last delete error — drives an alert in the view. Cleared
    /// by `clearDeleteError` when the alert dismisses.
    private(set) var lastDeleteError: String?

    private let service = PostService()
    private let likeService = PostLikeService()

    // MARK: - Initial load

    /// Fetch the root + first page of direct replies. Two
    /// round-trips, deliberate: keeping them separate means the
    /// thread's *root* paints before the children land, which
    /// in turn means the user can start reading and tap "Reply
    /// to thread" before the page of replies has finished
    /// loading on cellular.
    func load(rootId: String) async {
        if thread == nil { status = .loading }
        do {
            async let rootTask = service.fetchPost(id: rootId)
            async let firstPageTask = service.fetchDirectReplies(parentId: rootId)
            let root = try await rootTask
            let firstPage = try await firstPageTask

            var posts: [String: Post] = [root.id: root]
            for child in firstPage { posts[child.id] = child }
            var children: [String: [String]] = [root.id: firstPage.map(\.id)]

            var nextCursors: [String: Date] = [:]
            if let lastChild = firstPage.last {
                nextCursors[root.id] = lastChild.createdAt
            }

            // Optimistic full-page heuristic: if the page came
            // back at the requested limit, assume there's more
            // to fetch. The server confirms / refutes on the
            // next "Show more replies" tap.
            var hasMore: [String: Bool] = [:]
            hasMore[root.id] = firstPage.count >= PostService.directRepliesPageSize

            // Seed empty child slots for each loaded reply so
            // future expand calls have a place to write.
            for child in firstPage where children[child.id] == nil {
                children[child.id] = []
            }

            thread = PostThread(
                root: root,
                posts: posts,
                childrenByParent: children,
                expandedIds: [root.id],
                nextCursorByParent: nextCursors,
                hasMoreByParent: hasMore,
                loadingByParent: []
            )
            status = .loaded

            await hydrateLikes(for: Array(posts.keys))
        } catch let err as PostError {
            status = .error(err.errorDescription ?? "Couldn't load this thread.")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Lazy expansion

    /// Fetch the first page of `postId`'s direct replies and
    /// merge them into the tree. No-op when `postId` is already
    /// expanded or already mid-fetch — both protect against a
    /// double-tap.
    func expandReplies(for postId: String) async {
        guard var current = thread else { return }
        guard !current.expandedIds.contains(postId) else { return }
        guard !current.loadingByParent.contains(postId) else { return }

        current.loadingByParent.insert(postId)
        thread = current

        do {
            let page = try await service.fetchDirectReplies(parentId: postId)
            try Task.checkCancellation()

            guard var updated = thread else { return }
            for child in page { updated.posts[child.id] = child }
            updated.childrenByParent[postId] = page.map(\.id)
            for child in page where updated.childrenByParent[child.id] == nil {
                updated.childrenByParent[child.id] = []
            }
            if let last = page.last {
                updated.nextCursorByParent[postId] = last.createdAt
            }
            updated.hasMoreByParent[postId] = page.count >= PostService.directRepliesPageSize
            updated.expandedIds.insert(postId)
            updated.loadingByParent.remove(postId)
            thread = updated

            await hydrateLikes(for: page.map(\.id))
        } catch {
            // Couldn't expand — drop the loading flag so the
            // user can tap "View N replies" again. Surfacing
            // the error inline would crowd the affordance, so
            // we let the second tap drive a retry.
            if var updated = thread {
                updated.loadingByParent.remove(postId)
                thread = updated
            }
        }
    }

    /// Collapse an expanded subtree. Mirror of `expandReplies`,
    /// but synchronous and local — we only need to drop the id
    /// from `expandedIds` and `flattenForRender` will route the
    /// parent back through the "View N replies" branch on the
    /// next pass. Loaded children, cursors, and `hasMore` flags
    /// are kept in place so re-expanding is instant. The root
    /// can't be collapsed: there'd be no surviving affordance
    /// to bring it back, and the page would read empty.
    func collapse(parentId: String) {
        guard var current = thread else { return }
        guard parentId != current.root.id else { return }
        guard current.expandedIds.contains(parentId) else { return }
        current.expandedIds.remove(parentId)
        thread = current
    }

    /// Paginate the next page of direct children under
    /// `parentId`. Reads `nextCursorByParent[parentId]` and
    /// asks the service for siblings created after that cursor.
    func loadMoreSiblings(under parentId: String) async {
        guard var current = thread else { return }
        guard !current.loadingByParent.contains(parentId) else { return }
        guard let cursor = current.nextCursorByParent[parentId] else { return }

        current.loadingByParent.insert(parentId)
        thread = current

        do {
            let page = try await service.fetchDirectReplies(
                parentId: parentId,
                after: cursor
            )
            try Task.checkCancellation()

            guard var updated = thread else { return }
            // Defensive duplicate filter — same trick the feed
            // uses. A sub-millisecond tie on `created_at` could
            // re-send the boundary row.
            let existing = Set(updated.childrenByParent[parentId] ?? [])
            let fresh = page.filter { !existing.contains($0.id) }
            for child in fresh { updated.posts[child.id] = child }
            updated.childrenByParent[parentId, default: []].append(contentsOf: fresh.map(\.id))
            for child in fresh where updated.childrenByParent[child.id] == nil {
                updated.childrenByParent[child.id] = []
            }
            if let last = fresh.last {
                updated.nextCursorByParent[parentId] = last.createdAt
            }
            updated.hasMoreByParent[parentId] = page.count >= PostService.directRepliesPageSize
            updated.loadingByParent.remove(parentId)
            thread = updated

            await hydrateLikes(for: fresh.map(\.id))
        } catch {
            if var updated = thread {
                updated.loadingByParent.remove(parentId)
                // Conservative: stop offering more after a
                // failure so we don't busy-loop on a broken
                // server.
                updated.hasMoreByParent[parentId] = false
                thread = updated
            }
        }
    }

    // MARK: - Likes

    /// Optimistic heart toggle. Mutates the post in `posts`
    /// in-place so every render-item built off it reflects the
    /// new count + liked-set. Snapshot rollback on failure
    /// restores both atomically.
    func toggleLike(postId: String) {
        guard var current = thread else { return }
        guard let post = current.posts[postId] else { return }
        let wasLiked = viewerLikedIds.contains(postId)
        let snapshot = current

        var updated = post
        if wasLiked {
            updated.likeCount = max(0, updated.likeCount - 1)
            viewerLikedIds.remove(postId)
        } else {
            updated.likeCount += 1
            viewerLikedIds.insert(postId)
        }
        current.posts[postId] = updated
        thread = current

        Task { [weak self, wasLiked, snapshot] in
            guard let self else { return }
            do {
                if wasLiked {
                    try await self.likeService.unlike(postId: postId)
                } else {
                    try await self.likeService.like(postId: postId)
                }
            } catch {
                self.thread = snapshot
                if wasLiked { self.viewerLikedIds.insert(postId) }
                else { self.viewerLikedIds.remove(postId) }
            }
        }
    }

    // MARK: - Delete (own posts only)

    /// Optimistic remove + service call. Pulls the deleted post
    /// (and any descendants we'd loaded for it) out of the
    /// tree, then decrements the parent's and root's
    /// `replyCount` by one. Failure restores the snapshot and
    /// surfaces an error message via `lastDeleteError`.
    func delete(postId: String) {
        guard var current = thread else { return }
        // Root deletion isn't reachable from this flow — feed
        // owns that. Defensive guard.
        guard postId != current.root.id else { return }
        guard let target = current.posts[postId] else { return }
        guard let parentId = target.parentId else { return }
        let snapshot = current

        // Detach from parent's children list.
        if var siblings = current.childrenByParent[parentId] {
            siblings.removeAll { $0 == postId }
            current.childrenByParent[parentId] = siblings
        }

        // Drop the post and its loaded subtree (if any). The
        // server soft-deletes a single row, but on the client
        // a deleted parent should pull its locally-loaded
        // replies out of view too — a refetch later will get
        // the canonical state.
        var toRemove: [String] = [postId]
        var stack: [String] = [postId]
        while let next = stack.popLast() {
            if let kids = current.childrenByParent[next] {
                stack.append(contentsOf: kids)
                toRemove.append(contentsOf: kids)
            }
        }
        for id in toRemove {
            current.posts.removeValue(forKey: id)
            current.childrenByParent.removeValue(forKey: id)
            current.expandedIds.remove(id)
            current.nextCursorByParent.removeValue(forKey: id)
            current.hasMoreByParent.removeValue(forKey: id)
            current.loadingByParent.remove(id)
            viewerLikedIds.remove(id)
        }

        // Decrement parent + root reply counts in place. If the
        // parent and root are the same row, decrement only
        // once.
        if var parent = current.posts[parentId] {
            parent.replyCount = max(0, parent.replyCount - 1)
            current.posts[parentId] = parent
        }
        if parentId != current.root.id {
            // Root's replyCount lives on the immutable `root`
            // field too; the in-dict copy is what render reads.
            if var rootCopy = current.posts[current.root.id] {
                rootCopy.replyCount = max(0, rootCopy.replyCount - 1)
                current.posts[current.root.id] = rootCopy
            }
        }

        thread = current

        Task { [weak self, snapshot] in
            guard let self else { return }
            do {
                try await self.service.softDelete(postId: postId)
            } catch let err as PostError {
                self.thread = snapshot
                self.lastDeleteError = err.errorDescription
            } catch {
                self.thread = snapshot
                self.lastDeleteError = error.localizedDescription
            }
        }
    }

    func clearDeleteError() { lastDeleteError = nil }

    // MARK: - Block (in-memory scrub)

    /// Walk the loaded tree and pull every post authored by
    /// `authorId` — plus the descendants we'd loaded under each.
    /// Reply counts on surviving ancestors are decremented per
    /// pruned reply so the affordance text ("View N replies")
    /// stays honest after a block.
    ///
    /// If the *root* of the thread happened to be authored by the
    /// blocked user, the entire view reads as empty: we clear
    /// `thread` and leave `status = .loaded` so the screen renders
    /// nothing rather than an error — the user can pop back to the
    /// feed where the post is also gone.
    func removeAllByAuthor(authorId: String) {
        guard var current = thread else { return }
        let canonical = authorId.lowercased()

        // Edge: root itself is the blocked author. Tear the whole
        // thread; the surrounding NavigationStack will pop back on
        // its own once the user notices.
        if current.root.authorId.lowercased() == canonical {
            thread = nil
            return
        }

        // Collect every blocked-author post and their loaded
        // descendants up front so we can compute how much to
        // decrement each ancestor's replyCount by.
        let blockedSeed = current.posts.values
            .filter { $0.authorId.lowercased() == canonical && $0.id != current.root.id }
            .map(\.id)

        var toRemove: Set<String> = []
        var stack: [String] = blockedSeed
        while let next = stack.popLast() {
            guard !toRemove.contains(next) else { continue }
            toRemove.insert(next)
            if let kids = current.childrenByParent[next] {
                stack.append(contentsOf: kids)
            }
        }
        guard !toRemove.isEmpty else { return }

        // For each blocked seed (a removed reply directly under a
        // surviving parent), the parent — and the chain of
        // ancestors up to root — owes one decrement.
        var decrementsByAncestor: [String: Int] = [:]
        for seedId in blockedSeed {
            guard let seed = current.posts[seedId] else { continue }
            // Walk parent chain.
            var cursor: String? = seed.parentId
            while let p = cursor, !toRemove.contains(p) {
                decrementsByAncestor[p, default: 0] += 1
                cursor = current.posts[p]?.parentId
            }
        }

        // Detach removed ids from their parent's children list.
        for (parentId, kids) in current.childrenByParent {
            if toRemove.contains(parentId) { continue }
            current.childrenByParent[parentId] = kids.filter { !toRemove.contains($0) }
        }

        // Drop the rows + any per-row state we'd hydrated.
        for id in toRemove {
            current.posts.removeValue(forKey: id)
            current.childrenByParent.removeValue(forKey: id)
            current.expandedIds.remove(id)
            current.nextCursorByParent.removeValue(forKey: id)
            current.hasMoreByParent.removeValue(forKey: id)
            current.loadingByParent.remove(id)
            viewerLikedIds.remove(id)
        }

        // Apply per-ancestor reply-count decrements.
        for (ancestorId, delta) in decrementsByAncestor {
            if var post = current.posts[ancestorId] {
                post.replyCount = max(0, post.replyCount - delta)
                current.posts[ancestorId] = post
            }
        }

        thread = current
    }

    // MARK: - Reply insertion

    /// Slot a freshly-composed reply into the tree without a
    /// full reload.
    ///
    /// Two paths:
    ///   - Parent **is** expanded: append to its children
    ///     (children list is created_at ascending; the new
    ///     reply is the newest), and bump parent's + root's
    ///     `replyCount`.
    ///   - Parent **isn't** expanded: only bump `replyCount`s.
    ///     The reply isn't visible until the user expands the
    ///     parent — at which point the next `expandReplies`
    ///     call (or a fresh thread load) returns it from the
    ///     server. Avoids a confusing "ghost reply appears
    ///     under a collapsed View N replies button".
    func replyPosted(_ post: Post) {
        guard var current = thread else { return }
        guard let parentId = post.parentId else { return }
        guard current.posts[parentId] != nil else {
            // Parent not in the loaded tree (the user replied
            // through a stale composer that's no longer
            // anchored). Bail; next refresh handles it.
            return
        }

        if current.expandedIds.contains(parentId) {
            // Append to parent's children list (ascending order
            // means the new reply goes at the end). Don't bump
            // `nextCursorByParent` — the cursor tracks loaded
            // siblings vs. server siblings; the freshly-posted
            // reply doesn't change what's left to fetch.
            current.posts[post.id] = post
            current.childrenByParent[parentId, default: []].append(post.id)
            // Make sure the new reply has an empty children
            // bucket so a later expand call has somewhere to
            // write.
            if current.childrenByParent[post.id] == nil {
                current.childrenByParent[post.id] = []
            }
        }

        // Bump parent + root reply counts unconditionally —
        // even when the parent is collapsed, the count on the
        // "View N replies" button should reflect the new
        // reality.
        if var parent = current.posts[parentId] {
            parent.replyCount += 1
            current.posts[parentId] = parent
        }
        if parentId != current.root.id, var rootCopy = current.posts[current.root.id] {
            rootCopy.replyCount += 1
            current.posts[current.root.id] = rootCopy
        }

        thread = current
    }

    // MARK: - Helpers

    private func hydrateLikes(for ids: [String]) async {
        guard !ids.isEmpty else { return }
        let liked = await likeService.fetchLikeState(postIds: ids)
        viewerLikedIds.formUnion(liked)
    }
}
