import Foundation

/// In-progress state for a thread that loads lazily.
///
/// The flat `descendants` array of the previous incarnation has
/// been replaced by a small dictionary-backed tree so the view
/// model can expand individual subtrees on demand without
/// pulling the entire conversation up front. The model is
/// otherwise pure data — every mutation routes through
/// `PostThreadViewModel`, which is the only place
/// `expandedIds` / cursors / loading flags are written.
///
/// **Pre-order render.** `flattenForRender()` walks the tree in
/// pre-order, descending **only into expanded subtrees**, and
/// emits the affordances (View N replies / Show more / loading)
/// the view should draw between rows. The view doesn't have to
/// reason about which ancestor's subtree is closing where —
/// that's all baked in here.
nonisolated struct PostThread: Equatable, Sendable {
    let root: Post

    /// Every post we've fetched so far, keyed by id. Mutated in
    /// place when an optimistic like / reply / delete lands so
    /// counter changes don't need a refetch.
    var posts: [String: Post]

    /// Ordered child ids per parent. Order is **created_at
    /// ascending** so the natural "oldest reply first" reading
    /// order falls out of iteration.
    var childrenByParent: [String: [String]]

    /// Parent ids whose direct replies have been fetched at
    /// least once. The root is always seeded into this set on
    /// initial load so the first page of replies renders
    /// immediately.
    var expandedIds: Set<String>

    /// Cursor for "Show more replies" pagination — the
    /// `created_at` of the *last* loaded child for each parent.
    /// `loadMoreSiblings` reads this and asks the service for
    /// children with `created_at > cursor`.
    var nextCursorByParent: [String: Date]

    /// True iff the most recent direct-replies page for a parent
    /// came back full, signalling there are likely more siblings
    /// to fetch. Drives the "Show more replies" affordance.
    var hasMoreByParent: [String: Bool]

    /// Parent ids whose direct-replies fetch is in flight. Used
    /// to swap "View N replies" / "Show more" buttons for inline
    /// spinners while the network call lands.
    var loadingByParent: Set<String>

    /// One row in the rendered thread column. `flattenForRender`
    /// returns these in display order so the view can
    /// `ForEach(items, id: \.id)` and dispatch on `case`.
    enum RenderItem: Identifiable, Equatable, Sendable {
        /// A post row. `depth` is the **visual indent depth**,
        /// already capped at 4 — `post.depth` may be larger
        /// (server clamps at 6) but the visual indent stops
        /// growing past 4 so deeply nested replies keep a
        /// usable text column.
        case post(Post, depth: Int, isExpanded: Bool)
        /// "View N replies" affordance under a post whose
        /// children haven't been fetched yet. Tap → expand.
        case viewReplies(parentId: String, count: Int, depth: Int)
        /// Inline spinner replacing the "View N replies" /
        /// "Show more replies" button while a fetch is in
        /// flight.
        case loadingChildren(parentId: String, depth: Int)
        /// "Show more replies" — appears after the last loaded
        /// child of an expanded parent when more siblings
        /// exist on the server.
        case showMoreSiblings(parentId: String, depth: Int)
        /// "Hide replies" — emitted at the bottom of each
        /// expanded non-root subtree as a closing bracket. Tap
        /// → view-model removes the parent from `expandedIds`,
        /// which re-routes `flattenForRender` back through the
        /// `viewReplies` branch on next render. Loaded children
        /// are kept in place so re-expanding is instant.
        case hideReplies(parentId: String, depth: Int)

        var id: String {
            switch self {
            case .post(let p, _, _): return "post-\(p.id)"
            case .viewReplies(let pid, _, _): return "view-\(pid)"
            case .loadingChildren(let pid, _): return "loading-\(pid)"
            case .showMoreSiblings(let pid, _): return "more-\(pid)"
            case .hideReplies(let pid, _): return "hide-\(pid)"
            }
        }
    }

    /// Walk the tree in pre-order, returning rows in display
    /// order. Only descends into `expandedIds`. Posts whose
    /// children haven't been loaded show as leaves regardless
    /// of `replyCount` — the affordance entries surface "View N
    /// replies" alongside them.
    func flattenForRender() -> [RenderItem] {
        var items: [RenderItem] = []
        let rootIsExpanded = expandedIds.contains(root.id)
        items.append(.post(root, depth: 0, isExpanded: rootIsExpanded))
        if rootIsExpanded {
            appendChildren(of: root.id, into: &items)
        }
        return items
    }

    /// Render the loaded children of `parentId`, plus the
    /// affordance row that follows the last child (Show more,
    /// loading spinner, or nothing). Recurses into any expanded
    /// child to render its own subtree.
    private func appendChildren(of parentId: String, into items: inout [RenderItem]) {
        let childIds = childrenByParent[parentId] ?? []

        for childId in childIds {
            guard let child = posts[childId] else { continue }
            let childIsExpanded = expandedIds.contains(child.id)
            items.append(.post(
                child,
                depth: Self.indentDepth(for: child.depth),
                isExpanded: childIsExpanded
            ))

            if childIsExpanded {
                appendChildren(of: child.id, into: &items)
                // Closing bracket for *this* expanded subtree —
                // drops in below the deepest descendant before
                // the next sibling iterates. Re-tap collapses
                // the subtree without dropping its loaded rows.
                items.append(.hideReplies(
                    parentId: child.id,
                    depth: Self.affordanceDepth(below: child.depth)
                ))
            } else if loadingByParent.contains(child.id) {
                // Mid-expand for *this* child: swap "View N
                // replies" for a spinner.
                items.append(.loadingChildren(
                    parentId: child.id,
                    depth: Self.affordanceDepth(below: child.depth)
                ))
            } else if child.replyCount > 0 {
                items.append(.viewReplies(
                    parentId: child.id,
                    count: child.replyCount,
                    depth: Self.affordanceDepth(below: child.depth)
                ))
            }
        }

        // Trailing affordance under the parent itself: either
        // we're paginating siblings (loading), or there are
        // more siblings to fetch (show-more), or neither —
        // nothing to draw.
        let trailingDepth = Self.affordanceDepth(below: posts[parentId]?.depth ?? -1)
        if loadingByParent.contains(parentId) {
            // Don't double-draw the loading spinner if it was
            // already emitted as the "swap for View N replies"
            // case under a *child* — that path bails out via
            // `childIsExpanded == false && loading[child] ==
            // true`. Here we're after the last loaded child of
            // this *parent*, paginating siblings.
            items.append(.loadingChildren(parentId: parentId, depth: trailingDepth))
        } else if hasMoreByParent[parentId] == true {
            items.append(.showMoreSiblings(parentId: parentId, depth: trailingDepth))
        }
    }

    // MARK: - Indent helpers

    /// Visual indent for a post — caps at 4 so depth-5 / depth-6
    /// posts read at the same indent as their depth-4 ancestor.
    /// (Server clamps actual `Post.depth` at 6; we cap one
    /// level shallower for visual breathing room.)
    static func indentDepth(for postDepth: Int) -> Int {
        min(max(postDepth, 0), 4)
    }

    /// Indent for an affordance row that visually belongs
    /// *under* a post with `parentDepth`. One step deeper than
    /// the parent, capped one step beyond the post indent cap
    /// so a depth-4 post's affordance still reads as "below"
    /// rather than "alongside".
    static func affordanceDepth(below parentDepth: Int) -> Int {
        min(max(parentDepth, -1) + 1, 5)
    }
}
