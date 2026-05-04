import Foundation

/// Reasons a viewer can report a post. Mirrors the SQL CHECK
/// constraint on `post_reports.reason` exactly — keeping this
/// enum's rawValues in lockstep means a typo lands at compile
/// time, not as a runtime PostgREST 23514 from the database.
///
/// The display labels are deliberately separate from the raw
/// values so the wire format stays stable even when copy iterates.
nonisolated enum ReportReason: String, CaseIterable, Sendable, Equatable, Identifiable {
    case spam
    case harassment
    case sexual
    case violence
    case selfHarm = "self_harm"
    case other

    var id: String { rawValue }

    /// Human-readable label for the report sheet picker.
    var displayLabel: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harassment or bullying"
        case .sexual: return "Sexually explicit"
        case .violence: return "Violence or threats"
        case .selfHarm: return "Self-harm"
        case .other: return "Other"
        }
    }
}

/// Statuses a report can be in. Mirrors the SQL CHECK on
/// `post_reports.status`. The mod queue filters on `.open`; a
/// "Take down" promotes the row to `.actioned`, "Dismiss" to
/// `.dismissed`.
nonisolated enum ReportStatus: String, Sendable, Equatable {
    case open
    case actioned
    case dismissed
}

/// One row from the `post_reports_with_context` SQL view — a
/// flattened join of `post_reports`, the reported `posts` row,
/// and `usernames` (twice — once for the reporter, once for the
/// post author). The view exists so the moderation queue can
/// render every row in one round-trip; PostgREST's nested-embed
/// syntax is fragile when joining the same table twice via
/// different foreign keys, and the view is the cleaner cut.
nonisolated struct Report: Identifiable, Sendable, Equatable {
    let id: String
    let postId: String
    /// Body of the reported post (read at report time via the
    /// view's join). May be empty if the post was hard-deleted out
    /// from under the queue between fetch and render.
    let postBody: String
    /// Author of the reported post — `@handle` rendering only.
    let postAuthorUsername: String
    /// Top-most ancestor id of the reported post — fed to
    /// `PostThreadView(rootId:)` so a moderator can see context.
    /// Equal to `postId` when the reported post is itself a root.
    let postRootId: String
    /// Reporter's handle — same `@handle` treatment, but used only
    /// in the queue chrome to surface "who reported this".
    let reporterUsername: String
    let reason: ReportReason
    let note: String?
    let status: ReportStatus
    let createdAt: Date
    /// Audit trail — populated when a moderator actions or
    /// dismisses the report. Nil while the report is still
    /// `.open`.
    let reviewedBy: String?
    let reviewedAt: Date?
    /// Reviewer's handle, hydrated by the SQL view's third
    /// `usernames` join. Nil when `reviewedBy` is nil, or when
    /// the reviewer happens not to have a claimed handle (rare —
    /// every mod gets one through the picker).
    let reviewerUsername: String?
}

/// Wire shape decoded from `post_reports_with_context`. Snake-case
/// fields match the view's columns 1:1.
nonisolated struct ReportRow: Decodable, Sendable {
    let id: String
    let post_id: String
    let post_body: String?
    let post_author_username: String?
    let post_root_id: String?
    let reporter_username: String?
    let reason: String
    let note: String?
    let status: String
    let created_at: String
    let reviewed_by: String?
    let reviewed_at: String?
    let reviewer_username: String?

    func toModel() -> Report? {
        guard let reason = ReportReason(rawValue: reason),
              let status = ReportStatus(rawValue: status) else {
            return nil
        }
        let date = Self.parseTimestamp(created_at) ?? .now
        return Report(
            id: id,
            postId: post_id,
            postBody: post_body ?? "",
            postAuthorUsername: post_author_username ?? "unknown",
            // A reported root has post_root_id == post_id; the view
            // returns that explicitly. Fall back to post_id for
            // safety.
            postRootId: post_root_id ?? post_id,
            reporterUsername: reporter_username ?? "unknown",
            reason: reason,
            note: note,
            status: status,
            createdAt: date,
            reviewedBy: reviewed_by,
            reviewedAt: reviewed_at.flatMap(Self.parseTimestamp),
            reviewerUsername: reviewer_username
        )
    }

    /// Try fractional-seconds first (Postgres `now()` and trigger
    /// stamps), then fall back to whole-second ISO. Mirrors the
    /// helper on `PostRow`.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
