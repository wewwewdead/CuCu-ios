import Foundation

/// Decoded representation of a row in the Supabase `profiles` table.
///
/// The `design_json` jsonb column contains a JSON-encoded `ProfileDocument`
/// — the v2 scene graph that the canvas editor and the public viewer
/// both render from. We decode the column into `ProfileDocument` here so
/// callers can render directly without an extra parse step.
///
/// Note: the prototype carried `display_name` + `bio` columns; both were
/// removed because the canvas itself is the right place for any "About"
/// content the author wants to publish — duplicate fields above the
/// canvas confused the design and split the source of truth.
nonisolated struct PublishedProfile: Sendable, Equatable {
    let id: String
    let userId: String
    let username: String
    let document: ProfileDocument
    let isPublished: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let publishedAt: Date?
}

/// Wire-level row decoded from `client.from("profiles").select(...)`.
/// Field names map 1:1 to Postgres columns (snake_case). Public typed
/// surface (`PublishedProfile`) is built from this in
/// `PublishedProfileService.fetch(...)`.
nonisolated struct PublishedProfileRow: Decodable, Sendable {
    let id: String
    let user_id: String
    let username: String
    let design_json: ProfileDocument
    let is_published: Bool
    let created_at: String?
    let updated_at: String?
    let published_at: String?

    func toModel() -> PublishedProfile {
        let formatter = ISO8601DateFormatter()
        // Supabase emits timestamps with fractional seconds — both formats
        // are accepted by the SDK and we tolerate either at decode time.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PublishedProfile(
            id: id,
            userId: user_id,
            username: username,
            document: design_json,
            isPublished: is_published,
            createdAt: created_at.flatMap { formatter.date(from: $0) },
            updatedAt: updated_at.flatMap { formatter.date(from: $0) },
            publishedAt: published_at.flatMap { formatter.date(from: $0) }
        )
    }
}

// MARK: - Lightweight list summary

/// Card-row representation used by the explore list — strictly the
/// minimum fields needed to render a tappable summary. The heavy
/// `design_json` is **not** fetched here so 20 rows of the explore
/// feed don't pull 20 megabytes of scene-graph JSON over the wire;
/// the full `PublishedProfile` is loaded lazily when the user taps
/// into a row.
nonisolated struct PublishedProfileSummary: Identifiable, Sendable, Equatable {
    let id: String
    let username: String
    let thumbnailURL: String?
    let publishedAt: Date?
    let updatedAt: Date?

    /// `publishedAt` if the row has one (the publish flow always sets
    /// it on success), else `updatedAt`. Used both as the surface
    /// "fresh"-ness signal in the row card and as the ordering
    /// cursor for pagination.
    var sortDate: Date? { publishedAt ?? updatedAt }
}

/// Wire-level summary row. Mirrors `PublishedProfileSummary`'s shape
/// in snake_case to match the Postgres column names.
nonisolated struct PublishedProfileSummaryRow: Decodable, Sendable {
    let id: String
    let username: String
    let thumbnail_url: String?
    let published_at: String?
    let updated_at: String?

    func toModel() -> PublishedProfileSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PublishedProfileSummary(
            id: id,
            username: username,
            thumbnailURL: thumbnail_url,
            publishedAt: published_at.flatMap { formatter.date(from: $0) },
            updatedAt: updated_at.flatMap { formatter.date(from: $0) }
        )
    }
}
