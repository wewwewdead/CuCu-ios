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

/// Orchestrates the full v2 publish flow:
///
///   1. Validate username
///   2. Decide profileId (existing if previously published, else new UUID)
///   3. Walk every local asset surface in the `ProfileDocument`
///   4. Upload each asset to Storage under
///      `user_<userId>/profile_<profileId>/<basename>`
///   5. Build a `localPath → publicURL` map
///   6. Build a *transformed* ProfileDocument for the cloud copy
///   7. Upsert the `profiles` row + `profile_assets` rows
///   8. Return a PublishedProfileResult
///
/// **Local-only effects:** nothing in this service mutates the local
/// `ProfileDraft` / SwiftData. The caller (PublishViewModel) updates
/// `draft.publishedProfileId/publishedUsername/lastPublishedAt` after a
/// successful return. The local `ProfileDocument` is never mutated —
/// the published copy lives only inside the cloud row.
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

    /// One asset to upload, paired with the asset_type label that lands in
    /// `profile_assets.asset_type`. Built by walking the `ProfileDocument`'s
    /// four asset-bearing surfaces (page bg, container bg, image node,
    /// gallery node).
    private struct PendingUpload: Hashable {
        let localPath: String
        let assetType: String
    }

    func publish(
        existingProfileId: String?,
        document: ProfileDocument,
        username rawUsername: String,
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

        // Storage RLS compares the path's first folder component to
        // `'user_' || auth.uid()::text`. Postgres renders a UUID as
        // lowercase hex; Foundation's `UUID.uuidString` is uppercase
        // (`E621E1F8-...`). Without normalisation the policy rejects
        // every upload as an RLS violation. Lowercase here once and
        // reuse the canonical form for the entire publish.
        let canonicalUserId = user.id.lowercased()
        let canonicalProfileId = profileId.lowercased()

        // 3. Walk asset surfaces, deduplicate, upload.
        onPhaseChange?(.uploadingAssets)
        let uploads = collectUploads(from: document)
        var pathMap: [String: String] = [:]
        var assetRows: [PublishedAssetRow] = []

        for upload in uploads {
            // Storage path: user_<userId>/profile_<pid>/<basename>.
            // Basename is the last component of the local relative path
            // (`draft_<UUID>/image_<UUID>.jpg` → `image_<UUID>.jpg`),
            // which is already deterministic per-node, so re-publishes
            // overwrite the same object cleanly via `upsert: true`.
            let basename = (upload.localPath as NSString).lastPathComponent
            let storagePath = "user_\(canonicalUserId)/profile_\(canonicalProfileId)/\(basename)"
            let publicURL = try await uploadAsset(
                client: client,
                relativeLocalPath: upload.localPath,
                storagePath: storagePath
            )
            pathMap[upload.localPath] = publicURL
            assetRows.append(PublishedAssetRow(
                profile_id: canonicalProfileId,
                user_id: canonicalUserId,
                local_path: upload.localPath,
                storage_path: storagePath,
                public_url: publicURL,
                asset_type: upload.assetType
            ))
        }

        // 4-5. Transform document (pure copy; local document untouched).
        let publishedDocument = PublishedDocumentTransformer.transform(
            document, replacing: pathMap
        )

        // 6. Upsert profile row. UUIDs sent to Postgres in lowercase so
        //    the row's `user_id` column matches `auth.uid()` exactly,
        //    which is what every owner-side RLS policy compares
        //    against (`auth.uid() = user_id`).
        onPhaseChange?(.savingProfile)
        let profileRow = PublishedProfileRowEncodable(
            id: canonicalProfileId,
            user_id: canonicalUserId,
            username: username,
            design_json: publishedDocument,
            is_published: true,
            published_at: ISO8601DateFormatter().string(from: .now)
        )

        // If the profile upsert fails, scrub the storage objects we just
        // wrote so the cloud doesn't accumulate orphans on retry. Failures
        // beyond that point are non-fatal — the publish itself succeeded.
        do {
            try await client
                .from("profiles")
                .upsert(profileRow, onConflict: "id")
                .execute()
        } catch {
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
                    .eq("profile_id", value: canonicalProfileId)
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
            profileId: canonicalProfileId,
            username: username,
            publicPath: "/@\(username)"
        )
        #else
        throw PublishError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    // MARK: - Asset enumeration

    /// Walk the document's four asset surfaces and collect a deduplicated
    /// list of (path, asset_type) pairs to upload. Skips paths that
    /// already look remote (e.g. an unedited republish where a path is
    /// already a public URL) and empty strings.
    private func collectUploads(from document: ProfileDocument) -> [PendingUpload] {
        var seen = Set<String>()
        var uploads: [PendingUpload] = []

        for page in document.pages {
            if let p = page.backgroundImagePath, !p.isEmpty,
               !PublishedDocumentTransformer.isRemote(p), seen.insert(p).inserted {
                uploads.append(PendingUpload(localPath: p, assetType: "page_background"))
            }
        }

        if let p = document.pageBackgroundImagePath, !p.isEmpty,
           !PublishedDocumentTransformer.isRemote(p), seen.insert(p).inserted {
            uploads.append(PendingUpload(localPath: p, assetType: "page_background"))
        }

        for node in document.nodes.values {
            if let p = node.style.backgroundImagePath, !p.isEmpty,
               !PublishedDocumentTransformer.isRemote(p), seen.insert(p).inserted {
                uploads.append(PendingUpload(localPath: p, assetType: "container_background"))
            }
            if let p = node.content.localImagePath, !p.isEmpty,
               !PublishedDocumentTransformer.isRemote(p), seen.insert(p).inserted {
                uploads.append(PendingUpload(localPath: p, assetType: "image_node"))
            }
            if let arr = node.content.imagePaths {
                for p in arr where !p.isEmpty
                    && !PublishedDocumentTransformer.isRemote(p)
                    && seen.insert(p).inserted {
                    uploads.append(PendingUpload(localPath: p, assetType: "gallery_image"))
                }
            }
        }

        return uploads
    }

    #if canImport(Supabase)
    /// Reads bytes for `relativeLocalPath` (resolved through
    /// `LocalCanvasAssetStore`), uploads to `storagePath` in the
    /// `profile-assets` bucket, and returns the public URL. Throws
    /// `.missingAsset` if the local file is gone, `.uploadFailed` on any
    /// network/storage failure.
    private func uploadAsset(
        client: SupabaseClient,
        relativeLocalPath: String,
        storagePath: String
    ) async throws -> String {
        guard let localURL = LocalCanvasAssetStore.resolveURL(relativeLocalPath),
              let bytes = try? Data(contentsOf: localURL) else {
            throw PublishError.missingAsset(localPath: relativeLocalPath)
        }
        do {
            // supabase-swift exposes `upload(_:data:options:)` (path is the
            // unlabeled first argument; `path:file:options:` is deprecated).
            // `upsert: true` makes re-publishes overwrite cleanly.
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

/// Encoded as JSON for the `profiles` row. Field names map 1:1 to columns;
/// the nested `ProfileDocument` is serialized as a JSON object and stored
/// in the `jsonb` column so the viewer can decode it back via the same
/// `Codable` machinery.
private struct PublishedProfileRowEncodable: Encodable {
    let id: String
    let user_id: String
    let username: String
    let design_json: ProfileDocument
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
