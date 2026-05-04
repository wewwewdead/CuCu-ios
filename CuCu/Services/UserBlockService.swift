import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Errors surfaced by the block flow. Kept compact — block / unblock
/// aren't critical paths and shouldn't lean on a fat error
/// vocabulary.
enum UserBlockError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case notSignedIn
    case network
    case database(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to enable blocking."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to enable blocking."
        case .notSignedIn:
            return "Sign in to block users."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .database(let detail):
            return detail
        }
    }
}

/// Lightweight join row for the "Blocked users" account screen —
/// `userId` plus an optional `@handle` (a freshly-signed-up
/// blocked account may have no claim yet). Decodable from the
/// `user_blocks` ⨝ `usernames` query.
struct BlockedUser: Identifiable, Sendable, Equatable {
    let userId: String
    let username: String?
    var id: String { userId }
}

/// Reads / writes `user_blocks`. RLS:
///   - `user_blocks_owner` policy gates SELECT/INSERT/DELETE to
///     `auth.uid() = blocker_id`, so every method here is
///     implicitly scoped to the signed-in user — no client-side
///     filter on `blocker_id` needed.
///
/// The `is_blocked(viewer, target)` SQL function exists server-
/// side and is referenced by `posts_select_visible` so blocked
/// users' posts disappear from feeds automatically. The only
/// client-side scrub we do (`removeAllByAuthor` on the VMs) is to
/// prune the *currently loaded* viewport so the user sees their
/// block take effect without a refresh.
nonisolated struct UserBlockService {
    /// Insert a block row. Idempotent at the SQL layer
    /// (`PRIMARY KEY (blocker_id, blocked_id)`); a re-block from a
    /// stuck UI lands as a unique violation we swallow into success
    /// because the desired end-state ("this user is blocked") is
    /// already true.
    func block(userId: String) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw UserBlockError.notConfigured(reason: .missingCredentials)
        }
        guard let session = try? await client.auth.session else {
            throw UserBlockError.notSignedIn
        }
        let blockerId = session.user.id.uuidString.lowercased()
        let row = NewBlockRow(blocker_id: blockerId, blocked_id: userId.lowercased())
        do {
            try await client
                .from("user_blocks")
                .upsert(row, onConflict: "blocker_id,blocked_id")
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw UserBlockError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    func unblock(userId: String) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw UserBlockError.notConfigured(reason: .missingCredentials)
        }
        guard let session = try? await client.auth.session else {
            throw UserBlockError.notSignedIn
        }
        let blockerId = session.user.id.uuidString.lowercased()
        do {
            try await client
                .from("user_blocks")
                .delete()
                .eq("blocker_id", value: blockerId)
                .eq("blocked_id", value: userId.lowercased())
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw UserBlockError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// All `blocked_id`s the current user has blocked. Returns an
    /// empty set when signed out / Supabase isn't configured —
    /// callers (feed VM, thread VM) treat "no blocks" as the
    /// safe default.
    func fetchBlockedUserIds() async -> Set<String> {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else { return [] }
        guard let session = try? await client.auth.session else { return [] }
        let blockerId = session.user.id.uuidString.lowercased()
        do {
            let rows: [BlockedIdRow] = try await client
                .from("user_blocks")
                .select("blocked_id")
                .eq("blocker_id", value: blockerId)
                .execute()
                .value
            return Set(rows.map { $0.blocked_id })
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Two-query fetch for the Account → Privacy → Blocked users
    /// screen. PostgREST nested embed doesn't work here because
    /// `user_blocks.blocked_id` has no formal FK to
    /// `usernames.user_id` — both columns reference `auth.users(id)`
    /// instead, and PostgREST can only embed across declared FKs.
    /// We therefore:
    ///   1. SELECT every `blocked_id` for the signed-in viewer (RLS
    ///      restricts to `blocker_id = auth.uid()`).
    ///   2. SELECT matching `usernames` rows in one batched IN query.
    /// Order from the first query is preserved by walking the id
    /// list in the same sequence when assembling the result —
    /// PostgREST's `in(...)` doesn't guarantee return order.
    func fetchBlockedUsers() async throws -> [BlockedUser] {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw UserBlockError.notConfigured(reason: .missingCredentials)
        }
        guard (try? await client.auth.session) != nil else {
            throw UserBlockError.notSignedIn
        }
        do {
            let blockedRows: [BlockedIdRow] = try await client
                .from("user_blocks")
                .select("blocked_id")
                .order("created_at", ascending: false)
                .execute()
                .value
            let ids = blockedRows.map { $0.blocked_id }
            guard !ids.isEmpty else { return [] }

            let nameRows: [UserIdUsernameRow] = try await client
                .from("usernames")
                .select("user_id,username")
                .in("user_id", values: ids)
                .execute()
                .value
            var usernameByUserId: [String: String] = [:]
            for row in nameRows {
                usernameByUserId[row.user_id.lowercased()] = row.username
            }
            return ids.map { id in
                BlockedUser(
                    userId: id,
                    username: usernameByUserId[id.lowercased()]
                )
            }
        } catch {
            throw mapError(error)
        }
        #else
        throw UserBlockError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    #if canImport(Supabase)
    private func mapError(_ error: Error) -> UserBlockError {
        if let pgErr = error as? PostgrestError, pgErr.code == "23505" {
            // Duplicate block — desired state already holds, treat
            // as success at the call site by mapping to a benign
            // case. We don't throw here on duplicates because
            // upsert already absorbs them; this path covers code
            // paths that bypass upsert.
            return .database("already blocked")
        }
        if SupabaseErrorMapper.isNetwork(error) { return .network }
        return .database(SupabaseErrorMapper.detail(error))
    }
    #endif
}

// MARK: - Wire shapes

private nonisolated struct NewBlockRow: Encodable {
    let blocker_id: String
    let blocked_id: String
}

private nonisolated struct BlockedIdRow: Decodable, Sendable {
    let blocked_id: String
}

/// Used by the second query in `fetchBlockedUsers` — pairs each
/// `user_id` with its claimed `username` for the in-memory lookup.
private nonisolated struct UserIdUsernameRow: Decodable, Sendable {
    let user_id: String
    let username: String
}
