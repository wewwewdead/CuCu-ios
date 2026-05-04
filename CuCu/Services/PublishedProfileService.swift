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

    /// Username is normalized to lowercase before the query so the
    /// match is case-insensitive (Postgres comparison is exact, but the
    /// publish-side `UsernameValidator` lowercases on write).
    func fetch(username rawUsername: String) async throws -> PublishedProfile {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !username.isEmpty else { throw PublishedProfileError.usernameInvalid }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }

        do {
            let row: PublishedProfileRow = try await client
                .from("profiles")
                .select("id,user_id,username,design_json,is_published,created_at,updated_at,published_at")
                .eq("username", value: username)
                .eq("is_published", value: true)
                .limit(1)
                .single()
                .execute()
                .value
            return row.toModel()
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            // Supabase 'PGRST116' is the "0 rows on .single()" error —
            // means the row doesn't exist or is unpublished. That's a
            // clean 'not found' for the viewer, not an error to log.
            let text = String(describing: error).lowercased()
            if text.contains("pgrst116") || text.contains("0 rows") || text.contains("no rows") {
                throw PublishedProfileError.notFound
            }
            if SupabaseErrorMapper.isNetwork(error) {
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
                     before cursor: Date? = nil) async throws -> [PublishedProfileSummary] {
        #if canImport(Supabase)
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
            if let cursor {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let cursorString = isoFormatter.string(from: cursor)
                rows = try await baseSelect
                    .lt("published_at", value: cursorString)
                    .order("published_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            } else {
                rows = try await baseSelect
                    .order("published_at", ascending: false)
                    .limit(limit)
                    .execute()
                    .value
            }
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
                limit: Int = listPageSize) async throws -> [PublishedProfileSummary] {
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

        do {
            let rows: [PublishedProfileSummaryRow] = try await client
                .from("published_profile_stats")
                .select(Self.summarySelect)
                .ilike("username", pattern: pattern)
                .order("published_at", ascending: false)
                .limit(limit)
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

    /// Fetch the published profile feed ranked by the SQL view's MVP hot
    /// score: votes in the last 24h carry the most weight, then votes in the
    /// last 7d, then total votes.
    func fetchHottest(limit: Int = listPageSize) async throws -> [PublishedProfileSummary] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishedProfileError.notConfigured(reason: .missingCredentials)
        }
        do {
            let rows: [PublishedProfileSummaryRow] = try await client
                .from("published_profile_stats")
                .select(Self.summarySelect)
                .order("hot_score", ascending: false)
                .order("published_at", ascending: false)
                .limit(limit)
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
}
