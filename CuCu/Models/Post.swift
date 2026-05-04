import Foundation

/// One post — fully hydrated for rendering. Decoded from the
/// `posts_with_author` SQL view, which joins `posts` with the
/// author's claimed username so the feed UI can render
/// `@username` without a per-row join.
///
/// Body is bounded at 500 characters server-side (the same limit
/// the compose sheet enforces locally) so feed cells can lay out
/// without runaway text. `parentId` is non-nil for replies; the
/// threading view follows `parentId` chains to render
/// conversations.
///
/// `likeCount` / `replyCount` are denormalised counters maintained
/// by triggers so feed rendering stays a single round-trip. They
/// flow through as `var` so `PostFeedViewModel` can apply
/// optimistic increments without rebuilding the whole struct.
nonisolated struct Post: Identifiable, Equatable, Sendable, Hashable {
    let id: String
    let authorId: String
    let authorUsername: String
    /// Direct parent of this post — nil for top-level posts.
    let parentId: String?
    /// Top-most ancestor of the thread. For top-level posts this
    /// equals `id`; for replies, it's the originating root.
    /// Threads are queried by `root_id` so a single SELECT
    /// returns every node in the conversation.
    let rootId: String?
    /// Depth from the root. Root = 0, top-level reply = 1, etc.
    /// Server-stamped via trigger and capped server-side at 6 so
    /// trees don't run away — past that depth replies still chain
    /// to the same root, they just stop indenting visually.
    let depth: Int
    let body: String
    var likeCount: Int
    var replyCount: Int
    let createdAt: Date
    /// Set by the `posts` UPDATE trigger when the body changes.
    /// Drives the "edited" tag in the row view.
    let editedAt: Date?
}

// MARK: - Wire shapes (read vs. write are split on purpose)
//
// Reads come from the `posts_with_author` view (which exposes
// `author_username`); writes go to the `posts` *table*, which
// does not have that column. Mixing one struct for both ends
// caused the "could not find the 'author_username' column of
// posts in the schema cache" failure on insert. Splitting them
// into Decodable-only / Encodable-only types keeps each payload
// honest about which relation it belongs to.

/// Decoded from a `posts_with_author` row. Decodable-only — never
/// used as an insert/update payload, so columns the view
/// surfaces but the underlying table doesn't (e.g.
/// `author_username`) can live here without leaking into a
/// write call.
nonisolated struct PostRow: Decodable, Sendable {
    let id: String
    let author_id: String
    let author_username: String
    let parent_id: String?
    let root_id: String?
    let depth: Int?
    let body: String
    let like_count: Int?
    let reply_count: Int?
    let created_at: String
    let edited_at: String?

    func toModel() -> Post {
        Post(
            id: id,
            authorId: author_id,
            authorUsername: author_username,
            parentId: parent_id,
            rootId: root_id,
            depth: depth ?? 0,
            body: body,
            likeCount: like_count ?? 0,
            replyCount: reply_count ?? 0,
            createdAt: Self.parseTimestamp(created_at) ?? .now,
            editedAt: edited_at.flatMap(Self.parseTimestamp)
        )
    }

    /// Postgres `timestamptz` ships as ISO-8601 either with or
    /// without fractional seconds depending on whether the trigger
    /// stamped `now()` or a manual call rounded to seconds. Try
    /// both rather than guess.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
