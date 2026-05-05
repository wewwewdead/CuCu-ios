import Foundation

/// On-disk cache for the heavy `PublishedProfile` payload (the row
/// itself is small but `design_json` decodes to a full scene graph
/// that's commonly 30–80KB on the wire). Backs
/// `PublishedProfileService.fetch(username:)` / `.fetch(userId:)` so
/// re-views of the same profile across launches don't pay for the
/// full `design_json` again when the row hasn't changed since the
/// last successful fetch.
///
/// Freshness model: each cached entry carries the row's
/// `updatedAtRaw` (the original server-emitted timestamp string).
/// The service does a tiny `select("updated_at")` head check before
/// committing to the full fetch — if the head matches the cache,
/// the cached profile is returned and the heavy column never
/// crosses the wire. On network failure the service falls back to
/// the cached entry too, so the viewer stays usable offline.
///
/// Stored in `Caches/` rather than Application Support: the system
/// is welcome to evict under disk pressure. A purged cache just
/// costs the next viewer a full re-fetch — the same egress profile
/// the app had before this cache existed.
nonisolated final class PublishedProfileCache: @unchecked Sendable {
    static let shared = PublishedProfileCache()

    /// Versioned root so a future on-disk format change can clear
    /// every prior entry by bumping this string. Decode failures on
    /// upgrade also no-op into a cache miss, which is the safer
    /// default.
    private static let directoryName = "cucu-published-profiles-v1"

    /// Each cached entry is a tiny envelope: the row's
    /// `updated_at` string for cheap server-side compare, plus the
    /// fully-decoded `PublishedProfile` so the canvas renders with
    /// no further parsing. Date conversion happens on the model
    /// boundary (`PublishedProfileRow.toModel`) — the raw string is
    /// only the freshness fingerprint.
    struct Entry: Codable, Sendable {
        let updatedAtRaw: String?
        let publishedAtRaw: String?
        let profile: PublishedProfile
        let cachedAt: Date
    }

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "PublishedProfileCache", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// In-memory "we just validated this entry" markers. After a
    /// successful head check (or a full fetch), the service stamps
    /// the username/userId here so subsequent reads within
    /// `sessionFreshTTL` skip the head check entirely. Trades a tiny
    /// staleness window (≤60s) for one fewer round-trip on rapid
    /// repeat views — the dominant case is a user tapping into a
    /// profile, dismissing, and immediately tapping back in.
    private var sessionFresh: [String: Date] = [:]
    private let sessionLock = NSLock()
    private let sessionFreshTTL: TimeInterval = 60

    private init() {}

    // MARK: - Public API

    /// Look up by lowercased username. Returns `nil` if there's no
    /// cached entry, the file is corrupt, or the on-disk envelope is
    /// from an older format version (decode failure → miss).
    func read(username rawUsername: String) -> Entry? {
        let key = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return readFile(at: filePath(forUsername: key))
    }

    /// Look up by lowercased user_id (Supabase auth uid). RootView's
    /// bootstrap path uses this when the local username cache is
    /// still empty after a fresh sign-in.
    func read(userId rawUserId: String) -> Entry? {
        let key = rawUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return readFile(at: filePath(forUserId: key))
    }

    /// True when the username's cache entry was head-checked or
    /// fully refetched within the last `sessionFreshTTL` seconds.
    /// Lets the service short-circuit the head check on rapid repeat
    /// views without sacrificing eventual freshness — entries
    /// outside the window get a regular head check.
    func isSessionFresh(username rawUsername: String) -> Bool {
        isSessionFresh(key: "u:" + rawUsername.lowercased())
    }

    func isSessionFresh(userId rawUserId: String) -> Bool {
        isSessionFresh(key: "i:" + rawUserId.lowercased())
    }

    /// Stamp both keys after a successful head check or full
    /// fetch. Stamping both means a profile fetched once via
    /// either path is considered fresh on the other path too — the
    /// disk cache already shares state, so the in-memory layer
    /// should too.
    func markSessionFresh(username rawUsername: String?, userId rawUserId: String?) {
        let now = Date()
        let trimmedUsername = rawUsername?.lowercased() ?? ""
        let trimmedUserId = rawUserId?.lowercased() ?? ""
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if !trimmedUsername.isEmpty {
            sessionFresh["u:" + trimmedUsername] = now
        }
        if !trimmedUserId.isEmpty {
            sessionFresh["i:" + trimmedUserId] = now
        }
    }

    /// Clear stamps for a given key — used when invalidation runs
    /// (notFound from server) so the next view doesn't trust an
    /// in-memory marker for a row that's no longer there.
    func clearSessionFresh(username rawUsername: String?, userId rawUserId: String?) {
        let trimmedUsername = rawUsername?.lowercased() ?? ""
        let trimmedUserId = rawUserId?.lowercased() ?? ""
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if !trimmedUsername.isEmpty {
            sessionFresh.removeValue(forKey: "u:" + trimmedUsername)
        }
        if !trimmedUserId.isEmpty {
            sessionFresh.removeValue(forKey: "i:" + trimmedUserId)
        }
    }

    private func isSessionFresh(key: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let stamp = sessionFresh[key] else { return false }
        if Date().timeIntervalSince(stamp) <= sessionFreshTTL {
            return true
        }
        // Past TTL — drop the marker so the next read treats the
        // entry as needing a fresh head check.
        sessionFresh.removeValue(forKey: key)
        return false
    }

    /// Persist a freshly-fetched profile under both username and
    /// user_id keys. Same profile, two on-disk entries — costs ~50KB
    /// of duplication per profile but keeps the read paths a single
    /// O(1) file load instead of an index round-trip. Writes happen
    /// off-thread so a `fetch()` doesn't pay the disk cost
    /// synchronously.
    func write(profile: PublishedProfile, updatedAtRaw: String?, publishedAtRaw: String?) {
        let entry = Entry(
            updatedAtRaw: updatedAtRaw,
            publishedAtRaw: publishedAtRaw,
            profile: profile,
            cachedAt: .now
        )
        let username = profile.username.lowercased()
        let userId = profile.userId.lowercased()
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? self.encoder.encode(entry) else { return }
            if !username.isEmpty {
                self.writeFile(data: data, to: self.filePath(forUsername: username))
            }
            if !userId.isEmpty {
                self.writeFile(data: data, to: self.filePath(forUserId: userId))
            }
        }
    }

    /// Drop both keyed entries for a profile we've learned is gone
    /// (server returned `notFound` after a delete / unpublish).
    /// Idempotent: missing files are silently ignored.
    func invalidate(username rawUsername: String?, userId rawUserId: String?) {
        let username = rawUsername?.lowercased() ?? ""
        let userId = rawUserId?.lowercased() ?? ""
        queue.async { [weak self] in
            guard let self else { return }
            if !username.isEmpty {
                try? self.fileManager.removeItem(at: self.filePath(forUsername: username))
            }
            if !userId.isEmpty {
                try? self.fileManager.removeItem(at: self.filePath(forUserId: userId))
            }
        }
    }

    /// QA / debug. Wipes the entire on-disk cache. Production paths
    /// should rely on per-entry invalidation above.
    func clearAll() {
        queue.async { [weak self] in
            guard let self, let root = self.rootURL else { return }
            try? self.fileManager.removeItem(at: root)
        }
    }

    // MARK: - File system

    private var rootURL: URL? {
        guard let caches = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return caches.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func filePath(forUsername key: String) -> URL {
        let safe = sanitize(key)
        return (rootURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("by-username", isDirectory: true)
            .appendingPathComponent("\(safe).json", isDirectory: false)
    }

    private func filePath(forUserId key: String) -> URL {
        let safe = sanitize(key)
        return (rootURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("by-user-id", isDirectory: true)
            .appendingPathComponent("\(safe).json", isDirectory: false)
    }

    /// Lowercased usernames + UUIDs are filesystem-safe by their own
    /// rules, but a defensive whitelist guards against a stray invalid
    /// character (a misencoded handle from a future schema, etc.)
    /// turning into a path-traversal vector or a colon that breaks
    /// HFS+. Any disallowed byte collapses to `_`.
    private func sanitize(_ key: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(key.map { allowed.contains($0) ? $0 : "_" })
    }

    private func readFile(at url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Entry.self, from: data)
    }

    private func writeFile(data: Data, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Silent — a failed cache write just means the next
            // fetch pays for the full row again. The viewer
            // already has the canonical data in memory.
        }
    }
}
