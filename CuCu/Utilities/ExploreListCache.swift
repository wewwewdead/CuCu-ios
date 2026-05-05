import Foundation

/// Short-TTL in-memory cache for the explore feed's first-page
/// results — the Hottest carousel and the Latest column on
/// `PublishedProfilesListView`. Bypassed for paginated reads
/// (offset > 0 / cursor != nil) because cached pages would
/// contradict the `published_at` cursor that pagination is built
/// against.
///
/// Why this exists: `PublishedProfilesListView.task` and
/// `loadTopPicks` both hit `fetchHottest()` on first paint, and the
/// `.onAppear` tab-re-entry path runs `initialLoad` + `loadTopPicks`
/// on every Explore tab return. With a 60-second TTL, three pulls
/// of the same first page in 60 seconds collapse into one round
/// trip; the user-driven `pull-to-refresh` bypass keeps freshness
/// under user control.
///
/// Backed by an actor so the store is safe to share across the
/// service's `nonisolated struct` API without a lock dance.
actor ExploreListCache {
    static let shared = ExploreListCache()

    private struct Snapshot: Sendable {
        let rows: [PublishedProfileSummary]
        let fetchedAt: Date
    }

    /// Cache lives for one minute by default. Long enough to dedupe
    /// the duplicate calls described above; short enough that a
    /// freshly-published profile shows up on the next tab return.
    private let ttl: TimeInterval = 60

    private var hottestSnapshot: Snapshot?
    private var latestSnapshot: Snapshot?

    private init() {}

    // MARK: - Hottest

    /// Returns cached rows iff a fresh-enough snapshot exists.
    /// `nil` means the caller should fetch + then call `setHottest`.
    func hottest() -> [PublishedProfileSummary]? {
        guard let snap = hottestSnapshot,
              Date().timeIntervalSince(snap.fetchedAt) <= ttl else {
            return nil
        }
        return snap.rows
    }

    func setHottest(_ rows: [PublishedProfileSummary]) {
        hottestSnapshot = Snapshot(rows: rows, fetchedAt: .now)
    }

    func invalidateHottest() {
        hottestSnapshot = nil
    }

    // MARK: - Latest

    func latest() -> [PublishedProfileSummary]? {
        guard let snap = latestSnapshot,
              Date().timeIntervalSince(snap.fetchedAt) <= ttl else {
            return nil
        }
        return snap.rows
    }

    func setLatest(_ rows: [PublishedProfileSummary]) {
        latestSnapshot = Snapshot(rows: rows, fetchedAt: .now)
    }

    func invalidateLatest() {
        latestSnapshot = nil
    }

    /// Clear both snapshots. `PublishedProfilesListView`'s pull-to-
    /// refresh handler calls this so a manual refresh always
    /// bypasses the cache, regardless of how recently the user
    /// loaded the feed.
    func invalidateAll() {
        hottestSnapshot = nil
        latestSnapshot = nil
    }
}
