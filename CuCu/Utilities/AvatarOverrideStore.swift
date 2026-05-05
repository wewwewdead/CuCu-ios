import Foundation
import Observation

/// Process-wide cache for `username → heroAvatarURL` lookups, shared by
/// every surface that paints author avatars (feed, thread, masthead
/// pucks). Each surface used to keep its own `[String: String]` and
/// trigger its own `PublishedProfileService.fetchAvatars` debounce, so
/// jumping feed → thread for a post by the same author re-fetched the
/// same handle. Hoisting the dictionary into one observable singleton
/// means the second view reads the value the first one already paid
/// for, and a single batched fetch covers every surface that needs it.
///
/// Negative results (the author hasn't published, or published without
/// a hero avatar) are recorded in `completed` so recycled rows don't
/// keep re-asking the server only to keep rendering the letter
/// fallback.
@MainActor
@Observable
final class AvatarOverrideStore {
    static let shared = AvatarOverrideStore()

    /// Lowercased username → hero avatar URL. Read by `CachedRemoteImage`
    /// hosts to swap the bookplate-letter tile for the real photo.
    private(set) var overrides: [String: String] = [:]

    /// Both positive and negative resolutions. A miss is recorded so
    /// scrolling the same row back into view doesn't re-trigger a
    /// fetch — the server already told us this username has no hero
    /// avatar.
    private var completed: Set<String> = []

    /// Usernames queued during the current debounce window. Drained
    /// into a single batched `fetchAvatars` call when the window
    /// closes.
    private var pending: Set<String> = []

    /// Leading-edge gate so a scroll burst of `.onAppear`s only spawns
    /// one debounce task at a time. Each later request just adds to
    /// `pending`; when the fetch resolves, the gate drops and the next
    /// fresh request opens a new window.
    private var batchInFlight: Bool = false

    /// Empirically-tuned window: long enough that a momentum scroll
    /// gathers most visible authors into one batch, short enough that
    /// the avatar swap doesn't lag visibly behind the row paint.
    private let debounceNanos: UInt64 = 200_000_000

    private init() {}

    /// O(1) read. Returns `nil` for unknown handles or recorded misses
    /// — both render the letter-fallback path on the row side.
    func avatarURL(for username: String) -> String? {
        let key = username.lowercased()
        return overrides[key]
    }

    /// Per-row entry point. Each row's `.onAppear` calls this; we
    /// accumulate misses for a short window then drain the set in a
    /// single batched PostgREST call. Cache hits short-circuit at the
    /// top so re-appearing rows (scroll-back, recycle) cost nothing.
    func requestLazy(for username: String) {
        let key = username.lowercased()
        guard !key.isEmpty,
              overrides[key] == nil,
              !completed.contains(key) else { return }
        pending.insert(key)
        guard !batchInFlight else { return }
        batchInFlight = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanos ?? 200_000_000)
            await self?.drain()
        }
    }

    /// Account-boundary reset. Every cached lookup is by username, but
    /// the *signed-in viewer* uses the puck path which forks on
    /// "@\(myUsername)" — and a sign-out followed by a sign-in as a
    /// different account would otherwise paint the previous owner's
    /// puck during the brief load window. Wiping the dict on viewer
    /// change is cheap (a few dozen entries) and keeps the surface
    /// honest.
    func reset() {
        overrides.removeAll()
        completed.removeAll()
        pending.removeAll()
        batchInFlight = false
    }

    /// Force-refresh a single username after a `cucuProfileAvatarDidChange`
    /// broadcast. Drops the stale URL before the network call so the
    /// row briefly flips to fallback rather than continuing to paint
    /// the previous photo while the request is in flight.
    func refresh(username: String) async {
        let key = username.lowercased()
        guard !key.isEmpty else { return }
        overrides.removeValue(forKey: key)
        pending.remove(key)
        completed.remove(key)
        do {
            let map = try await PublishedProfileService()
                .fetchAvatars(forUsernames: [key])
            completed.insert(key)
            if let freshURL = map[key], !freshURL.isEmpty {
                overrides[key] = freshURL
            }
        } catch {
            // Silent — fallback is correct until the next successful lookup.
        }
    }

    private func drain() async {
        let snapshot = pending
            .subtracting(Set(overrides.keys))
            .subtracting(completed)
        pending.removeAll()
        batchInFlight = false
        guard !snapshot.isEmpty else { return }
        do {
            let map = try await PublishedProfileService()
                .fetchAvatars(forUsernames: Array(snapshot))
            // Mark every queried username as completed — including
            // those the server didn't return, so a missing hero avatar
            // is recorded as a negative and not re-asked on every
            // subsequent appearance.
            completed.formUnion(snapshot)
            for (key, url) in map where !url.isEmpty {
                overrides[key] = url
            }
        } catch {
            // Silent — letter / rose puck fallback covers it. The
            // pending set was already cleared above so a transient
            // failure doesn't poison the next debounce window.
        }
    }
}
