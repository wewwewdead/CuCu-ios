import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Errors surfaced by the username claim flow.
///
/// Kept distinct from `PublishError` because the picker runs before
/// publish and shouldn't have to map between unrelated cases.
enum UsernameError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case invalid(String)
    case taken
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to claim a username."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to claim a username."
        case .invalid(let reason):
            return reason
        case .taken:
            return "That username is already taken."
        case .network:
            return "Couldn't reach Supabase. Check your connection and try again."
        case .unknown(let detail):
            return detail
        }
    }
}

/// Result of a live availability check. Distinguishes "we know it's taken"
/// from "we couldn't reach the server" so the picker can render the right
/// inline hint without falsely blocking the Claim button on a transient
/// network blip.
enum UsernameAvailability: Equatable, Sendable {
    case available
    case taken
    case invalid(String)
    case error(String)
}

/// Reads / writes the `usernames` table — the single source of truth
/// for who owns which handle. The Phase 1 SQL migration populated this
/// table from `profiles.username` so existing accounts already have a
/// row; brand-new accounts get a row when they claim through
/// `UsernamePickerView`.
nonisolated struct UsernameService {
    /// Fetch the claim for `userId`. Returns `nil` when no row exists
    /// (the user hasn't claimed yet) and **also** when the lookup
    /// fails — the caller (AuthViewModel) treats either as "no
    /// username yet" and routes to the picker. The picker's own
    /// availability + claim calls will surface a real error if the
    /// network is genuinely down.
    func fetchUsername(userId: String) async -> String? {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else { return nil }
        let canonicalUserId = userId.lowercased()
        do {
            let row: UsernameRow = try await client
                .from("usernames")
                .select("username")
                .eq("user_id", value: canonicalUserId)
                .limit(1)
                .single()
                .execute()
                .value
            return row.username
        } catch {
            // PGRST116 = "0 rows on .single()" — that's the legitimate
            // "no claim yet" answer, not an error worth surfacing.
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Live availability check, called by the picker on every keystroke
    /// (debounced 400 ms upstream). Validates the format locally first
    /// so we don't waste a round-trip on input that the SQL `check`
    /// constraint would reject anyway.
    func checkAvailability(_ rawUsername: String) async -> UsernameAvailability {
        switch UsernameValidator.validate(rawUsername) {
        case .failure(let err):
            return .invalid(err.errorDescription ?? "Invalid username.")
        case .success(let canonical):
            #if canImport(Supabase)
            guard let client = SupabaseClientProvider.shared else {
                return .error(UsernameError
                    .notConfigured(reason: .missingCredentials)
                    .errorDescription ?? "")
            }
            do {
                let rows: [UsernameRow] = try await client
                    .from("usernames")
                    .select("username")
                    .eq("username", value: canonical)
                    .limit(1)
                    .execute()
                    .value
                return rows.isEmpty ? .available : .taken
            } catch {
                if SupabaseErrorMapper.isNetwork(error) {
                    return .error(UsernameError.network.errorDescription ?? "")
                }
                return .error(SupabaseErrorMapper.detail(error))
            }
            #else
            return .error(UsernameError
                .notConfigured(reason: .packageNotAdded)
                .errorDescription ?? "")
            #endif
        }
    }

    /// Claim `rawUsername` for `userId`. The `usernames` table has a
    /// unique constraint on `username`; a race with another claimer
    /// surfaces here as `.taken` rather than the raw Postgres error.
    /// On success, returns the canonical (lowercased) form so the
    /// caller can store exactly what landed in the row.
    func claim(_ rawUsername: String, userId: String) async throws -> String {
        let username: String
        switch UsernameValidator.validate(rawUsername) {
        case .success(let v): username = v
        case .failure(let err):
            throw UsernameError.invalid(err.errorDescription ?? "Invalid username.")
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw UsernameError.notConfigured(reason: .missingCredentials)
        }
        let canonicalUserId = userId.lowercased()
        let row = UsernameClaimRow(user_id: canonicalUserId, username: username)
        do {
            try await client
                .from("usernames")
                .insert(row)
                .execute()
            return username
        } catch {
            if SupabaseErrorMapper.isUsernameUniqueViolation(error) {
                throw UsernameError.taken
            }
            // Generic 23505 unique violation also lands here when the
            // constraint name doesn't match the heuristic — treat any
            // unique violation on `usernames` as "taken" since that's
            // the only unique constraint on the table.
            let text = String(describing: error).lowercased()
            if text.contains("23505") || text.contains("duplicate key") {
                throw UsernameError.taken
            }
            if SupabaseErrorMapper.isNetwork(error) {
                throw UsernameError.network
            }
            throw UsernameError.unknown(SupabaseErrorMapper.detail(error))
        }
        #else
        throw UsernameError.notConfigured(reason: .packageNotAdded)
        #endif
    }
}

// MARK: - Wire payloads

private nonisolated struct UsernameRow: Decodable, Sendable {
    let username: String
}

private nonisolated struct UsernameClaimRow: Encodable {
    let user_id: String
    let username: String
}
