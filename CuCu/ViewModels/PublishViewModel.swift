import Foundation
import Observation

/// Drives the publish sheet's UI through a small explicit state machine. The
/// service is pure I/O; this view model owns transitions, error mapping, and
/// post-success local-draft updates.
@MainActor
@Observable
final class PublishViewModel {
    enum Status: Equatable {
        case idle
        case validating
        case uploadingAssets
        case savingProfile
        case success(PublishedProfileResult)
        case failure(String)
    }

    private(set) var status: Status = .idle

    var isWorking: Bool {
        switch status {
        case .validating, .uploadingAssets, .savingProfile: return true
        default: return false
        }
    }

    var canRetry: Bool {
        if case .failure = status { return true }
        return false
    }

    func reset() { status = .idle }

    /// Runs the whole flow, updating `status` as it advances. Caller is
    /// responsible for persisting `publishedProfileId/Username/lastPublishedAt`
    /// onto the local ProfileDraft on success.
    ///
    /// The flow operates on the v2 `ProfileDocument` directly — the local
    /// document is never mutated, only walked for asset paths. The
    /// authenticated user already carries their claimed `username`
    /// (hydrated by `AuthViewModel` after sign-in), so no username
    /// argument is plumbed through here — the publish service pulls
    /// it directly off `user`.
    func publish(
        user: AppUser,
        draft: ProfileDraft,
        document: ProfileDocument,
        category: ProfileVibe? = nil
    ) async {
        status = .validating

        guard let username = user.username, !username.isEmpty else {
            status = .failure("Pick a username before publishing.")
            return
        }
        if case .failure(let err) = UsernameValidator.validate(username) {
            status = .failure(err.errorDescription ?? "Username is invalid.")
            return
        }

        let canonicalUserId = user.id.lowercased()

        // Authorship guard: refuse to publish someone else's draft.
        // SwiftData isn't user-scoped, so a sign-out → sign-in-as-
        // different-account on the same device can leave the
        // editor pointed at the previous user's draft. Without
        // this guard, hitting Publish would write the previous
        // user's design under the new user's username — exactly
        // the "publishing another user's profile" symptom we're
        // closing off. `BuildTab` already filters drafts to ones
        // the current account owns or hasn't claimed yet, so this
        // path should be unreachable in normal flow; the guard is
        // a second line of defense for stale views and any
        // pre-existing draft that snuck through pre-fix.
        if let draftOwner = draft.ownerUserId, draftOwner != canonicalUserId {
            status = .failure("This draft belongs to a different account. Switch back, or start a new draft to publish.")
            return
        }
        // Claim the draft if it's never been stamped — the user
        // is publishing it, so they're authoring it as far as we
        // care. Stops it from getting re-claimed by a future
        // account on the same device.
        if draft.ownerUserId == nil {
            draft.ownerUserId = canonicalUserId
        }

        // Cross-account guard: if this draft was last published by a
        // *different* Supabase user (sign-out → sign-up on the same
        // device), drop the stale `publishedProfileId` so the upsert
        // becomes a fresh INSERT for the current user. Without this
        // we'd hand the service the previous owner's profile id and
        // Postgres would reject the upsert on the profiles UPDATE
        // policy's `using (auth.uid() = user_id)` clause — surfacing
        // as the cryptic "(using expression)" RLS failure.
        if let owner = draft.publishedOwnerUserId, owner != canonicalUserId {
            draft.publishedProfileId = nil
            draft.publishedUsername = nil
            draft.lastPublishedAt = nil
            draft.publishedOwnerUserId = nil
        }

        // Service drives explicit phase transitions through `onPhaseChange`,
        // so the spinner label flips from "Uploading images…" to "Saving
        // profile…" exactly when the work moves between those phases.
        status = .uploadingAssets
        let service = PublishService(user: user, draftID: draft.id)
        do {
            let result = try await service.publish(
                existingProfileId: draft.publishedProfileId,
                document: document,
                category: category?.rawValue,
                onPhaseChange: { [weak self] phase in
                    guard let self else { return }
                    switch phase {
                    case .uploadingAssets: self.status = .uploadingAssets
                    case .savingProfile: self.status = .savingProfile
                    }
                }
            )
            status = .success(result)
        } catch let err as PublishError {
            status = .failure(err.errorDescription ?? "Couldn't publish.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
