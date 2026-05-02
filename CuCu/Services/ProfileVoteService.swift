import Foundation
#if canImport(Supabase)
import Supabase
#endif

enum ProfileVoteError: Error, LocalizedError, Equatable {
    case notSignedIn
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case policyDenied
    case network
    case database(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to vote on profiles."
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to vote on profiles."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to vote on profiles."
        case .policyDenied:
            return "Voting was blocked by Supabase RLS. Apply `Supabase/schema_likes_hottest.sql`, then sign out and sign back in."
        case .network:
            return "Couldn't reach Supabase. Check your connection and try again."
        case .database(let detail):
            return "Couldn't update your vote: \(detail)"
        }
    }
}

nonisolated struct ProfileVoteState: Sendable, Equatable {
    let profileId: String
    let voteCount: Int
    let hasVoted: Bool
}

nonisolated struct ProfileVoteService {
    func fetchVoteState(profileId rawProfileId: String, user: AppUser?) async throws -> ProfileVoteState {
        let profileId = rawProfileId.lowercased()
        let stats = try await fetchStats(profileId: profileId)
        guard let user else {
            return ProfileVoteState(profileId: profileId, voteCount: stats.voteCount, hasVoted: false)
        }
        let hasVoted = try await fetchHasVoted(profileId: profileId, user: user)
        return ProfileVoteState(profileId: profileId, voteCount: stats.voteCount, hasVoted: hasVoted)
    }

    func fetchVoteCount(profileId rawProfileId: String) async throws -> Int {
        try await fetchStats(profileId: rawProfileId.lowercased()).voteCount
    }

    func fetchStats(profileId rawProfileId: String) async throws -> PublishedProfileStats {
        let profileId = rawProfileId.lowercased()
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw ProfileVoteError.notConfigured(reason: .missingCredentials)
        }
        do {
            let rows: [PublishedProfileStatsRow] = try await client
                .from("published_profile_stats")
                .select("profile_id,vote_count,votes_last_24h,votes_last_7d,hot_score")
                .eq("profile_id", value: profileId)
                .limit(1)
                .execute()
                .value
            return rows.first?.toModel() ?? PublishedProfileStats(
                profileId: profileId,
                voteCount: 0,
                votesLast24Hours: 0,
                votesLast7Days: 0,
                hotScore: 0
            )
        } catch let decodeErr as DecodingError {
            throw ProfileVoteError.database(String(describing: decodeErr))
        } catch {
            throw map(error)
        }
        #else
        throw ProfileVoteError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    func vote(profileId rawProfileId: String, user: AppUser) async throws {
        let row = ProfileVoteInsertRow(
            profile_id: rawProfileId.lowercased(),
            user_id: user.id.lowercased()
        )
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw ProfileVoteError.notConfigured(reason: .missingCredentials)
        }
        do {
            try await client
                .from("profile_votes")
                .insert(row)
                .execute()
        } catch {
            let text = SupabaseErrorMapper.detail(error).lowercased()
            if text.contains("23505") || text.contains("duplicate key") {
                return
            }
            throw map(error)
        }
        #else
        throw ProfileVoteError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    func unvote(profileId rawProfileId: String, user: AppUser) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw ProfileVoteError.notConfigured(reason: .missingCredentials)
        }
        do {
            try await client
                .from("profile_votes")
                .delete()
                .eq("profile_id", value: rawProfileId.lowercased())
                .eq("user_id", value: user.id.lowercased())
                .execute()
        } catch {
            throw map(error)
        }
        #else
        throw ProfileVoteError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    private func fetchHasVoted(profileId: String, user: AppUser) async throws -> Bool {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw ProfileVoteError.notConfigured(reason: .missingCredentials)
        }
        do {
            let rows: [ProfileVotePresenceRow] = try await client
                .from("profile_votes")
                .select("id")
                .eq("profile_id", value: profileId)
                .eq("user_id", value: user.id.lowercased())
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            throw map(error)
        }
        #else
        throw ProfileVoteError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    private func map(_ error: Error) -> ProfileVoteError {
        if SupabaseErrorMapper.isNetwork(error) {
            return .network
        }
        if SupabaseErrorMapper.isStoragePolicyDenied(error) {
            return .policyDenied
        }
        return .database(SupabaseErrorMapper.detail(error))
    }
}

private nonisolated struct ProfileVoteInsertRow: Encodable {
    let profile_id: String
    let user_id: String
}

private nonisolated struct ProfileVotePresenceRow: Decodable {
    let id: String
}
