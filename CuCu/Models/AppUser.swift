import Foundation

/// App-level representation of an authenticated user.
///
/// Kept free of Supabase types so SwiftUI views and view-models compile in
/// builds that don't yet have the `Supabase` SPM package. The auth service
/// constructs `AppUser` from `Supabase.User` in a `#if canImport(Supabase)`
/// branch.
///
/// `username` is optional because brand-new accounts haven't claimed one
/// yet — the auth gate routes them through `UsernamePickerView` after
/// sign-up. Pre-existing accounts had their `profiles.username` backfilled
/// into the `usernames` table by the Phase 1 SQL migration, so a fresh
/// `loadSession` hydrates them on first launch.
nonisolated struct AppUser: Equatable, Sendable {
    let id: String
    let email: String
    var username: String?
    /// True when the user has the `admin` row in `user_roles`. Drives
    /// the "Manage roles" entry in the Account sheet — gated by the
    /// SQL `user_roles_admin_write` policy server-side too, so a
    /// stale-state misclick still can't escalate.
    var isAdmin: Bool
    /// True when the user has either `admin` or `moderator` in
    /// `user_roles` — admins are also moderators, per spec. Drives
    /// the "Moderation queue" entry in the Account sheet.
    var isModerator: Bool

    init(
        id: String,
        email: String,
        username: String? = nil,
        isAdmin: Bool = false,
        isModerator: Bool = false
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.isAdmin = isAdmin
        self.isModerator = isModerator
    }
}
