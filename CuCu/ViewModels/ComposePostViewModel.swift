import Foundation
import Observation

/// Drives `ComposePostSheet` through an explicit state machine —
/// same shape as `PublishViewModel` so the SwiftUI side switches on
/// a single `status` value instead of juggling `isSubmitting` /
/// `errorMessage` / `result` booleans.
///
/// Owns the body text and the submit pipeline; the sheet binds to
/// `body`, reads derived flags (`remainingChars`, `canSubmit`), and
/// calls `submit(parentId:)` from its button.
@MainActor
@Observable
final class ComposePostViewModel {
    enum Status: Equatable {
        case idle
        case submitting
        case success(Post)
        case failure(String)
    }

    /// Single source of truth for the sheet's UI state. The view
    /// switches on this rather than inspecting intermediate flags so
    /// impossible combinations ("submitting and succeeded at once")
    /// aren't representable.
    private(set) var status: Status = .idle

    /// Bound to the `TextEditor`. Persists across `.failure` so a
    /// retry doesn't lose what the user typed.
    var body: String = ""

    /// Mirrors `PostService.bodyCharacterLimit` — kept here as a
    /// computed pass-through so the view doesn't reach into the
    /// service layer for a constant.
    var maxBodyLength: Int { PostService.bodyCharacterLimit }

    /// Drives the live counter. Goes negative once the user blows
    /// past the limit so the sheet can flip the colour to red and
    /// disable submit.
    var remainingChars: Int {
        maxBodyLength - body.count
    }

    /// Submit is enabled only when the body is non-empty (after a
    /// trim — pure whitespace shouldn't post), within the character
    /// budget, and the view-model isn't already mid-submit. The
    /// service re-validates on the wire path so a bypassed UI guard
    /// can't write a malformed row.
    var canSubmit: Bool {
        guard !isSubmitting else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.count <= maxBodyLength
    }

    var isSubmitting: Bool {
        if case .submitting = status { return true }
        return false
    }

    private let service = PostService()

    /// Reset back to `.idle` after the sheet has consumed a `.success`
    /// or the user has acknowledged a `.failure`. Caller-driven so
    /// the view can decide when the transition feels right (e.g.,
    /// success dismisses the sheet, failure stays open).
    func reset() { status = .idle }

    /// Run the create-post call. On `.success` the sheet should
    /// fire `onPosted(post)` and dismiss; on `.failure` it stays
    /// open with `body` intact for retry.
    ///
    /// The view-model never throws — every error is mapped onto
    /// `status = .failure(message)` so the sheet has one place to
    /// render the error.
    func submit(user: AppUser, parentId: String?) async {
        guard !isSubmitting else { return }
        status = .submitting
        do {
            let post = try await service.createPost(
                user: user,
                body: body,
                parentId: parentId
            )
            status = .success(post)
        } catch let err as PostError {
            // `PostError`'s `errorDescription` already produces the
            // user-facing string (rate-limit copy, body-too-long,
            // etc.) — surface it verbatim so the sheet doesn't have
            // to know about each case.
            status = .failure(err.errorDescription ?? "Couldn't post.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
