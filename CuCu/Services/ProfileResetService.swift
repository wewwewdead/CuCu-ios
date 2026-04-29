import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// All errors the reset / cloud-wipe flow can surface. Mirrors
/// `PublishError`'s tone so the UI's error-alert copy stays consistent
/// across publish / reset paths.
enum ProfileResetError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case storage(String)
    case database(String)
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to remove cloud data."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to SupabaseSecrets.plist."
        case .storage(let detail):
            return "Couldn't delete uploaded images: \(detail)"
        case .database(let detail):
            return "Couldn't delete the published profile row: \(detail)"
        case .network:
            return "Couldn't reach Supabase. Check your connection and try again."
        case .unknown(let detail):
            return detail
        }
    }
}

/// Removes a published profile from the cloud:
///
///   1. List + delete every object under
///      `profile-assets/user_<userId>/profile_<profileId>/`.
///   2. Best-effort delete from `profile_assets` (bookkeeping rows).
///   3. Delete the row from `profiles`.
///
/// Path canonicalisation matches `PublishService` exactly — Supabase's
/// storage RLS policies and the `profiles.id` column compare against
/// lowercase UUID strings, so we lowercase here once and reuse the
/// canonical form for every call. Skipping this normalisation makes
/// every delete an RLS violation against a path that "looks right" in
/// uppercase.
///
/// **Pagination.** `storage.list(path:)` defaults to a 100-item page,
/// which used to be enough for typical profiles. Default templates
/// ship galleries with multiple tiles plus icons, avatar, container
/// bgs, etc., so a busy profile can plausibly cross that boundary —
/// the wipe loops `list` + `remove` until the folder reads empty so
/// no orphaned objects survive a reset regardless of asset count.
/// A safety cap on iterations protects against unexpected loops if a
/// remove call ever silently fails to delete its targets.
@MainActor
struct ProfileResetService {
    let user: AppUser
    let profileId: String

    func wipe() async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw ProfileResetError.notConfigured(reason: .missingCredentials)
        }

        // Same canonicalisation rule as `PublishService` — see comments
        // there for why uppercase UUIDs trip RLS. The folder path
        // mirrors the upload-side scheme so we hit the exact same
        // objects we wrote during publish.
        let canonicalUserId = user.id.lowercased()
        let canonicalProfileId = profileId.lowercased()
        let folderPath = "user_\(canonicalUserId)/profile_\(canonicalProfileId)"

        // 1. List + delete every storage object under the profile folder.
        //    Loop until the folder reads empty so we don't strand
        //    orphaned objects past the 100-item default page. The
        //    iteration cap is generous (5000 objects-worth of pages)
        //    but bounded so a remove call that silently no-ops can't
        //    spin forever.
        do {
            let maxPages = 50
            var page = 0
            while page < maxPages {
                page += 1
                let objects = try await client.storage
                    .from("profile-assets")
                    .list(path: folderPath)
                if objects.isEmpty { break }

                let fullPaths = objects.map { "\(folderPath)/\($0.name)" }
                _ = try await client.storage
                    .from("profile-assets")
                    .remove(paths: fullPaths)
            }
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                throw ProfileResetError.network
            }
            throw ProfileResetError.storage(error.localizedDescription)
        }

        // 2. Best-effort: drop the bookkeeping rows in `profile_assets`.
        //    Wrapped in a swallowed catch because these rows are
        //    derivative — the storage objects above are the canonical
        //    artifact, and the `profiles.id` cascade in step 3 already
        //    handles the row from the user's perspective. If this fails
        //    (RLS / network blip) the next publish overwrites it anyway.
        do {
            try await client
                .from("profile_assets")
                .delete()
                .eq("profile_id", value: canonicalProfileId)
                .execute()
        } catch {
            // Non-fatal — see comment above.
        }

        // 3. Delete the `profiles` row itself. This is the user-visible
        //    "is this profile gone from the cloud?" check, so failures
        //    here have to surface as errors.
        do {
            try await client
                .from("profiles")
                .delete()
                .eq("id", value: canonicalProfileId)
                .execute()
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                throw ProfileResetError.network
            }
            throw ProfileResetError.database(error.localizedDescription)
        }
        #else
        throw ProfileResetError.notConfigured(reason: .packageNotAdded)
        #endif
    }
}
