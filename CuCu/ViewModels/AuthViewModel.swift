import Foundation
import Observation

/// Observable wrapper around `AuthService` for SwiftUI views.
///
/// Created at app launch and injected via `.environment(_:)`. Tries to load
/// any persisted session in the background but never blocks the UI — the
/// app remains fully usable while this is in flight, including draft editing.
@MainActor
@Observable
final class AuthViewModel {
    private(set) var currentUser: AppUser?
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?
    private(set) var infoMessage: String?

    /// True when Supabase isn't reachable at all (no package or no creds).
    /// Surfaced to the UI as a calm "configure to publish" hint.
    let unavailability: SupabaseClientProvider.Unavailability?

    private let service = AuthService()

    init() {
        self.unavailability = SupabaseClientProvider.unavailability
        Task { await loadSession() }
    }

    var isSignedIn: Bool { currentUser != nil }

    func loadSession() async {
        currentUser = await service.currentUser()
    }

    func signIn(email: String, password: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        beginRequest()
        defer { endRequest() }
        do {
            currentUser = try await service.signIn(email: trimmed, password: password)
        } catch let err as AuthError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        beginRequest()
        defer { endRequest() }
        do {
            switch try await service.signUp(email: trimmed, password: password) {
            case .signedIn(let user):
                currentUser = user
            case .needsEmailVerification:
                infoMessage = "Check your email to verify your account, then sign in."
            }
        } catch let err as AuthError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        beginRequest()
        defer { endRequest() }
        do {
            try await service.signOut()
        } catch {
            // Sign-out failures don't matter to the user — clear local state
            // either way so the app reflects "logged out".
        }
        currentUser = nil
    }

    func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    private func beginRequest() {
        isLoading = true
        errorMessage = nil
        infoMessage = nil
    }

    private func endRequest() {
        isLoading = false
    }
}
