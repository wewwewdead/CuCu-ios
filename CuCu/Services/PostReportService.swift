import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Errors surfaced by the report-a-post flow. The `alreadyReported`
/// case is treated as a friendly "thanks, we already have it" path
/// in the UI rather than a retryable failure — duplicate reports
/// from the same viewer are mostly accidental double-taps.
enum PostReportError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case notSignedIn
    case noteTooLong(limit: Int)
    case alreadyReported
    case notAuthorized
    case network
    case database(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to enable reporting."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to enable reporting."
        case .notSignedIn:
            return "Sign in to report posts."
        case .noteTooLong(let limit):
            return "Notes can be up to \(limit) characters."
        case .alreadyReported:
            return "You already reported this post. Our team will review it soon."
        case .notAuthorized:
            return "You don't have permission to do that."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .database(let detail):
            return detail
        }
    }
}

/// Reads / writes `post_reports`. RLS policy summary:
///   - INSERT: `post_reports_insert_own` — the caller must be
///     `auth.uid() = reporter_id`. Unique constraint on
///     `(post_id, reporter_id)` enforces "one report per
///     viewer per post".
///   - SELECT / UPDATE: `post_reports_select` / `_update_mod` — the
///     `is_moderator(auth.uid())` predicate gates both, so non-mods
///     trying to read the queue come back empty rather than 403.
///   - The mod queue read goes through the
///     `post_reports_with_context` view (security_invoker = true)
///     which means RLS still applies — non-mods get an empty set.
nonisolated struct PostReportService {
    /// Hard ceiling on the optional explanation note. Mirrors the
    /// SQL `CHECK (length(note) <= 500)` so a client that gets past
    /// the local count still gets a clean error.
    static let noteCharacterLimit: Int = 500

    /// Insert a new report row. Returns Void — the caller has
    /// nothing useful to render with the report row beyond a
    /// success toast, and the queue is mod-only territory.
    func report(
        postId: String,
        reason: ReportReason,
        note rawNote: String?
    ) async throws {
        let trimmedNote = rawNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
        if let note, note.count > Self.noteCharacterLimit {
            throw PostReportError.noteTooLong(limit: Self.noteCharacterLimit)
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostReportError.notConfigured(reason: .missingCredentials)
        }
        guard let session = try? await client.auth.session else {
            throw PostReportError.notSignedIn
        }
        let reporterId = session.user.id.uuidString.lowercased()
        let payload = NewReportRow(
            post_id: postId,
            reporter_id: reporterId,
            reason: reason.rawValue,
            note: note
        )
        do {
            try await client
                .from("post_reports")
                .insert(payload)
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw PostReportError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Columns the queue read pulls from
    /// `post_reports_with_context`. Listed explicitly rather than
    /// `*` so adding a column to the view doesn't quietly enlarge
    /// every row the moderation panel pulls down.
    private static let queueColumns = "id,post_id,post_body,post_author_username,post_root_id,reporter_username,reason,note,status,created_at,reviewed_by,reviewed_at,reviewer_username"

    /// Pull every open report from `post_reports_with_context`,
    /// oldest first so moderators handle the backlog FIFO. The
    /// view is `security_invoker = true`, which means RLS still
    /// gates this: a non-mod calling this method gets an empty
    /// array, not a 403.
    func fetchOpenReports() async throws -> [Report] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostReportError.notConfigured(reason: .missingCredentials)
        }
        do {
            let rows: [ReportRow] = try await client
                .from("post_reports_with_context")
                .select(Self.queueColumns)
                .eq("status", value: ReportStatus.open.rawValue)
                .order("created_at", ascending: true)
                .execute()
                .value
            return rows.compactMap { $0.toModel() }
        } catch {
            throw mapError(error)
        }
        #else
        throw PostReportError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Audit-history read for the moderation queue's "History"
    /// segment. Returns reports in `.actioned` or `.dismissed`,
    /// newest first (most recently reviewed at the top so a
    /// moderator can see what they/their teammates just did).
    /// Capped at `limit` because the queue isn't paginated yet —
    /// 100 rows is plenty for a small mod team to scroll without
    /// pulling down the whole audit log.
    func fetchReviewedReports(limit: Int = 100) async throws -> [Report] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostReportError.notConfigured(reason: .missingCredentials)
        }
        do {
            let rows: [ReportRow] = try await client
                .from("post_reports_with_context")
                .select(Self.queueColumns)
                .neq("status", value: ReportStatus.open.rawValue)
                .order("reviewed_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            return rows.compactMap { $0.toModel() }
        } catch {
            throw mapError(error)
        }
        #else
        throw PostReportError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Promote a report from `open` → `actioned`. Called after a
    /// "Take down" succeeds (`PostService.deletePost`); both
    /// updates land in sequence rather than as a transaction
    /// because the mod's value here is "post is gone *and* my
    /// queue stops showing it" — partial failure (post deleted but
    /// report still queued) is annoying but recoverable.
    func markActioned(reportId: String) async throws {
        try await updateStatus(reportId: reportId, status: .actioned)
    }

    /// Promote a report from `open` → `dismissed`. No
    /// post-side effect — the post stays untouched.
    func markDismissed(reportId: String) async throws {
        try await updateStatus(reportId: reportId, status: .dismissed)
    }

    private func updateStatus(reportId: String, status: ReportStatus) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostReportError.notConfigured(reason: .missingCredentials)
        }
        // Stamp the reviewer + the moment of review on every status
        // mutation. The columns exist on `post_reports` for audit
        // purposes — we want to know which mod actioned which report
        // and when. PostgREST won't accept a Postgres `now()` call
        // through the table API, so we send an ISO-8601 string the
        // same way `PostService.deletePost` does.
        guard let session = try? await client.auth.session else {
            throw PostReportError.notSignedIn
        }
        let reviewerId = session.user.id.uuidString.lowercased()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = ReportStatusUpdate(
            status: status.rawValue,
            reviewed_by: reviewerId,
            reviewed_at: formatter.string(from: .now)
        )
        do {
            try await client
                .from("post_reports")
                .update(payload)
                .eq("id", value: reportId)
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw PostReportError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    #if canImport(Supabase)
    private func mapError(_ error: Error) -> PostReportError {
        if let pgErr = error as? PostgrestError {
            if pgErr.code == "23505" { return .alreadyReported }
            if pgErr.code == "42501" { return .notAuthorized }
        }
        let text = SupabaseErrorMapper.detail(error).lowercased()
        if text.contains("23505") || text.contains("duplicate key") {
            return .alreadyReported
        }
        if text.contains("row-level security") || text.contains("42501") {
            return .notAuthorized
        }
        if text.contains("note") && text.contains("check constraint") {
            return .noteTooLong(limit: Self.noteCharacterLimit)
        }
        if SupabaseErrorMapper.isNetwork(error) { return .network }
        return .database(SupabaseErrorMapper.detail(error))
    }
    #endif
}

// MARK: - Wire shapes

private nonisolated struct NewReportRow: Encodable {
    let post_id: String
    let reporter_id: String
    let reason: String
    let note: String?
}

private nonisolated struct ReportStatusUpdate: Encodable {
    let status: String
    let reviewed_by: String
    let reviewed_at: String
}
