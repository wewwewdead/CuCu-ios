import Foundation

/// Lightweight cross-surface event bus for post deletions.
///
/// Closure callbacks couple two specific views together — fine for
/// the dismiss-handoff between `PostThreadView` and `PostFeedView`,
/// but brittle when a third surface also has the same post on
/// screen (a per-user feed, a profile column, a future bookmarks
/// list). A broadcast lets every loaded surface scrub in lock-step
/// without each one needing to know about the others.
///
/// The bus is fire-and-forget: senders broadcast on optimistic
/// removal; subscribers locally pull the row from whatever column
/// they manage. Rollback on server failure is the sender's job —
/// other surfaces will pick up the canonical state on their next
/// fetch (the cost of a stale row for one refresh cycle is far
/// lower than the complexity of a two-phase ack/restore protocol).
extension Notification.Name {
    /// Posted when a post has been optimistically removed somewhere
    /// in the app. `userInfo["postId"]` carries the id (String).
    static let cucuPostOptimisticallyDeleted = Notification.Name(
        "CuCu.PostOptimisticallyDeleted"
    )

    /// Posted after a successful profile publish that may have
    /// changed the profile hero/avatar. `userInfo["username"]`
    /// carries the lowercased username (String).
    static let cucuProfileAvatarDidChange = Notification.Name(
        "CuCu.ProfileAvatarDidChange"
    )
}

enum CucuPostEvents {
    /// Convenience wrapper so call sites don't repeat the userInfo
    /// shape. Senders should call this *after* the optimistic
    /// mutation lands locally so subscribers don't race ahead of
    /// the source surface's own animation.
    static func broadcastDeletion(postId: String) {
        NotificationCenter.default.post(
            name: .cucuPostOptimisticallyDeleted,
            object: nil,
            userInfo: ["postId": postId]
        )
    }

    /// Pull the deleted post id out of a notification's userInfo.
    /// Returns nil if the payload is malformed — subscribers can
    /// safely `guard let` to no-op on bad input rather than trap.
    static func deletedPostId(from notification: Notification) -> String? {
        notification.userInfo?["postId"] as? String
    }
}

enum CucuProfileEvents {
    static func broadcastAvatarChange(username: String) {
        let canonical = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !canonical.isEmpty else { return }
        NotificationCenter.default.post(
            name: .cucuProfileAvatarDidChange,
            object: nil,
            userInfo: ["username": canonical]
        )
    }

    static func avatarUsername(from notification: Notification) -> String? {
        guard let username = notification.userInfo?["username"] as? String else {
            return nil
        }
        let canonical = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return canonical.isEmpty ? nil : canonical
    }
}
