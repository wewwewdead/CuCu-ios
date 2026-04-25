import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Result handed back to the UI on a successful publish.
struct PublishedProfileResult: Sendable, Equatable {
    let profileId: String
    let username: String
    let publicPath: String  // e.g. "/@alice"
}

/// All errors the publish flow can surface. Drives clear inline error
/// messages in the publish sheet without leaking SDK types.
enum PublishError: Error, LocalizedError, Equatable {
    case notSignedIn
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case usernameInvalid(reason: String)
    case usernameTaken
    case missingAsset(localPath: String)
    case uploadFailed(String)
    case database(String)
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You need to sign in to publish."
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to enable publishing."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to SupabaseSecrets.plist."
        case .usernameInvalid(let reason):
            return reason
        case .usernameTaken:
            return "That username is already taken. Try a different one."
        case .missingAsset(let path):
            return "Couldn't find a local image (\(path)). Re-pick that image and try again."
        case .uploadFailed(let detail):
            return "Image upload failed: \(detail)"
        case .database(let detail):
            return "Couldn't save your profile: \(detail)"
        case .network:
            return "Couldn't reach Supabase. Check your connection and try again."
        case .unknown(let detail):
            return detail
        }
    }
}

/// Username rules mirror the SQL `check` constraint exactly so the client
/// rejects bad input before we ever round-trip to Postgres.
enum UsernameValidator {
    static func validate(_ raw: String) -> Result<String, PublishError> {
        let username = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard username.count >= 3 && username.count <= 30 else {
            return .failure(.usernameInvalid(reason: "Username must be 3–30 characters."))
        }
        // Lowercase letters, digits, underscore — same as the SQL constraint.
        let pattern = #"^[a-z0-9_]+$"#
        if username.range(of: pattern, options: .regularExpression) == nil {
            return .failure(.usernameInvalid(
                reason: "Username can only contain lowercase letters, numbers, and underscores."
            ))
        }
        return .success(username)
    }
}

/// Orchestrates the full publish flow:
///
///   1. Validate username
///   2. Decide profileId (existing if previously published, else new UUID)
///   3. Upload each local image asset to Storage
///   4. Build a local-path → public-URL map
///   5. Build a *transformed* ProfileDesign for the cloud copy
///   6. Upsert the `profiles` row + `profile_assets` rows
///   7. Return a PublishedProfileResult
///
/// Local-only effects: nothing in this service mutates the local
/// ProfileDraft / SwiftData. The caller (PublishViewModel) handles updating
/// `draft.publishedProfileId/publishedUsername/lastPublishedAt` after a
/// successful return.
@MainActor
struct PublishService {
    /// Phases the UI can observe while `publish(...)` runs. Surfaced through
    /// the `onPhaseChange` closure so the publish sheet can flip its spinner
    /// label between "Uploading images…" and "Saving profile…".
    enum Phase {
        case uploadingAssets
        case savingProfile
    }

    let user: AppUser
    let draftID: UUID

