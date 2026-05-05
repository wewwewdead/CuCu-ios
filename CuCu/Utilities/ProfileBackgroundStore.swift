import Foundation
import Observation

/// Process-wide cache for the JSONB-extracted banner fragments
/// (background image URL, background hex, hero avatar URL) that
/// `PublishedProfilesListView` and `TopPickTile` overlay onto each
/// explore card.
///
/// Each `PublishedProfilesListView` mount used to keep its own
/// `[String: BackgroundFragment]` `@State` dict, so navigating away
/// and back into Explore re-fetched the same fragments via
/// `PublishedProfileService.fetchBackgrounds`. Hoisting the dict to
/// a singleton means the fragments survive view tear-down for the
/// life of the process — explore-list remounts read the values the
/// previous mount already paid for, and only profiles new to this
/// session round-trip to PostgREST.
///
/// The fragments themselves are essentially immutable for a given
/// `profile.id` until the author re-publishes — the `cucuProfileAvatarDidChange`
/// notification is the only correctness-critical invalidation, and
/// even that only matters for the *avatar* slot (the page background
/// rarely changes for a given profile).
@MainActor
@Observable
final class ProfileBackgroundStore {
    static let shared = ProfileBackgroundStore()

    /// Profile id → cached banner fragment. Populated by `enrich` and
    /// read directly by the explore card / top-pick tile views.
    private(set) var fragments: [String: PublishedProfileService.BackgroundFragment] = [:]

    private let service = PublishedProfileService()

    private init() {}

    /// O(1) read for an already-resolved profile. Returns nil for
    /// profiles we haven't enriched yet — the caller's seed gradient
    /// covers the gap until `enrich` populates the entry.
    func fragment(for profileId: String) -> PublishedProfileService.BackgroundFragment? {
        fragments[profileId]
    }

    /// Batched enrichment for a freshly-loaded page of summaries.
    /// Skips ids we've already cached so a re-mount of the explore
    /// list doesn't re-pull the same JSONB fragments. Failures are
    /// silent — the seed gradient is the fallback.
    func enrich(profiles: [PublishedProfileSummary]) async {
        let needed = profiles.map(\.id).filter { fragments[$0] == nil }
        guard !needed.isEmpty else { return }
        do {
            let fresh = try await service.fetchBackgrounds(for: needed)
            // Merge rather than replace so concurrent enrich calls
            // (Hottest + Latest racing on the same view) cooperate
            // instead of stomping each other.
            for (key, value) in fresh { fragments[key] = value }
        } catch {
            // Silent — the seed gradient is correct until the next refresh.
        }
    }

    /// Drop a single profile's fragment after a republish broadcast.
    /// The avatar URL inside is the most likely change; clearing the
    /// whole entry forces a re-enrich on the next list mount, which
    /// keeps the code simple at the cost of one extra wire fetch
    /// when the user republishes.
    func invalidate(profileId: String) {
        fragments.removeValue(forKey: profileId)
    }

    /// Clear everything. Called rarely — useful if a future "log out"
    /// flow wants to scrub cross-account residue from the device.
    func clearAll() {
        fragments.removeAll()
    }
}
