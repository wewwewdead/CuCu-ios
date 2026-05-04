import Foundation
import SwiftData

/// SwiftData record for a locally saved draft.
///
/// The whole design is serialized as JSON in `designJSON` rather than modeled
/// relationally. This keeps the schema flexible while we iterate on block types
/// and lets the same payload feed a future web renderer with no translation.
///
/// Phase 4 added three optional publish-metadata fields. They're optional and
/// have nil defaults, which qualifies as a SwiftData lightweight migration —
/// existing pre-Phase-4 stores migrate automatically with the new fields set
/// to nil for old drafts.
@Model
final class ProfileDraft {
    var id: UUID
    var title: String
    var designJSON: String
    var createdAt: Date
    var updatedAt: Date

    /// Server profile ID returned by the most recent successful publish. Used
    /// to upsert the same row on subsequent publishes instead of creating a
    /// duplicate profile.
    var publishedProfileId: String?
    /// Username chosen at the most recent successful publish. Pre-fills the
    /// publish form so the user doesn't have to re-type it.
    var publishedUsername: String?
    /// Timestamp of the most recent successful publish.
    var lastPublishedAt: Date?
    /// Canonical (lowercased) Supabase user id that owns the published row
    /// referenced by `publishedProfileId`. Stamped on every successful
    /// publish so a later sign-out + sign-up on the same device can detect
    /// "this draft's published profile belongs to a different account" and
    /// drop the stale pointer before the next publish — without it, the
    /// upsert tries to UPDATE the old owner's row, fails RLS on the
    /// `using (auth.uid() = user_id)` clause, and the upsert fall-through
    /// surfaces as a confusing "row violates RLS policy (using expression)"
    /// error to the new account.
    ///
    /// Pre-fix drafts have this nil; the next successful publish by the
    /// original owner stamps it, after which the cross-account check
    /// works for that draft going forward.
    var publishedOwnerUserId: String?

    init(id: UUID = UUID(),
         title: String = "Untitled",
         designJSON: String = DesignJSONCoder.fallbackJSON,
         createdAt: Date = .now,
         updatedAt: Date = .now,
         publishedProfileId: String? = nil,
         publishedUsername: String? = nil,
         lastPublishedAt: Date? = nil,
         publishedOwnerUserId: String? = nil) {
        self.id = id
        self.title = title
        self.designJSON = designJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publishedProfileId = publishedProfileId
        self.publishedUsername = publishedUsername
        self.lastPublishedAt = lastPublishedAt
        self.publishedOwnerUserId = publishedOwnerUserId
    }
}