    func publish(
        existingProfileId: String?,
        design: ProfileDesign,
        username rawUsername: String,
        displayName: String?,
        onPhaseChange: ((Phase) -> Void)? = nil
    ) async throws -> PublishedProfileResult {
        // 1. Validate
        let username: String
        switch UsernameValidator.validate(rawUsername) {
        case .success(let v): username = v
        case .failure(let e): throw e
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishError.notConfigured(reason: .missingCredentials)
        }

        // 2. Determine profile id BEFORE any I/O so storage paths are stable
        //    across upload + DB insert (and across republishes).
        let profileId: String = existingProfileId ?? UUID().uuidString

        // 3. Upload local assets, collecting (localPath → publicURL).
        onPhaseChange?(.uploadingAssets)
        var pathMap: [String: String] = [:]
        var assetRows: [PublishedAssetRow] = []

        // Block images — walk recursively so images nested inside containers
        // are uploaded too. `imageBlocksDeep` flattens the recursion.
        for data in design.blocks.imageBlocksDeep where !data.localImagePath.isEmpty {
            // Skip duplicates if the same local path is referenced by more
            // than one block (uncommon but cheap to defend against).
            guard pathMap[data.localImagePath] == nil else { continue }
            let storagePath = "user_\(user.id)/profile_\(profileId)/block_\(data.id.uuidString).jpg"
            let publicURL = try await uploadAsset(
                client: client,
                relativeLocalPath: data.localImagePath,
                storagePath: storagePath
            )
            pathMap[data.localImagePath] = publicURL
            assetRows.append(PublishedAssetRow(
                profile_id: profileId,
                user_id: user.id,
                local_path: data.localImagePath,
                storage_path: storagePath,
                public_url: publicURL,
                asset_type: "image_block"
            ))
        }

        // Background image
        if let bgLocal = design.theme.backgroundImagePath, !bgLocal.isEmpty {
            let storagePath = "user_\(user.id)/profile_\(profileId)/background.jpg"
            let publicURL = try await uploadAsset(
                client: client,
                relativeLocalPath: bgLocal,
                storagePath: storagePath
            )
            pathMap[bgLocal] = publicURL
            assetRows.append(PublishedAssetRow(
                profile_id: profileId,
                user_id: user.id,
                local_path: bgLocal,
                storage_path: storagePath,
                public_url: publicURL,
                asset_type: "background"
            ))
        }

        // 4-5. Transform design (pure copy; local draft untouched).
        let publishedDesign = PublishedDesignTransformer.transform(design, replacing: pathMap)

        // 6. Upsert profile row.
        onPhaseChange?(.savingProfile)
        let profileRow = PublishedProfileRow(
            id: profileId,
            user_id: user.id,
            username: username,
            display_name: displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            design_json: publishedDesign,
            is_published: true,
            published_at: ISO8601DateFormatter().string(from: .now)
        )

        // TODO(phase 5+): if a later step fails between profile upsert and
        // asset-row insert, storage objects may be orphaned. The cleanup
        // below covers the upsert-failure case only; deeper rollback would
        // require a 2PC or a server-side transaction.
        do {
            try await client
                .from("profiles")
                .upsert(profileRow, onConflict: "id")
                .execute()
        } catch {
            // Best-effort scrub: remove anything we just uploaded so a failed
            // publish doesn't leave dangling files. Failures here are ignored
            // because the user is about to see the upsert error anyway.
            if !assetRows.isEmpty {
                _ = try? await client.storage
                    .from("profile-assets")
                    .remove(paths: assetRows.map { $0.storage_path })
            }
            throw mapDatabaseError(error)
        }

        // 6b. Replace any prior asset rows for this profile.
        if !assetRows.isEmpty {
            do {
                try await client.from("profile_assets")
                    .delete()
                    .eq("profile_id", value: profileId)
                    .execute()
                try await client.from("profile_assets")
                    .insert(assetRows)
                    .execute()
            } catch {
                // Asset row write failures are non-fatal — the publish itself
                // succeeded; the rows are mostly bookkeeping for now.
            }
        }

        return PublishedProfileResult(
            profileId: profileId,
            username: username,
            publicPath: "/@\(username)"
        )
        #else
        throw PublishError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    #if canImport(Supabase)
    /// Reads bytes for `relativeLocalPath`, uploads to `storagePath`, and
    /// returns the public URL. Throws `.missingAsset` if the local file
    /// is gone, `.uploadFailed` on any network/storage failure.
    private func uploadAsset(
        client: SupabaseClient,
        relativeLocalPath: String,
        storagePath: String
    ) async throws -> String {
        guard let localURL = LocalAssetStore.resolveURL(relativePath: relativeLocalPath),
              let bytes = try? Data(contentsOf: localURL) else {
            throw PublishError.missingAsset(localPath: relativeLocalPath)
        }
        do {
            // supabase-swift exposes `upload(_:data:options:)` (path is the
            // unlabeled first argument; `path:file:options:` is deprecated).
            _ = try await client.storage
                .from("profile-assets")
                .upload(
                    storagePath,
                    data: bytes,
                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                )
        } catch {
            throw PublishError.uploadFailed(error.localizedDescription)
        }
        do {
            let url = try client.storage
                .from("profile-assets")
                .getPublicURL(path: storagePath)
            return url.absoluteString
        } catch {
            throw PublishError.uploadFailed(error.localizedDescription)
        }
    }

    private func mapDatabaseError(_ error: Error) -> PublishError {
        // Prefer the typed Postgres error when available — substring matching
        // on `String(describing:)` is brittle across SDK versions. SQLSTATE
        // 23505 is `unique_violation`; on the `profiles` upsert it's
        // overwhelmingly the username unique constraint.
        if let pgErr = error as? PostgrestError, pgErr.code == "23505" {
            return .usernameTaken
        }
        let text = String(describing: error).lowercased()
        if text.contains("23505") || text.contains("duplicate key") || text.contains("unique") {
            if text.contains("username") {
                return .usernameTaken
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return .network
        }
        return .database(error.localizedDescription)
    }
    #endif
}

// MARK: - Wire payloads (snake_case keys to match Postgres columns)

/// Encoded as JSON for the `profiles.design_json` column. Field names map 1:1
/// to columns; the nested `ProfileDesign` is serialized as a JSON object and
/// stored in the `jsonb` column.
private struct PublishedProfileRow: Encodable {
    let id: String
    let user_id: String
    let username: String
    let display_name: String?
    let design_json: ProfileDesign
    let is_published: Bool
    let published_at: String
}

private struct PublishedAssetRow: Encodable {
    let profile_id: String
    let user_id: String
    let local_path: String?
    let storage_path: String
    let public_url: String?
    let asset_type: String
}
