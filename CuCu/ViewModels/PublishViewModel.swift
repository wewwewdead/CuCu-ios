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
    /// document is never mutated, only walked for asset paths. Username
    /// is the only user-facing identifier — display name and bio fields
    /// were removed; the canvas itself carries any "About" text the
    /// author wants on the public page.
    func publish(
        user: AppUser,
        draft: ProfileDraft,
        document: ProfileDocument,
        username: String
    ) async {
        status = .validating

        switch UsernameValidator.validate(username) {
        case .failure(let err):
            status = .failure(err.errorDescription ?? "Username is invalid.")
            return
        case .success:
            break
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
                username: username,
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
