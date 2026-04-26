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
@MainActor
struct PublishedProfileService {
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
            if (error as NSError).domain == NSURLErrorDomain {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(error.localizedDescription)
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

    /// Fetch the latest published profiles, ordered by `published_at`
    /// (falling back to `updated_at` for older rows that predate the
    /// `published_at` column). The query selects only the summary
    /// columns — `design_json` is intentionally omitted so 20 rows of
    /// the feed stay light.
    ///
    /// Pagination is **cursor-based** via the `before` parameter: pass
    /// the `sortDate` of the last row from the previous page and the
    /// next call returns rows published strictly before that
    /// timestamp. Cursor pagination beats offset-based here because
    /// new publishes inserted at the top can't shift the page window.
    ///
    /// RLS: only `is_published = true` rows are returned, both via
    /// the `eq` here and the `Published profiles are public-readable`
    /// policy on the `profiles` table — anonymous viewers see the
    /// same set the policy permits.
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
                .from("profiles")
                .select("id,username,thumbnail_url,published_at,updated_at")
                .eq("is_published", value: true)

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
            if (error as NSError).domain == NSURLErrorDomain {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(error.localizedDescription)
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
                .from("profiles")
                .select("id,username,thumbnail_url,published_at,updated_at")
                .eq("is_published", value: true)
                .ilike("username", pattern: pattern)
                .order("published_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            return rows.map { $0.toModel() }
        } catch let decodeErr as DecodingError {
            throw PublishedProfileError.decode(String(describing: decodeErr))
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                throw PublishedProfileError.network
            }
            throw PublishedProfileError.unknown(error.localizedDescription)
        }
        #else
        throw PublishedProfileError.notConfigured(reason: .packageNotAdded)
        #endif
    }
}
