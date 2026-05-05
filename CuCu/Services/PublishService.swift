import Foundation
import CryptoKit
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
    case storagePolicyDenied
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
        case .storagePolicyDenied:
            return "Image upload was blocked by your Supabase storage policy. Check that the `profile-assets` bucket exists and that the storage policies in `Supabase/schema_publish_profiles.sql` have been applied. If the bucket and policies are in place, sign out and sign back in to refresh your session."
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
nonisolated enum UsernameValidator {
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
nonisolated struct PublishService {
    /// Phases the UI can observe while `publish(...)` runs. Surfaced through
    /// the `onPhaseChange` closure so the publish sheet can flip its spinner
    /// label between "Uploading images…" and "Saving profile…".
    enum Phase: Sendable {
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
        onPhaseChange: (@MainActor (Phase) -> Void)? = nil
    ) async throws -> PublishedProfileResult {
        // 1. Pull the username from the authenticated user. The picker
        //    flow guarantees this is set before we ever reach Publish;
        //    a nil here means the caller bypassed `requiresUsernameClaim`
        //    routing and should send the user back through the picker.
        let username: String
        switch UsernameValidator.validate(user.username ?? "") {
        case .success(let v): username = v
        case .failure: throw PublishError.usernameInvalid(
            reason: "Pick a username before publishing."
        )
        }

        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw PublishError.notConfigured(reason: .missingCredentials)
        }

        // 2. Determine profile id BEFORE any I/O so storage paths are stable
        //    across upload + DB insert (and across republishes).
        //
        //    Three-stage resolution, ordered by trust:
        //    a) Local `existingProfileId` if we still own that row — happy
        //       path for the typical republish.
        //    b) Server-side lookup by `user_id` if (a) failed. Catches the
        //       case where the local stamp drifted (sign-out/in, fresh
        //       install before re-stamp, SwiftData wipe, pre-
        //       `publishedOwnerUserId` drafts). Picks the user's most
        //       recently updated row so the result is deterministic when
        //       legacy data left multiple rows under one user_id.
        //    c) Fresh UUID when the user has no row anywhere — genuine
        //       first publish.
        //
        //    Without (b), an out-of-sync local stamp dropped the upsert
        //    into the INSERT branch and tripped `profiles.username`'s
        //    UNIQUE constraint against the user's *own* prior row,
        //    surfacing as a misleading "username is taken" error.
        let canonicalUserId = user.id.lowercased()
        let resolvedProfileId: String
        if let candidate = existingProfileId?.lowercased(),
           !candidate.isEmpty,
           try await isOwnedByCurrentUser(
               client: client,
               profileId: candidate,
               userId: canonicalUserId
           ) {
            resolvedProfileId = candidate
        } else if let serverId = try await findOwnedProfileId(
            client: client,
            userId: canonicalUserId
        ) {
            #if DEBUG
            if let candidate = existingProfileId?.lowercased(),
               !candidate.isEmpty,
               candidate != serverId {
                print("PublishService: local publishedProfileId \(candidate) drifted from server row \(serverId); adopting server id.")
            }
            #endif
            resolvedProfileId = serverId
        } else {
            resolvedProfileId = UUID().uuidString
        }

        // Storage RLS compares the path's first folder component to
        // `'user_' || auth.uid()::text`. Postgres renders a UUID as
        // lowercase hex; Foundation's `UUID.uuidString` is uppercase
        // (`E621E1F8-...`). Without normalisation the policy rejects
        // every upload as an RLS violation. Lowercase here once and
        // reuse the canonical form for the entire publish.
        let canonicalProfileId = resolvedProfileId.lowercased()

        let uploads = collectUploads(from: document)
        try validateLocalAssets(uploads)

        // 3. Walk asset surfaces, deduplicate, upload.
        await onPhaseChange?(.uploadingAssets)
        var pathMap: [String: String] = [:]
        var assetRows: [PublishedAssetRow] = []

        for upload in uploads {
            // Storage path: user_<userId>/profile_<pid>/<stem>_<hash8>.<ext>.
            // The basename's stem is deterministic per-node
            // (`draft_<UUID>/image_<UUID>.jpg` → `image_<UUID>`); the hash
            // suffix is the first 8 hex chars of SHA-256 over the bytes
            // we're about to upload. Same bytes → same path → CDN reuse;
            // different bytes → new path → cache bust without manual purge.
            // This is what makes the `immutable` cache header below safe.
            guard let localURL = LocalCanvasAssetStore.resolveURL(upload.localPath) else {
                throw PublishError.missingAsset(localPath: upload.localPath)
            }
            let bytes: Data
            do {
                bytes = try await readFileData(at: localURL)
            } catch {
                throw PublishError.missingAsset(localPath: upload.localPath)
            }
            let basename = (upload.localPath as NSString).lastPathComponent
            let hashedBasename = Self.contentHashedBasename(basename, bytes: bytes)
            let storagePath = "user_\(canonicalUserId)/profile_\(canonicalProfileId)/\(hashedBasename)"
            let publicURL = try await uploadAsset(
                client: client,
                bytes: bytes,
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
        var publishedDocument = PublishedDocumentTransformer.transform(
            document, replacing: pathMap
        )
        // Lift the hero avatar's resolved public URL into a top-level
        // key on `design_json` so the explore feed can extract it via
        // `design_json->>heroAvatarURL` without paying for the whole
        // scene graph per banner row. Only present after the publish
        // pipeline rewrote the local path to a Supabase URL — local-
        // only paths nil out (`heroAvatarPublicURL` filters those).
        publishedDocument.heroAvatarURL = heroAvatarPublicURL(in: publishedDocument)

        // 6. Upsert profile row. UUIDs sent to Postgres in lowercase so
        //    the row's `user_id` column matches `auth.uid()` exactly,
        //    which is what every owner-side RLS policy compares
        //    against (`auth.uid() = user_id`).
        await onPhaseChange?(.savingProfile)
        let profileRow = PublishedProfileRowEncodable(
            id: canonicalProfileId,
            user_id: canonicalUserId,
            username: username,
            design_json: publishedDocument,
            thumbnail_url: thumbnailURL(from: assetRows),
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

        // 6b. Replace any prior asset rows for this profile, and sweep any
        //      storage objects that those rows pointed at but the new rows
        //      don't. Required because hashed basenames mean a re-published
        //      profile uploads a *new* object instead of overwriting the
        //      old one — without this sweep, every edit would leak storage.
        if !assetRows.isEmpty {
            let newPaths = Set(assetRows.map { $0.storage_path })
            var orphanedPaths: [String] = []
            do {
                let oldRows: [StoredAssetPath] = try await client
                    .from("profile_assets")
                    .select("storage_path")
                    .eq("profile_id", value: canonicalProfileId)
                    .execute()
                    .value
                orphanedPaths = oldRows
                    .map { $0.storage_path }
                    .filter { !newPaths.contains($0) }
            } catch {
                // Couldn't read old rows; skip the sweep but keep going.
            }

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

            if !orphanedPaths.isEmpty {
                _ = try? await client.storage
                    .from("profile-assets")
                    .remove(paths: orphanedPaths)
            }
        }

        return PublishedProfileResult(
            profileId: canonicalProfileId,
            username: username,
            publicPath: ProfileShareLink.path(username: username)
        )
        #else
        throw PublishError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    // MARK: - Asset enumeration

    /// Walk the document's four asset surfaces and collect a deduplicated
    /// list of (path, asset_type) pairs to upload. Skips paths that
    /// already look remote (e.g. an unedited republish where a path is
    /// already a public URL), `bundled:` references that resolve to the
    /// app's asset catalog (seeded default templates use these for
    /// placeholder tone images), and empty strings.
    private func collectUploads(from document: ProfileDocument) -> [PendingUpload] {
        var seen = Set<String>()
        var uploads: [PendingUpload] = []

        for page in document.pages {
            if let p = page.backgroundImagePath,
               PublishedDocumentTransformer.isUploadable(p),
               seen.insert(p).inserted {
                uploads.append(PendingUpload(localPath: p, assetType: "page_background"))
            }
        }

        if let p = document.pageBackgroundImagePath,
           PublishedDocumentTransformer.isUploadable(p),
           seen.insert(p).inserted {
            uploads.append(PendingUpload(localPath: p, assetType: "page_background"))
        }

        for node in document.nodes.values {
            if let p = node.style.backgroundImagePath,
               PublishedDocumentTransformer.isUploadable(p),
               seen.insert(p).inserted {
                uploads.append(PendingUpload(localPath: p, assetType: "container_background"))
            }
            if let p = node.content.localImagePath,
               PublishedDocumentTransformer.isUploadable(p),
               seen.insert(p).inserted {
                uploads.append(PendingUpload(localPath: p, assetType: "image_node"))
            }
            if let arr = node.content.imagePaths {
                for p in arr where PublishedDocumentTransformer.isUploadable(p)
                    && seen.insert(p).inserted {
                    uploads.append(PendingUpload(localPath: p, assetType: "gallery_image"))
                }
            }
        }

        return uploads
    }

    /// Check every local asset before the first upload starts. This prevents
    /// a half-uploaded publish when the third image in a gallery is missing.
    private func validateLocalAssets(_ uploads: [PendingUpload]) throws {
        for upload in uploads {
            guard let url = LocalCanvasAssetStore.resolveURL(upload.localPath),
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw PublishError.missingAsset(localPath: upload.localPath)
            }
        }
    }

    private func thumbnailURL(from rows: [PublishedAssetRow]) -> String? {
        let preferredTypes = ["image_node", "gallery_image", "page_background", "container_background"]
        for assetType in preferredTypes {
            if let row = rows.first(where: { $0.asset_type == assetType }),
               let publicURL = row.public_url,
               !publicURL.isEmpty {
                return publicURL
            }
        }
        return nil
    }

    #if canImport(Supabase)
    /// Uploads `bytes` to `storagePath` in the `profile-assets` bucket and
    /// returns the public URL. Bytes are read once by the caller so the
    /// SHA-256 used to build `storagePath` is computed over the exact same
    /// buffer we upload. Throws `.uploadFailed` on any network/storage
    /// failure.
    private func uploadAsset(
        client: SupabaseClient,
        bytes: Data,
        storagePath: String
    ) async throws -> String {
        do {
            // supabase-swift exposes `upload(_:data:options:)` (path is the
            // unlabeled first argument; `path:file:options:` is deprecated).
            // `upsert: true` is harmless under content-hashed paths (same
            // bytes → same path → idempotent rewrite). `cacheControl` is
            // set to one year + `immutable` because the path itself busts
            // when bytes change, so the CDN can hold this object forever.
            _ = try await client.storage
                .from("profile-assets")
                .upload(
                    storagePath,
                    data: bytes,
                    options: FileOptions(
                        cacheControl: "31536000, immutable",
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )
        } catch {
            // Storage RLS rejections come back as a generic error string
            // mentioning "row-level security policy" or "violates ... policy".
            // Surface these as a typed `.storagePolicyDenied` so the UI can
            // explain how to fix the bucket setup, instead of dumping the
            // raw Postgres message at the user.
            if SupabaseErrorMapper.isStoragePolicyDenied(error) {
                throw PublishError.storagePolicyDenied
            }
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishError.network
            }
            throw PublishError.uploadFailed(SupabaseErrorMapper.detail(error))
        }
        do {
            let url = try client.storage
                .from("profile-assets")
                .getPublicURL(path: storagePath)
            return url.absoluteString
        } catch {
            throw PublishError.uploadFailed(SupabaseErrorMapper.detail(error))
        }
    }

    /// True when the row at `id = profileId` is owned by `userId`.
    /// Used as a pre-flight before the upsert so a stale local
    /// `existingProfileId` (e.g. signed-out → signed-up on the same
    /// device, where SwiftData carries the previous user's pointer)
    /// doesn't smuggle into someone else's row. The query is
    /// constrained on both id and user_id so the
    /// `Owners can read their own profiles` RLS policy
    /// (`using (auth.uid() = user_id)`) returns the row only when
    /// the current user actually owns it — the public-readable
    /// policy can't leak it through because we explicitly
    /// `eq("user_id", canonical)`.
    ///
    /// Returns false on a "not found" or RLS-hidden row, which is
    /// the right behaviour: in either case the caller should mint a
    /// fresh UUID rather than try to upsert into a row it doesn't
    /// own. Network errors propagate so the publish surfaces the
    /// real problem instead of silently treating it as
    /// not-our-row.
    private func isOwnedByCurrentUser(
        client: SupabaseClient,
        profileId: String,
        userId: String
    ) async throws -> Bool {
        struct OwnedCheckRow: Decodable, Sendable {
            let id: String
        }
        do {
            let rows: [OwnedCheckRow] = try await client
                .from("profiles")
                .select("id")
                .eq("id", value: profileId)
                .eq("user_id", value: userId)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishError.network
            }
            throw PublishError.database(SupabaseErrorMapper.detail(error))
        }
    }

    /// Look up the current user's most-recently-updated profile row.
    /// Used as the fallback when the local `existingProfileId` no longer
    /// matches a row this user owns — without this, an out-of-sync local
    /// stamp drops the upsert into the INSERT branch and trips the
    /// `username UNIQUE` constraint against the user's own prior row.
    ///
    /// Ordering: `updated_at DESC, id DESC` keeps the result deterministic
    /// even when legacy data left two rows with identical `updated_at`.
    /// Returns the canonical lowercase id (matching how Postgres renders
    /// UUIDs) so storage paths stay stable downstream.
    private func findOwnedProfileId(
        client: SupabaseClient,
        userId: String
    ) async throws -> String? {
        struct OwnedRow: Decodable, Sendable {
            let id: String
        }
        do {
            let rows: [OwnedRow] = try await client
                .from("profiles")
                .select("id")
                .eq("user_id", value: userId)
                .order("updated_at", ascending: false)
                .order("id", ascending: false)
                .limit(1)
                .execute()
                .value
            return rows.first?.id.lowercased()
        } catch {
            if SupabaseErrorMapper.isNetwork(error) {
                throw PublishError.network
            }
            throw PublishError.database(SupabaseErrorMapper.detail(error))
        }
    }

    private func mapDatabaseError(_ error: Error) -> PublishError {
        // Prefer the typed Postgres error when available — substring matching
        // on `String(describing:)` is brittle across SDK versions. SQLSTATE
        // 23505 is `unique_violation`; on the `profiles` upsert it's
        // overwhelmingly the username unique constraint.
        if SupabaseErrorMapper.isUsernameUniqueViolation(error) {
            return .usernameTaken
        }
        if SupabaseErrorMapper.isNetwork(error) {
            return .network
        }
        return .database(SupabaseErrorMapper.detail(error))
    }

    private func readFileData(at url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
    }
    #endif

    /// Build a content-addressed basename from the local file's basename and
    /// the bytes we're about to upload. Format: `<stem>_<hash8>.<ext>`,
    /// where `<hash8>` is the first 8 hex chars of SHA-256 over `bytes`.
    /// Eight chars (32 bits) is plenty for cache-busting at our scale —
    /// collision risk is bounded by assets per profile, not globally, and
    /// a within-profile collision still resolves to the same bytes.
    nonisolated static func contentHashedBasename(_ basename: String, bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        let hash8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let ns = basename as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        return ext.isEmpty ? "\(stem)_\(hash8)" : "\(stem)_\(hash8).\(ext)"
    }
}

// MARK: - Wire payloads (snake_case keys to match Postgres columns)

/// Encoded as JSON for the `profiles` row. Field names map 1:1 to columns;
/// the nested `ProfileDocument` is serialized as a JSON object and stored
/// in the `jsonb` column so the viewer can decode it back via the same
/// `Codable` machinery.
private nonisolated struct PublishedProfileRowEncodable: Encodable {
    let id: String
    let user_id: String
    let username: String
    let design_json: ProfileDocument
    let thumbnail_url: String?
    let is_published: Bool
    let published_at: String
}

/// Find the hero's `.profileAvatar` node and return its resolved
/// public URL. After `PublishedDocumentTransformer` runs, the
/// `content.localImagePath` field carries the Supabase URL the
/// asset was uploaded to. Returns `nil` when no avatar node exists,
/// the field is empty, or the path didn't get rewritten (still a
/// local file URI) — the banner falls through to the initial-letter
/// chip in those cases.
private func heroAvatarPublicURL(in document: ProfileDocument) -> String? {
    let avatar = document.nodes.values.first { $0.role == .profileAvatar }
    guard let path = avatar?.content.localImagePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty else { return nil }
    let lower = path.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
        return nil
    }
    return path
}

private nonisolated struct PublishedAssetRow: Encodable {
    let profile_id: String
    let user_id: String
    let local_path: String?
    let storage_path: String
    let public_url: String?
    let asset_type: String
}

/// Narrow projection used only for the orphan-sweep on republish — we just
/// need the storage paths the prior publish wrote so we can diff them
/// against the new ones and remove the leftovers.
private nonisolated struct StoredAssetPath: Decodable {
    let storage_path: String
}
