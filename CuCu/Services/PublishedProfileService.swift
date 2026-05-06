import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Errors surfaced to the public viewer. Each maps to a user-facing
/// state in `PublishedProfileView` (loading / not found / network error).
enum PublishedProfileError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case notFound
    case usernameInvalid
    case network
    case decode(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to view profiles."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to view profiles."
        case .notFound:
            return "We couldn't find that profile."
        case .usernameInvalid:
            return "That username doesn't look right."
        case .network:
            return "Couldn't reach Supabase. Check your connection and try again."
        case .decode(let detail):
            return "We received the profile but couldn't read it (\(detail))."
        case .unknown(let detail):
            return detail
        }
    }
}

/// Reads from Supabase: the public viewer's only data path.
///
/// Selects only `is_published = true` so unpublished drafts are not
/// readable through the anon key — RLS already enforces this server-side
/// (see `Supabase/schema_publish_profiles.sql`); the explicit `eq` here
/// makes the contract obvious at the call site too.
nonisolated struct PublishedProfileService {
    private static let summarySelect = "profile_id,username,thumbnail_url,published_at,updated_at,vote_count,votes_last_24h,votes_last_7d,hot_score"

    /// Column list for the full row — used by `fetch(username:)` /
    /// `fetch(userId:)` and the cache-miss path. `design_json` is the
    /// expensive piece (commonly tens of KB per row) so the head-check
    /// path below avoids it whenever the cache is current.
    private static let fullRowSelect = "id,user_id,username,design_json,is_published,created_at,updated_at,published_at"

    /// Tiny shape used by the freshness probe. Just the row id and
    /// timestamps — a few hundred bytes on the wire vs the multi-KB
    /// full row. Keyed off the same predicates the full fetches use
    /// (username + is_published, or user_id + is_published) so an
    /// unpublish disappears from the head check the same way it
    /// disappears from the full read.
    private struct UpdatedAtFragment: Decodable, Sendable {
        let id: String?
        let updated_at: String?
        let published_at: String?
    }

    /// Username is normalized to lowercase before the query so the
    /// match is case-insensitive (Postgres comparison is exact, but the
    /// publish-side `UsernameValidator` lowercases on write).
    ///
    /// Cache strategy: when a previous fetch landed an entry, do a
    /// freshness probe that only pulls the row's `updated_at`. If the
    /// server's value matches the cached fingerprint, return the
    /// cached `PublishedProfile` and skip the full `design_json`
    /// download entirely. On network failure with a cache present,
    /// we serve the cache so the viewer stays usable offline; cache
    /// invalidation on `notFound` keeps unpublished rows from
    /// lingering after a delete.
    func fetch(username rawUsername: String) async throws -> PublishedProfile {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !username.isEmpty else { throw PublishedProfileError.usernameInvalid }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }

        // Cache + head-check fast path. The probe is `select("id,updated_at,published_at")`
        // — a few hundred bytes versus the multi-KB row.
        let cached = PublishedProfileCache.shared.read(username: username)
        if let cached {
            // Session-fresh fast-fast path: skip the head check too
            // when this entry was just validated (≤60s ago). Common
            // case: user taps profile → dismisses → taps again. The
            // staleness window is bounded by `sessionFreshTTL`.
            if PublishedProfileCache.shared.isSessionFresh(username: username) {
                return cached.profile
            }
            do {
                let head: UpdatedAtFragment = try await client
                    .from("profiles")
                    .select("id,updated_at,published_at")
                    .eq("username", value: username)
                    .eq("is_published", value: true)
                    .limit(1)
                    .single()
                    .execute()
                    .value
                if let serverUpdated = head.updated_at,
                   let cachedUpdated = cached.updatedAtRaw,
                   serverUpdated == cachedUpdated {
                    PublishedProfileCache.shared.markSessionFresh(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    return cached.profile
                }
                // Fall through to full fetch — the cache is stale.
            } catch {
                let text = String(describing: error).lowercased()
                if text.contains("pgrst116") || text.contains("0 rows") || text.contains("no rows") {
                    PublishedProfileCache.shared.invalidate(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    PublishedProfileCache.shared.clearSessionFresh(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    throw PublishedProfileError.notFound
                }
                if SupabaseErrorMapper.isNetwork(error) {
                    // Offline / dropped connection — serve the cache.
                    return cached.profile
                }
                // Other errors fall through to the full fetch so the
                // user can still recover via a normal network round
                // trip rather than being pinned to a stale cache.
            }
        }

        do {
            let row: PublishedProfileRow = try await client
                .from("profiles")
                .select(Self.fullRowSelect)
                .eq("username", value: username)
                .eq("is_published", value: true)
                .limit(1)
                .single()
                .execute()
                .value
            let profile = row.toModel()
            PublishedProfileCache.shared.write(
                profile: profile,
                updatedAtRaw: row.updated_at,
                publishedAtRaw: row.published_at
            )
            PublishedProfileCache.shared.markSessionFresh(
                username: profile.username,
                userId: profile.userId
            )
            return profile
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            // Supabase 'PGRST116' is the "0 rows on .single()" error —
            // means the row doesn't exist or is unpublished. That's a
            // clean 'not found' for the viewer, not an error to log.
            let text = String(describing: error).lowercased()
            if text.contains("pgrst116") || text.contains("0 rows") || text.contains("no rows") {
                if let cached {
                    PublishedProfileCache.shared.invalidate(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    PublishedProfileCache.shared.clearSessionFresh(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                }
                throw PublishedProfileError.notFound
            }
            if SupabaseErrorMapper.isNetwork(error) {
                if let cached { return cached.profile }
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Fetch the signed-in user's latest published profile by Supabase
    /// `auth.users.id`. This is the right bootstrap path for a fresh
    /// device because the session always has `user.id`, while the local
    /// username cache may still be empty or unavailable.
    ///
    /// Same cache+head-check pattern as `fetch(username:)`. The two
    /// paths share an on-disk cache keyed on both `username` and
    /// `userId`, so a profile fetched once via either path is served
    /// from cache when re-fetched via the other.
    func fetch(userId rawUserId: String) async throws -> PublishedProfile {
        let userId = rawUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !userId.isEmpty else { throw PublishedProfileError.notFound }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }

        let cached = PublishedProfileCache.shared.read(userId: userId)
        if let cached {
            if PublishedProfileCache.shared.isSessionFresh(userId: userId) {
                return cached.profile
            }
            do {
                let head: UpdatedAtFragment = try await client
                    .from("profiles")
                    .select("id,updated_at,published_at")
                    .eq("user_id", value: userId)
                    .eq("is_published", value: true)
                    .order("published_at", ascending: false)
                    .limit(1)
                    .single()
                    .execute()
                    .value
                if let serverUpdated = head.updated_at,
                   let cachedUpdated = cached.updatedAtRaw,
                   serverUpdated == cachedUpdated {
                    PublishedProfileCache.shared.markSessionFresh(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    return cached.profile
                }
            } catch {
                let text = String(describing: error).lowercased()
                if text.contains("pgrst116") || text.contains("0 rows") || text.contains("no rows") {
                    PublishedProfileCache.shared.invalidate(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    PublishedProfileCache.shared.clearSessionFresh(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    throw PublishedProfileError.notFound
                }
                if SupabaseErrorMapper.isNetwork(error) {
                    return cached.profile
                }
            }
        }

        do {
            let row: PublishedProfileRow = try await client
                .from("profiles")
                .select(Self.fullRowSelect)
                .eq("user_id", value: userId)
                .eq("is_published", value: true)
                .order("published_at", ascending: false)
                .limit(1)
                .single()
                .execute()
                .value
            let profile = row.toModel()
            PublishedProfileCache.shared.write(
                profile: profile,
                updatedAtRaw: row.updated_at,
                publishedAtRaw: row.published_at
            )
            PublishedProfileCache.shared.markSessionFresh(
                username: profile.username,
                userId: profile.userId
            )
            return profile
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            let text = String(describing: error).lowercased()
            if text.contains("pgrst116") || text.contains("0 rows") || text.contains("no rows") {
                if let cached {
                    PublishedProfileCache.shared.invalidate(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                    PublishedProfileCache.shared.clearSessionFresh(
                        username: cached.profile.username,
                        userId: cached.profile.userId
                    )
                }
                throw PublishedProfileError.notFound
            }
            if SupabaseErrorMapper.isNetwork(error) {
                if let cached { return cached.profile }
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    // MARK: - Explore list

    /// Default page size for the explore feed. Big enough to fill the
    /// first viewport on iPad, small enough to load fast on cellular.
    /// `nonisolated` so default-parameter expressions on the methods
    /// below can reference it without crossing the `@MainActor`
    /// boundary (Swift 6 strict-concurrency-friendly).
    nonisolated static let listPageSize: Int = 20

    /// Fetch the latest published profiles, ordered by `published_at`.
    /// The query reads the `published_profile_stats` view so card vote
    /// counts travel with the same lightweight summary rows. `design_json`
    /// is intentionally omitted so 20 rows of the feed stay light.
    ///
    /// Pagination is **cursor-based** via the `before` parameter: pass
    /// the `sortDate` of the last row from the previous page and the
    /// next call returns rows published strictly before that
    /// timestamp. Cursor pagination beats offset-based here because
    /// new publishes inserted at the top can't shift the page window.
    ///
    /// RLS: the SQL view filters to `profiles.is_published = true`, and
    /// its `security_invoker` setting keeps the underlying table policies
    /// active for anonymous viewers.
    func fetchLatest(limit: Int = listPageSize,
                     before cursor: Date? = nil,
                     category: String? = nil) async throws -> [PublishedProfileSummary] {
        #if canImport(Supabase)
        // First-page only — use the 60s in-memory snapshot if it's
        // fresh. Pagination cursors must always go to the wire so
        // page boundaries stay aligned with `published_at`. The
        // category-filtered path bypasses the cache so a chip flip
        // doesn't return a stale "All" snapshot under a filter pill.
        if cursor == nil, category == nil, limit == Self.listPageSize,
           let cached = await ExploreListCache.shared.latest() {
            return cached
        }
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }
        do {
            // Build the query in steps; supabase-swift's typed builder
            // returns a different concrete type after each `.eq` /
            // `.lt`, so a `var` of one nominal type doesn't work —
            // each branch executes its own end-to-end pipeline.
            let baseSelect = client
                .from("published_profile_stats")
                .select(Self.summarySelect)

            let rows: [PublishedProfileSummaryRow]
            switch (cursor, category) {
            case (nil, nil):
                rows = try await baseSelect
                    .order("published_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            case (let cursor?, nil):
                let cursorString = isoFormat(cursor)
                rows = try await baseSelect
                    .lt("published_at", value: cursorString)
                    .order("published_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            case (nil, let category?):
                rows = try await baseSelect
                    .eq("category", value: category)
                    .order("published_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            case (let cursor?, let category?):
                let cursorString = isoFormat(cursor)
                rows = try await baseSelect
                    .eq("category", value: category)
                    .lt("published_at", value: cursorString)
                    .order("published_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            }
            let summaries = rows.map { $0.toModel() }
            // Stamp the first-page snapshot so subsequent calls in
            // the next 60s short-circuit at the top — but only the
            // un-filtered path; we don't cache per-category lists in
            // this layer.
            if cursor == nil, category == nil, limit == Self.listPageSize {
                await ExploreListCache.shared.setLatest(summaries)
            }
            return summaries
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Compact ISO-8601 formatter used by the category-aware fetch
    /// branches above. Pulled out so each switch arm doesn't
    /// re-instantiate the formatter; the cost is negligible per call
    /// but keeping the cursor formatting in one place avoids drift.
    private func isoFormat(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Case-insensitive substring search by `username`. Empty /
    /// whitespace queries fall through to `fetchLatest`.
    ///
    /// Display name and bio columns were removed from the schema in
    /// favor of canvas-rendered identity, so only the username column
    /// is searched. ILIKE on a Postgres text column is the standard
    /// "case-insensitive substring" match — wrapping the user's
    /// query in `%` does substring matching, escape-sensitive to
    /// literal `%` / `_` which we scrub upstream.
    func search(query rawQuery: String,
                limit: Int = listPageSize,
                offset: Int = 0) async throws -> [PublishedProfileSummary] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await fetchLatest(limit: limit, before: nil)
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }
        // Strip the LIKE wildcards out of user input so a typed `%`
        // doesn't change the match semantics. Supabase escaping is
        // not granular enough to inline-quote these safely.
        let safe = trimmed
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "_", with: "")
        let pattern = "%\(safe)%"
        let from = max(offset, 0)
        let to = from + max(limit, 1) - 1

        do {
            let rows: [PublishedProfileSummaryRow] = try await client
                .from("published_profile_stats")
                .select(Self.summarySelect)
                .ilike("username", pattern: pattern)
                .order("published_at", ascending: false)
                .range(from: from, to: to)
                .execute()
                .value
            return rows.map { $0.toModel() }
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    // MARK: - Banner enrichment

    /// One profile's page-background fragment, extracted out of
    /// `design_json` server-side via PostgREST's JSONB `->>` operator.
    /// Used by the explore feed's banner cards so each row can render
    /// against the user's own canvas background without paying for
    /// the rest of the scene graph.
    nonisolated struct BackgroundFragment: Sendable, Equatable {
        let profileId: String
        let backgroundImageURL: String?
        let backgroundHex: String?
        /// Hero avatar URL pulled from the published document's
        /// top-level `heroAvatarURL` key (denormalized at publish
        /// time). Lets the explore-feed banner render the user's
        /// actual avatar without paying for the full scene graph.
        let heroAvatarURL: String?
    }

    private struct BackgroundFragmentRow: Decodable, Sendable {
        let id: String?
        let profile_id: String?
        let background_image_url: String?
        let background_hex: String?
        let hero_avatar_url: String?
    }

    /// Fetch the page-background URL + hex for a batch of published
    /// profiles, using a JSONB projection so the server only sends
    /// the two text fields we need (instead of the whole `design_json`
    /// payload, which can be megabytes per row).
    ///
    /// `pageBackgroundImagePath` is rewritten to a public URL by
    /// `PublishedDocumentTransformer.transform(_:replacing:)` during
    /// publish, so the value extracted here is directly loadable by
    /// `CachedRemoteImage`. Same goes for the hex tone — it sits at
    /// the top of the encoded `ProfileDocument` (mirrored from the
    /// first page) for backward compatibility.
    ///
    /// Failures are surfaced rather than swallowed so the caller (the
    /// explore feed) can decide whether to log + continue with the
    /// fallback gradient or retry on the next refresh.
    func fetchBackgrounds(for ids: [String]) async throws -> [String: BackgroundFragment] {
        guard !ids.isEmpty else { return [:] }
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }
        // PostgREST select with JSONB extraction. `->>` returns the
        // value as text — perfect for a URL or a "#RRGGBB" hex.
        // Aliasing (`alias:column->>key`) renames the column on the
        // wire so our Decodable shape can stay tidy.
        let select = "profile_id:id," +
            "background_image_url:design_json->>pageBackgroundImagePath," +
            "background_hex:design_json->>pageBackgroundHex," +
            "hero_avatar_url:design_json->>heroAvatarURL"
        do {
            let rows: [BackgroundFragmentRow] = try await client
                .from("profiles")
                .select(select)
                .in("id", values: ids)
                .eq("is_published", value: true)
                .execute()
                .value
            var out: [String: BackgroundFragment] = [:]
            for row in rows {
                let id = row.profile_id ?? row.id ?? ""
                guard !id.isEmpty else { continue }
                out[id] = BackgroundFragment(
                    profileId: id,
                    backgroundImageURL: row.background_image_url,
                    backgroundHex: row.background_hex,
                    heroAvatarURL: row.hero_avatar_url
                )
            }
            return out
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Username-keyed avatar lookup. Used by `PostFeedView` to paint
    /// each post's row with the author's real hero avatar (when the
    /// author has published a profile) instead of the bookplate
    /// letter fallback. Mirrors `fetchBackgrounds(for:)` but keyed
    /// on `username` because posts carry the author's handle, not
    /// the profile-id.
    ///
    /// Returns a `[lowercaseUsername: avatarURL]` dictionary so the
    /// caller can do an O(1) lookup per row. Authors who haven't
    /// published — or who published without a hero avatar — are
    /// simply absent from the map; the row keeps its letter
    /// fallback.
    func fetchAvatars(forUsernames usernames: [String]) async throws -> [String: String] {
        let normalized = Array(Set(usernames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return [:] }
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }
        struct AvatarRow: Decodable, Sendable {
            let username: String?
            let hero_avatar_url: String?
        }
        let select = "username,hero_avatar_url:design_json->>heroAvatarURL"
        do {
            let rows: [AvatarRow] = try await client
                .from("profiles")
                .select(select)
                .in("username", values: normalized)
                .eq("is_published", value: true)
                .execute()
                .value
            var out: [String: String] = [:]
            for row in rows {
                guard let u = row.username?.lowercased(),
                      let url = row.hero_avatar_url,
                      !url.isEmpty else { continue }
                out[u] = url
            }
            return out
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Fetch the published profile feed ranked by the SQL view's MVP hot
    /// score: votes in the last 24h carry the most weight, then votes in the
    /// last 7d, then total votes.
    ///
    /// Pagination is **offset-based** (`.range(from:to:)`) rather than
    /// cursor-based: `hot_score` is a derived value that recalculates on
    /// every vote, so a cursor on it would drift mid-scroll. Offset
    /// pages can shift if a row's score crosses a page boundary between
    /// fetches, so the caller must de-dupe by `id` before appending.
    func fetchHottest(limit: Int = listPageSize,
                      offset: Int = 0,
                      category: String? = nil) async throws -> [PublishedProfileSummary] {
        #if canImport(Supabase)
        // First-page fast path. Same TTL discipline as `fetchLatest`
        // — paginated reads (offset > 0) bypass the snapshot. The
        // category-filtered path skips the cache so a chip flip
        // doesn't return a stale "All" hottest snapshot.
        if offset == 0, category == nil, limit == Self.listPageSize,
           let cached = await ExploreListCache.shared.hottest() {
            return cached
        }
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }
        let from = max(offset, 0)
        let to = from + max(limit, 1) - 1
        do {
            let baseSelect = client
                .from("published_profile_stats")
                .select(Self.summarySelect)
            let rows: [PublishedProfileSummaryRow]
            if let category {
                rows = try await baseSelect
                    .eq("category", value: category)
                    .order("hot_score", ascending: false)
                    .order("published_at", ascending: false)
                    .range(from: from, to: to)
                    .execute()
                    .value
            } else {
                rows = try await baseSelect
                    .order("hot_score", ascending: false)
                    .order("published_at", ascending: false)
                    .range(from: from, to: to)
                    .execute()
                    .value
            }
            let summaries = rows.map { $0.toModel() }
            if offset == 0, category == nil, limit == Self.listPageSize {
                await ExploreListCache.shared.setHottest(summaries)
            }
            return summaries
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }
}
