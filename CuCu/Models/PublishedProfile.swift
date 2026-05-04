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

/// Denormalized hero/banner metadata surfaced on the explore card
/// without paying for `design_json`. Every field is optional so a
/// summary row predating the v2 `published_profile_stats` view (no
/// hero columns) decodes cleanly — the card falls back to a
/// hash-deterministic gradient and the username styled as the
/// display name when the fields are nil. Source of truth is the
/// canvas hero + page background; the publish step is what writes
/// these into the row so the explore feed doesn't have to crack
/// `design_json` open per card.
nonisolated struct PublishedProfileCardMetadata: Sendable, Equatable {
    let displayName: String?
    let bio: String?
    /// Page background tone (hex). When `backgroundImageURL` is also
    /// set, the image overlays this color, matching the canvas's
    /// composition order so a transparent PNG still reads against the
    /// authored backdrop.
    let backgroundHex: String?
    /// Remote URL of the page's background photograph (if any).
    /// Independent of `thumbnailURL`, which is the whole-canvas
    /// snapshot — the banner uses this when present so the card reads
    /// as the user's hero rather than the rendered scroll.
    let backgroundImageURL: String?
    /// Avatar image lifted from the hero's `.profileAvatar` node.
    let avatarImageURL: String?
    /// Hero text styling. `cucuFontKey` matches the `NodeFontFamily`
    /// rawValue (e.g. `"fraunces"`, `"caveat"`); `cucuColorHex` is the
    /// effective resolved color from `applyAdaptiveHeroTextColors`.
    let displayNameFontKey: String?
    let displayNameColorHex: String?
    let bioFontKey: String?
    let bioColorHex: String?
}

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
    let voteCount: Int
    let votesLast24Hours: Int
    let votesLast7Days: Int
    let hotScore: Int
    /// Optional banner styling pulled denormalized from the publish
    /// step — `nil` on rows the v2 view hasn't surfaced yet.
    let cardMetadata: PublishedProfileCardMetadata?

    /// `publishedAt` if the row has one (the publish flow always sets
    /// it on success), else `updatedAt`. Used both as the surface
    /// "fresh"-ness signal in the row card and as the ordering
    /// cursor for pagination.
    var sortDate: Date? { publishedAt ?? updatedAt }
}

/// Wire-level summary row. Mirrors `PublishedProfileSummary`'s shape
/// in snake_case to match the Postgres column names.
nonisolated struct PublishedProfileSummaryRow: Decodable, Sendable {
    let id: String?
    let profile_id: String?
    let username: String
    let thumbnail_url: String?
    let published_at: String?
    let updated_at: String?
    let vote_count: Int?
    let votes_last_24h: Int?
    let votes_last_7d: Int?
    let hot_score: Int?
    // Optional v2 banner-metadata columns. Decode as nil on older
    // views; the card falls back to a hash gradient + the username.
    let display_name: String?
    let bio: String?
    let background_hex: String?
    let background_image_url: String?
    let avatar_image_url: String?
    let display_name_font: String?
    let display_name_color: String?
    let bio_font: String?
    let bio_color: String?

    func toModel() -> PublishedProfileSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata: PublishedProfileCardMetadata? = {
            // Only surface a metadata payload when at least one
            // banner-styling field came back populated; otherwise the
            // card branches into its own fallback path and we don't
            // want it to read "metadata is present but empty."
            let anyPresent = [
                display_name, bio, background_hex, background_image_url,
                avatar_image_url, display_name_font, display_name_color,
                bio_font, bio_color,
            ].contains { ($0?.isEmpty == false) }
            guard anyPresent else { return nil }
            return PublishedProfileCardMetadata(
                displayName: display_name,
                bio: bio,
                backgroundHex: background_hex,
                backgroundImageURL: background_image_url,
                avatarImageURL: avatar_image_url,
                displayNameFontKey: display_name_font,
                displayNameColorHex: display_name_color,
                bioFontKey: bio_font,
                bioColorHex: bio_color
            )
        }()
        return PublishedProfileSummary(
            id: profile_id ?? id ?? "",
            username: username,
            thumbnailURL: thumbnail_url,
            publishedAt: published_at.flatMap { formatter.date(from: $0) },
            updatedAt: updated_at.flatMap { formatter.date(from: $0) },
            voteCount: vote_count ?? 0,
            votesLast24Hours: votes_last_24h ?? 0,
            votesLast7Days: votes_last_7d ?? 0,
            hotScore: hot_score ?? 0,
            cardMetadata: metadata
        )
    }
}

/// Aggregate voting state used by the public viewer and Explore cards.
nonisolated struct PublishedProfileStats: Sendable, Equatable {
    let profileId: String
    let voteCount: Int
    let votesLast24Hours: Int
    let votesLast7Days: Int
    let hotScore: Int
}

nonisolated struct PublishedProfileStatsRow: Decodable, Sendable {
    let profile_id: String
    let vote_count: Int?
    let votes_last_24h: Int?
    let votes_last_7d: Int?
    let hot_score: Int?

    func toModel() -> PublishedProfileStats {
        PublishedProfileStats(
            profileId: profile_id,
            voteCount: vote_count ?? 0,
            votesLast24Hours: votes_last_24h ?? 0,
            votesLast7Days: votes_last_7d ?? 0,
            hotScore: hot_score ?? 0
        )
    }
}
