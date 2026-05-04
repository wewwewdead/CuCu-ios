import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// All errors the compose flow can surface. Drives clear inline
/// messages in `ComposePostSheet` without leaking SDK types.
enum PostError: Error, LocalizedError, Equatable {
    case notSignedIn
    case noUsername
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case bodyEmpty
    case bodyTooLong(limit: Int)
    case rateLimited
    case network
    case database(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You need to sign in to post."
        case .noUsername:
            return "Pick a username before posting."
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to enable posting."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to enable posting."
        case .bodyEmpty:
            return "Type something before posting."
        case .bodyTooLong(let limit):
            return "Posts can be up to \(limit) characters."
        case .rateLimited:
            return "You're posting a bit fast — try again in a minute."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .database(let detail):
            return "Couldn't save your post: \(detail)"
        case .unknown(let detail):
            return detail
        }
    }
}

/// Pure-IO wrapper around the `posts` table.
///
/// Writes target the `posts` *table* (with payloads that contain
/// only the columns the client owns). Reads target the
/// `posts_with_author` *view* — that's where `author_username`
/// lives. Each mutation re-fetches the affected row through the
/// view so the caller gets a fully-hydrated `Post` back without
/// the call site having to know about the read/write split.
nonisolated struct PostService {
    /// Hard ceiling enforced both client-side (compose sheet) and
    /// server-side (CHECK constraint on `posts.body`). Kept here as
    /// the single Swift constant so the view-model and the sheet's
    /// counter stay aligned.
    static let bodyCharacterLimit: Int = 500

    /// Default page size for feed reads. Big enough to fill the
    /// first viewport on iPad without pulling so much that the
    /// initial paint stalls on cellular.
    static let feedPageSize: Int = 25

    /// Default page size for the lazy thread expansion. Five is
    /// enough to read the start of a conversation without
    /// burying the rest of the screen; "Show more replies" walks
    /// forward from there.
    static let directRepliesPageSize: Int = 5

    /// Columns the read-side selects from `posts_with_author`.
    /// Listed explicitly rather than `*` so adding a column to the
    /// view (e.g., `bookmark_count`) doesn't quietly enlarge every
    /// row the feed pulls down.
    private static let readSelect = "id,author_id,author_username,parent_id,root_id,depth,body,like_count,reply_count,created_at,edited_at"

    /// Insert a new post owned by `user`, optionally as a reply to
    /// `parentId`. Returns the freshly-decoded `Post` so the caller
    /// can prepend it to a feed without a refetch.
    ///
    /// Two-step pattern:
    ///   1. INSERT into `posts` with a write-only payload — only
    ///      the columns the client supplies. Server-set columns
    ///      (`id`, `root_id`, `depth`, `reply_count`, `like_count`,
    ///      `created_at`, `edited_at`) come from defaults / triggers
    ///      and would error out the schema-cache check if included.
    ///   2. SELECT the new row from `posts_with_author` by id so
    ///      `author_username` (which only exists on the view) is
    ///      populated on the returned `Post`.
    func createPost(
        user: AppUser,
        body rawBody: String,
        parentId: String?
    ) async throws -> Post {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PostError.bodyEmpty }
        guard body.count <= Self.bodyCharacterLimit else {
            throw PostError.bodyTooLong(limit: Self.bodyCharacterLimit)
        }
        guard let username = user.username, !username.isEmpty else {
            throw PostError.noUsername
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        // Lowercase the author id so the row's `author_id` matches
        // `auth.uid()` byte-for-byte under any text-coerced RLS
        // compare — same canonicalisation `PublishService` does for
        // `user_id`.
        let payload = PostInsert(
            author_id: user.id.lowercased(),
            body: body,
            parent_id: parentId
        )

        do {
            // Step 1: insert into the table, ask for just the new
            // id back. PostgREST returns the inserted rows when
            // we chain `.select(...)`; we only need the id to
            // re-fetch through the view in step 2.
            let inserted: InsertedId = try await client
                .from("posts")
                .insert(payload)
                .select("id")
                .single()
                .execute()
                .value

            // Step 2: hydrate via the view so `author_username` is
            // populated. Single round-trip is acceptable here — a
            // fresh insert is a one-off per submit, not a hot path.
            return try await fetchHydrated(client: client, id: inserted.id)
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Update the body of an existing post. RLS on `posts`
    /// constrains updates to `auth.uid() = author_id`, so a
    /// non-owner request fails server-side rather than needing a
    /// client check. Returns the refreshed `Post` from the view.
    func editPost(
        postId: String,
        newBody rawBody: String
    ) async throws -> Post {
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PostError.bodyEmpty }
        guard body.count <= Self.bodyCharacterLimit else {
            throw PostError.bodyTooLong(limit: Self.bodyCharacterLimit)
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        let payload = PostUpdate(body: body)
        do {
            // The UPDATE itself doesn't need to return anything —
            // we re-fetch from the view in the next call to pick
            // up the trigger-stamped `edited_at` and the
            // denormalized `author_username`.
            try await client
                .from("posts")
                .update(payload)
                .eq("id", value: postId)
                .execute()

            return try await fetchHydrated(client: client, id: postId)
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Soft-delete: stamp `deleted_at = now()` on the row. The
    /// post stays in the table so reply chains don't lose their
    /// anchor; feeds filter on `deleted_at IS NULL`. Caller-side
    /// the call returns Void — there's no useful state to render
    /// for a row that's about to disappear from the feed.
    func softDelete(postId: String) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        // Encoded payload uses an ISO 8601 string so PostgREST
        // sees a JSON value for the `timestamptz` column instead
        // of trying to interpret a Swift `Date` directly. Letting
        // Postgres run `now()` would be cleaner but PostgREST
        // doesn't expose SQL functions through the table API —
        // a client-supplied timestamp is the standard workaround.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = PostSoftDelete(deleted_at: formatter.string(from: .now))

        do {
            try await client
                .from("posts")
                .update(payload)
                .eq("id", value: postId)
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    // MARK: - Reads

    /// Single-row read of the post identified by `id`. Used by
    /// `PostThreadViewModel` to fetch the root before the first
    /// page of replies — kept narrow on purpose so the thread
    /// view's initial paint is two short queries instead of one
    /// fat one.
    func fetchPost(id: String) async throws -> Post {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }
        do {
            return try await fetchHydrated(client: client, id: id)
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Direct replies of `parentId`, ordered ascending by
    /// `created_at`. Cursor parameter is `after` — when set, the
    /// query asks for siblings created **strictly after** the
    /// cursor so "Show more replies" walks forward through
    /// chronologically-ascending children.
    ///
    /// Note on the parameter name: the original spec called this
    /// cursor `before` with a `<` predicate, but combined with
    /// `ORDER BY created_at ASC` that scheme can't paginate
    /// forward — the initial load returns the oldest page and
    /// any subsequent `< before` query just re-asks for older
    /// rows that don't exist. Renaming to `after` (`>` predicate)
    /// preserves the intended UX: load the first chunk of
    /// replies, then walk forward sibling-by-sibling.
    func fetchDirectReplies(
        parentId: String,
        after cursor: Date? = nil,
        limit: Int = directRepliesPageSize
    ) async throws -> [Post] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        do {
            let baseSelect = client
                .from("posts_with_author")
                .select(Self.readSelect)
                .eq("parent_id", value: parentId)
                .is("deleted_at", value: nil)

            let rows: [PostRow]
            if let cursor {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                rows = try await baseSelect
                    .gt("created_at", value: isoFormatter.string(from: cursor))
                    .order("created_at", ascending: true)
                    .limit(limit)
                    .execute()
                    .value
            } else {
                rows = try await baseSelect
                    .order("created_at", ascending: true)
                    .limit(limit)
                    .execute()
                    .value
            }
            return rows.map { $0.toModel() }
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Latest top-level posts, newest first. Cursor-based: pass the
    /// `createdAt` of the last row from the previous page to fetch
    /// the next slice. Mirrors `PublishedProfileService.fetchLatest`
    /// — cursor pagination beats offset because new posts appearing
    /// at the top of the feed can't shift the page window beneath
    /// the user mid-scroll.
    ///
    /// Filters server-side to top-level posts (`parent_id IS NULL`)
    /// so the global feed reads as a column of conversations rather
    /// than a flattened jumble of replies. The thread view is the
    /// surface that exposes replies.
    ///
    /// Caller is expected to also batch-call
    /// `PostLikeService.fetchLikeState(postIds:)` after each fetch
    /// to hydrate viewer-liked state for the visible page.
    func fetchFeed(
        before cursor: Date? = nil,
        limit: Int = feedPageSize
    ) async throws -> [Post] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        do {
            // Each branch builds its own end-to-end pipeline because
            // supabase-swift's typed builder produces a different
            // concrete type after each `.eq` / `.lt` chain — a
            // single `var` of one nominal type doesn't compose.
            let baseSelect = client
                .from("posts_with_author")
                .select(Self.readSelect)
                .is("parent_id", value: nil)
                .is("deleted_at", value: nil)

            let rows: [PostRow]
            if let cursor {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                rows = try await baseSelect
                    .lt("created_at", value: isoFormatter.string(from: cursor))
                    .order("created_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            } else {
                rows = try await baseSelect
                    .order("created_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            }
            return rows.map { $0.toModel() }
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Latest top-level posts authored by a single user, newest
    /// first. Same cursor pagination shape as `fetchFeed` — pass the
    /// `createdAt` of the last loaded row to advance. Powers the
    /// per-profile Posts section on `PublishedProfileView` and the
    /// `UserPostsListView` "View all" surface.
    ///
    /// `authorId` is normalised to lowercase to match the
    /// canonicalisation rule the insert path applies (`auth.uid()`
    /// is byte-compared against `author_id`).
    func fetchUserPosts(
        authorId: String,
        before cursor: Date? = nil,
        limit: Int = feedPageSize
    ) async throws -> [Post] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        do {
            let baseSelect = client
                .from("posts_with_author")
                .select(Self.readSelect)
                .eq("author_id", value: authorId.lowercased())
                .is("parent_id", value: nil)
                .is("deleted_at", value: nil)

            let rows: [PostRow]
            if let cursor {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                rows = try await baseSelect
                    .lt("created_at", value: isoFormatter.string(from: cursor))
                    .order("created_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            } else {
                rows = try await baseSelect
                    .order("created_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            }
            return rows.map { $0.toModel() }
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Pull a full thread for `rootId` — the root post plus every
    /// descendant — in a single round-trip. **The iOS thread
    /// view no longer calls this** (it lazy-loads via
    /// `fetchPost` + `fetchDirectReplies`); the call is kept for
    /// share-card / future server-rendered surfaces that genuinely
    /// need the whole conversation in one shot.
    ///
    /// Returns a fully-expanded `PostThread`: every loaded
    /// descendant is in `posts`, every parent's children are
    /// listed in `childrenByParent`, and every parent appears in
    /// `expandedIds`. There's no pagination state — `hasMore`
    /// and cursors stay empty since there's nothing left to
    /// fetch.
    func fetchThread(rootId: String) async throws -> PostThread {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostError.notConfigured(reason: .missingCredentials)
        }

        do {
            // Pull every node in the conversation (root + descendants)
            // in one shot — the view exposes `root_id`, so a single
            // equality predicate covers the whole subtree.
            let rows: [PostRow] = try await client
                .from("posts_with_author")
                .select(Self.readSelect)
                .eq("root_id", value: rootId)
                .is("deleted_at", value: nil)
                .order("depth", ascending: true)
                .order("created_at", ascending: true)
                .execute()
                .value

            guard let rootRow = rows.first(where: { $0.id == rootId }) else {
                throw PostError.database("Thread not found.")
            }
            let allPosts = rows.map { $0.toModel() }
            let root = rootRow.toModel()

            // Build the dictionary-backed tree in one pass.
            var posts: [String: Post] = [:]
            var childrenByParent: [String: [String]] = [:]
            var expandedIds: Set<String> = []
            for post in allPosts {
                posts[post.id] = post
                expandedIds.insert(post.id)
                if childrenByParent[post.id] == nil {
                    childrenByParent[post.id] = []
                }
                if let parent = post.parentId, parent != post.id {
                    childrenByParent[parent, default: []].append(post.id)
                }
            }
            // Children should still render in created_at
            // ascending order regardless of how the server
            // returned them.
            for (parentId, ids) in childrenByParent {
                let sorted = ids.sorted { lhsId, rhsId in
                    guard let l = posts[lhsId], let r = posts[rhsId] else { return false }
                    return l.createdAt < r.createdAt
                }
                childrenByParent[parentId] = sorted
            }

            return PostThread(
                root: root,
                posts: posts,
                childrenByParent: childrenByParent,
                expandedIds: expandedIds,
                nextCursorByParent: [:],
                hasMoreByParent: [:],
                loadingByParent: []
            )
        } catch let err as PostError {
            throw err
        } catch {
            throw mapError(error)
        }
        #else
        throw PostError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    // MARK: - Helpers

    #if canImport(Supabase)
    /// Single hydrated read from the view. Centralised so create /
    /// edit hit the exact same column list and error handling.
    private func fetchHydrated(client: SupabaseClient, id: String) async throws -> Post {
        let row: PostRow = try await client
            .from("posts_with_author")
            .select(Self.readSelect)
            .eq("id", value: id)
            .single()
            .execute()
            .value
        return row.toModel()
    }

    /// Translate raw Supabase / Postgres errors into the typed
    /// `PostError` cases the UI knows how to render.
    ///
    /// Rate limiting on the `posts` table is enforced by a Postgres
    /// trigger that raises `P0001` with a message containing "rate"
    /// when a user exceeds the per-hour quota — substring-matching
    /// rather than relying on a specific SQLSTATE because the trigger
    /// implementation is owned by the backend and may evolve.
    private func mapError(_ error: Error) -> PostError {
        let text = SupabaseErrorMapper.detail(error).lowercased()

        if let pgErr = error as? PostgrestError {
            // Postgres custom raise with `RAISE EXCEPTION` lands
            // here as P0001 — that's the rate-limit trigger's
            // SQLSTATE.
            if pgErr.code == "P0001" {
                return .rateLimited
            }
        }

        if text.contains("rate limit")
            || text.contains("rate_limit")
            || text.contains("too many requests")
            || text.contains("posting too") {
            return .rateLimited
        }

        if SupabaseErrorMapper.isNetwork(error) {
            return .network
        }

        // CHECK constraint failures land here — surface the limit
        // case so the UI shows the same message it would for a
        // pre-flight reject.
        if text.contains("body_length") || text.contains("check constraint") {
            return .bodyTooLong(limit: Self.bodyCharacterLimit)
        }

        return .database(SupabaseErrorMapper.detail(error))
    }
    #endif
}

// MARK: - Wire payloads (write-only)

/// INSERT into `public.posts`. Only the three columns the client
/// supplies — every other column on the table is server-set
/// (default expression or trigger).
private nonisolated struct PostInsert: Encodable {
    let author_id: String
    let body: String
    let parent_id: String?
}

/// UPDATE on `public.posts` for an edit. Just the body — `edited_at`
/// is stamped by a row trigger, not the client.
private nonisolated struct PostUpdate: Encodable {
    let body: String
}

/// UPDATE on `public.posts` for a soft delete. Carries `deleted_at`
/// alone so feeds can filter the row out.
private nonisolated struct PostSoftDelete: Encodable {
    let deleted_at: String
}

/// One-field decoder for the id PostgREST hands back from an
/// INSERT-with-`.select("id")` chain.
private nonisolated struct InsertedId: Decodable, Sendable {
    let id: String
}
