import Foundation
import Observation

/// Drives `UsernamePickerView` through a small phase-driven state machine.
///
/// Mirrors `PublishViewModel`'s pattern: the view binds to a single
/// `phase` value and reads derived flags off the view model rather than
/// switching on the phase in three places. Owns the 400 ms availability
/// debounce so the SwiftUI side stays declarative.
@MainActor
@Observable
final class UsernameClaimViewModel {
    enum Phase: Equatable {
        case idle
        case checking
        case available
        case unavailable(String)
        case claiming
        case claimed(String)
        case failed(String)
    }

    /// Single source of truth for the picker's UI state. The view never
    /// inspects intermediate booleans — it switches off `phase` (or reads
    /// the derived flags below) so impossible states (e.g. "checking and
    /// claimed at the same time") aren't representable.
    private(set) var phase: Phase = .idle

    /// Bound to the text field. Lower-cased on submit; the picker echoes
    /// the user's typing verbatim so caps don't disappear under their
    /// fingers, but the validator works on a trimmed/lowercased copy.
    var input: String = ""

    private var debounceTask: Task<Void, Never>?
    private let service = UsernameService()

    /// Window after which the most recent keystroke triggers an
    /// availability check. 400 ms is the standard "user paused
    /// typing" threshold — fast enough that the hint shows up before
    /// they tap Claim, slow enough that we don't fire a request per
    /// character on a 60 wpm typist.
    private let debounceNanoseconds: UInt64 = 400_000_000

    /// Called from `onChange(of: input)`. Cancels any in-flight check,
    /// validates locally, then schedules a debounced availability call.
    /// Local validation runs **before** the debounce so format errors
    /// surface instantly — no point waiting 400 ms to tell the user
    /// they typed an uppercase letter.
    func onInputChange(_ value: String) {
        debounceTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }

        switch UsernameValidator.validate(trimmed) {
        case .failure(let err):
            phase = .unavailable(err.errorDescription ?? "Invalid username.")
            return
        case .success:
            break
        }

        phase = .checking
        let captured = trimmed
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanoseconds ?? 400_000_000)
            guard !Task.isCancelled, let self else { return }
            let result = await self.service.checkAvailability(captured)
            guard !Task.isCancelled else { return }
            // The user may have kept typing while the network call
            // was in flight — only honor the result if the trimmed
            // input still matches what we sent.
            let nowTrimmed = self.input
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard nowTrimmed == captured else { return }
            switch result {
            case .available:
                self.phase = .available
            case .taken:
                self.phase = .unavailable("That username is already taken.")
            case .invalid(let message):
                self.phase = .unavailable(message)
            case .error(let message):
                self.phase = .failed(message)
            }
        }
    }

    /// Fire the claim. Returns the canonical username on success so the
    /// caller can pass it to `AuthViewModel.setClaimedUsername`. Returns
    /// nil on failure — `phase` carries the reason (`.unavailable` or
    /// `.failed`) so the view re-renders without the caller plumbing
    /// errors through.
    func claim(userId: String) async -> String? {
        // Block the call when the form isn't in an actionable state so
        // a stale "Claim" tap from a fast double-tap doesn't fire after
        // the input has gone stale.
        guard case .available = phase else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        phase = .claiming
        do {
            let canonical = try await service.claim(trimmed, userId: userId)
            phase = .claimed(canonical)
            return canonical
        } catch let err as UsernameError {
            switch err {
            case .taken:
                phase = .unavailable("That username is already taken.")
            case .invalid(let reason):
                phase = .unavailable(reason)
            default:
                phase = .failed(err.errorDescription ?? "Couldn't claim that username.")
            }
            return nil
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    var canSubmit: Bool {
        if case .available = phase { return true }
        return false
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .claiming: return true
        default: return false
        }
    }

    /// Inline hint shown beneath the text field. Returns `nil` when the
    /// field is idle / actively claiming so the row collapses cleanly.
    var hint: (text: String, kind: HintKind)? {
        switch phase {
        case .idle, .checking, .claiming: return nil
        case .available: return ("Available", .success)
        case .claimed(let name): return ("Claimed @\(name)", .success)
        case .unavailable(let message): return (message, .warning)
        case .failed(let message): return (message, .warning)
        }
    }

    enum HintKind { case success, warning }
}
