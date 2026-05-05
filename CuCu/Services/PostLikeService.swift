import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Errors surfaced by the like flow. `PostFeedViewModel` /
/// `PostThreadViewModel` translate these into rollbacks; nothing
/// blocks the UI on a like failure beyond reverting the
/// optimistic flip.
enum PostLikeError: Error, LocalizedError, Equatable {
    case notSignedIn
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You need to sign in to like posts."
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to enable likes."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to enable likes."
        case .network:
            return "Couldn't reach the server."
        case .unknown(let detail):
            return detail
        }
    }
}

nonisolated struct PostLikeMutationResult: Equatable, Sendable {
    let postId: String
    let viewerHasLiked: Bool
    let likeCount: Int
}

/// Reads / writes the `post_likes` table.
///
/// One row per (post_id, user_id) pair (uniquely constrained
/// server-side). The `posts` row's `like_count` is maintained by
/// triggers on insert/delete here, so feeds don't need a join —
/// this service only handles the viewer's own like state and the
/// like/unlike toggle itself.
nonisolated struct PostLikeService {
    /// Return the subset of `postIds` that the current viewer has
    /// already liked. Used to hydrate `viewerLikedIds` in batch
    /// after a feed / thread fetch — one round-trip per page
    /// instead of N "have I liked this?" calls.
    ///
    /// Empty input short-circuits to an empty result so call
    /// sites can hand in a freshly-loaded page without a guard.
    func fetchLikeState(postIds: [String]) async -> Set<String> {
        guard !postIds.isEmpty else { return [] }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else { return [] }

        // Anonymous viewer — no row in `post_likes` to find.
        // Return early instead of round-tripping just to confirm
        // an empty set.
        guard let session = try? await client.auth.session else { return [] }
        let userId = session.user.id.uuidString.lowercased()

        do {
            let rows: [LikeRow] = try await client
                .from("post_likes")
                .select("post_id")
                .eq("user_id", value: userId)
                .in("post_id", values: postIds)
                .execute()
                .value
            return Set(rows.map { $0.post_id })
        } catch {
            // Soft fail — the heart just shows un-liked. The
            // viewer can still tap to like; the trigger keeps the
            // counter consistent regardless.
            return []
        }
        #else
        return []
        #endif
    }

    /// Toggle the current viewer's like through the database RPC
    /// that owns both the `post_likes` row and `posts.like_count`.
    /// The returned count is canonical, so optimistic UI settles
    /// to the same value other viewers will read on their next
    /// feed/thread fetch.
    func toggle(postId: String) async throws -> PostLikeMutationResult {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostLikeError.notConfigured(reason: .missingCredentials)
        }
        guard (try? await client.auth.session) != nil else {
            throw PostLikeError.notSignedIn
        }
        do {
            let rows: [LikeMutationRow] = try await client
                .rpc("toggle_post_like", params: ["p_post_id": postId])
                .execute()
                .value
            guard let row = rows.first else {
                throw PostLikeError.unknown("Like RPC returned no rows.")
            }
            return try row.toModel(fallbackPostId: postId)
        } catch let err as PostLikeError {
            throw err
        } catch {
            throw mapError(error)
        }
        #else
        throw PostLikeError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Insert a like. Idempotent at the SQL layer (unique
    /// constraint on `(post_id, user_id)` + `on conflict do
    /// nothing`), so a double-tap from a stuck UI doesn't
    /// double-count.
    func like(postId: String) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostLikeError.notConfigured(reason: .missingCredentials)
        }
        guard let session = try? await client.auth.session else {
            throw PostLikeError.notSignedIn
        }
        let userId = session.user.id.uuidString.lowercased()
        let row = NewLike(user_id: userId, post_id: postId)
        do {
            try await client
                .from("post_likes")
                .upsert(row, onConflict: "post_id,user_id")
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw PostLikeError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    func unlike(postId: String) async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PostLikeError.notConfigured(reason: .missingCredentials)
        }
        guard let session = try? await client.auth.session else {
            throw PostLikeError.notSignedIn
        }
        let userId = session.user.id.uuidString.lowercased()
        do {
            try await client
                .from("post_likes")
                .delete()
                .eq("post_id", value: postId)
                .eq("user_id", value: userId)
                .execute()
        } catch {
            throw mapError(error)
        }
        #else
        throw PostLikeError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    #if canImport(Supabase)
    private func mapError(_ error: Error) -> PostLikeError {
        if SupabaseErrorMapper.isNetwork(error) { return .network }
        return .unknown(SupabaseErrorMapper.detail(error))
    }
    #endif
}

// MARK: - Wire shapes

private nonisolated struct LikeRow: Decodable, Sendable {
    let post_id: String
}

private nonisolated struct NewLike: Encodable {
    let user_id: String
    let post_id: String
}

private nonisolated struct LikeMutationRow: Decodable, Sendable {
    let post_id: String?
    let liked: Bool?
    let viewer_has_liked: Bool?
    let like_count: Int

    func toModel(fallbackPostId: String) throws -> PostLikeMutationResult {
        guard let viewerHasLiked = liked ?? viewer_has_liked else {
            throw PostLikeError.unknown("Like RPC did not return liked state.")
        }
        return PostLikeMutationResult(
            postId: post_id ?? fallbackPostId,
            viewerHasLiked: viewerHasLiked,
            likeCount: like_count
        )
    }
}
