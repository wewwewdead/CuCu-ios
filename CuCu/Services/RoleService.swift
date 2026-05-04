import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Errors surfaced by the role-management surface (admin-only screens).
/// Kept distinct from `AuthError` because role mutations are admin
/// actions, not auth-gating actions — surfacing them through the
/// auth error type would muddy the shared sign-in copy.
enum RoleError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case notSignedIn
    case usernameNotFound(String)
    case alreadyHasRole
    case notAuthorized
    case network
    case database(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to manage roles."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to manage roles."
        case .notSignedIn:
            return "Sign in to manage roles."
        case .usernameNotFound(let username):
            return "No user found with username @\(username)."
        case .alreadyHasRole:
            return "That user already has a role assigned."
        case .notAuthorized:
            return "You don't have permission to do that."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .database(let detail):
            return detail
        }
    }
}

/// Roles the app understands. The DB CHECK constraint on
/// `user_roles.role` enforces the same set — keeping this enum
/// in lockstep means a typo here surfaces at compile time rather
/// than as a runtime PostgREST 23514 error.
enum AppRole: String, Sendable, Equatable {
    case admin
    case moderator
}

/// Lightweight record used by `RoleManagementView` for the existing-
/// roles list. The username is optional because `user_roles` is
/// joined left-side against `usernames` — a user without a claimed
/// handle still appears, just without a "@" badge.
struct RoleAssignment: Identifiable, Sendable, Equatable {
    let userId: String
    let username: String?
    let role: AppRole
    var id: String { userId }
}

/// Reads / writes `user_roles`. RLS:
///   - SELECT: every signed-in user can read their own row
///     (`user_roles_select`), so `fetchRole(userId:)` works for the
///     calling user.
///   - INSERT / DELETE: admins only (`user_roles_admin_write`).
///   - The full-list read used by the admin panel goes through the
///     same `user_roles_select` policy, which the migration extended
///     to admins reading any row.
nonisolated struct RoleService {
    /// Resolve `userId`'s role. Returns `nil` when the user has no
    /// row (the regular-user case). Quietly returns `nil` on any
    /// error too — a transient PostgREST hiccup shouldn't gate the
    /// app on "we couldn't determine your role", it just means
    /// admin/mod surfaces stay hidden until the next refresh.
    func fetchRole(userId: String) async -> AppRole? {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else { return nil }
        let canonical = userId.lowercased()
        do {
            let rows: [RoleRow] = try await client
                .from("user_roles")
                .select("role")
                .eq("user_id", value: canonical)
                .execute()
                .value
            // Multiple rows shouldn't happen under the unique
            // constraint, but be defensive: prefer admin if both
            // somehow coexist so privileges don't silently
            // downgrade.
            if rows.contains(where: { $0.role == AppRole.admin.rawValue }) {
                return .admin
            }
            if rows.contains(where: { $0.role == AppRole.moderator.rawValue }) {
                return .moderator
            }
            return nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Resolve `username` → `user_id` via the `usernames` table,
    /// then INSERT a `moderator` row into `user_roles`. RLS gates
    /// the insert to admins; non-admins land in `.notAuthorized`.
    /// Returns the granted user_id so the caller can refresh its
    /// row list without a full refetch.
    func grantModerator(username: String) async throws -> String {
        let trimmed = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else {
            throw RoleError.usernameNotFound(username)
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw RoleError.notConfigured(reason: .missingCredentials)
        }

        do {
            let lookup: [UsernameUserIdRow] = try await client
                .from("usernames")
                .select("user_id")
                .eq("username", value: trimmed)
                .limit(1)
                .execute()
                .value
            guard let row = lookup.first else {
                throw RoleError.usernameNotFound(trimmed)
            }
            let payload = NewRoleRow(user_id: row.user_id, role: AppRole.moderator.rawValue)
            try await client
                .from("user_roles")
                .insert(payload)
                .execute()
            return row.user_id
        } catch let err as RoleError {
            throw err
        } catch {
            throw mapError(error)
        }
        #else
        throw RoleError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Drop `userId`'s row from `user_roles`. Caller is responsible
    /// for refusing to revoke the signed-in admin's own row — RLS
    /// would allow it (admins can DELETE any row), but doing so
    /// removes their own access path back into the screen, so the
    /// UI disables the button and the SQL editor stays the
    /// authoritative path for that case.
    func revokeRole(userId: String) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw RoleError.notConfigured(reason: .missingCredentials)
        }
        do {
            try await client
                .from("user_roles")
                .delete()
                .eq("user_id", value: userId.lowercased())
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw RoleError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Full list of admins + moderators for the admin panel.
    /// Two-query: first SELECT `user_roles`, then look up matching
    /// `usernames` in one batched IN. PostgREST nested-embed
    /// doesn't work here because `user_roles.user_id` references
    /// `auth.users(id)`, not `usernames.user_id`, so there's no FK
    /// for the embed planner to resolve. Username is optional — a
    /// freshly-promoted account that hasn't claimed a handle yet
    /// still appears in the list, just without a `@` badge.
    func fetchModeratorsAndAdmins() async throws -> [RoleAssignment] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw RoleError.notConfigured(reason: .missingCredentials)
        }
        do {
            let roleRows: [RoleListRow] = try await client
                .from("user_roles")
                .select("user_id,role")
                .order("role", ascending: true)
                .execute()
                .value
            let ids = roleRows.map { $0.user_id }
            guard !ids.isEmpty else { return [] }

            let nameRows: [UsernameLookupRow] = try await client
                .from("usernames")
                .select("user_id,username")
                .in("user_id", values: ids)
                .execute()
                .value
            var usernameByUserId: [String: String] = [:]
            for row in nameRows {
                usernameByUserId[row.user_id.lowercased()] = row.username
            }
            return roleRows.compactMap { row in
                guard let role = AppRole(rawValue: row.role) else { return nil }
                return RoleAssignment(
                    userId: row.user_id,
                    username: usernameByUserId[row.user_id.lowercased()],
                    role: role
                )
            }
        } catch {
            throw mapError(error)
        }
        #else
        throw RoleError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    #if canImport(Supabase)
    private func mapError(_ error: Error) -> RoleError {
        if let pgErr = error as? PostgrestError {
            // 23505 unique violation = role row already exists.
            if pgErr.code == "23505" { return .alreadyHasRole }
            // 42501 = insufficient privilege; PostgREST also
            // surfaces RLS denials this way.
            if pgErr.code == "42501" { return .notAuthorized }
        }
        let text = SupabaseErrorMapper.detail(error).lowercased()
        if text.contains("23505") || text.contains("duplicate key") {
            return .alreadyHasRole
        }
        if text.contains("row-level security") || text.contains("42501") {
            return .notAuthorized
        }
        if SupabaseErrorMapper.isNetwork(error) { return .network }
        return .database(SupabaseErrorMapper.detail(error))
    }
    #endif
}

// MARK: - Wire shapes

private nonisolated struct RoleRow: Decodable, Sendable {
    let role: String
}

private nonisolated struct UsernameUserIdRow: Decodable, Sendable {
    let user_id: String
}

private nonisolated struct NewRoleRow: Encodable {
    let user_id: String
    let role: String
}

/// Plain (un-joined) row from `user_roles`. The username lookup
/// happens in a separate `IN`-batched query — see
/// `fetchModeratorsAndAdmins`'s commentary for why nested embed
/// doesn't work for this relation.
private nonisolated struct RoleListRow: Decodable, Sendable {
    let user_id: String
    let role: String
}

private nonisolated struct UsernameLookupRow: Decodable, Sendable {
    let user_id: String
    let username: String
}
