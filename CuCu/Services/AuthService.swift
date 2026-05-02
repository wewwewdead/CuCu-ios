import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Thin async wrapper around `client.auth`.
///
/// Returns app-level types (`AppUser`) so call sites stay free of Supabase
/// imports. All methods throw `AuthError` on failure and never crash —
/// missing-package and missing-config cases surface as `.notConfigured`.
enum AuthError: Error, LocalizedError, Equatable {
    case notConfigured(reason: SupabaseClientProvider.Unavailability)
    case invalidCredentials
    case emailAlreadyRegistered
    case weakPassword
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(.packageNotAdded):
            return "Add the Supabase Swift package in Xcode to enable publishing."
        case .notConfigured(.missingCredentials):
            return "Add your Supabase URL and anon key to SupabaseSecrets.plist."
        case .invalidCredentials:
            return "Wrong email or password."
        case .emailAlreadyRegistered:
            return "An account with that email already exists."
        case .weakPassword:
            return "Please choose a stronger password (at least 8 characters)."
        case .network:
            return "Couldn't reach Supabase. Check your connection and try again."
        case .unknown(let message):
            return message
        }
    }
}

nonisolated struct AuthService {

    /// Loads the persisted session if any. Returns nil when no user is signed
    /// in or when Supabase isn't configured (the caller treats both as
    /// "logged out", which is the right default for the offline-first app).
    func currentUser() async -> AppUser? {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else { return nil }
        // Avoid throwing on first launch when there's simply no session yet.
        if let session = try? await client.auth.session {
            return AppUser(id: session.user.id.uuidString,
                           email: session.user.email ?? "")
        }
        return nil
        #else
        return nil
        #endif
    }

    func signIn(email: String, password: String) async throws -> AppUser {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw AuthError.notConfigured(reason: .missingCredentials)
        }
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            return AppUser(id: session.user.id.uuidString,
                           email: session.user.email ?? "")
        } catch {
            throw mapAuthError(error)
        }
        #else
        throw AuthError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    /// Returns whether the new account requires email verification before it
    /// can sign in. When Supabase has email confirmation disabled, the
    /// session is established immediately and we return `false`.
    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else {
            throw AuthError.notConfigured(reason: .missingCredentials)
        }
        do {
            let response = try await client.auth.signUp(email: email, password: password)
            if let session = response.session {
                let user = AppUser(id: session.user.id.uuidString,
                                   email: session.user.email ?? "")
                return .signedIn(user)
            }
            return .needsEmailVerification
        } catch {
            throw mapAuthError(error)
        }
        #else
        throw AuthError.notConfigured(reason: .packageNotAdded)
        #endif
    }

    func signOut() async throws {
        #if canImport(Supabase)
        guard let client = SupabaseClientProvider.shared else { return }
        do {
            try await client.auth.signOut()
        } catch {
            throw mapAuthError(error)
        }
        #endif
    }

    enum SignUpOutcome: Equatable {
        case signedIn(AppUser)
        case needsEmailVerification
    }

    private func mapAuthError(_ error: Error) -> AuthError {
        let text = String(describing: error).lowercased()
        if text.contains("invalid login") || text.contains("invalid_credentials") {
            return .invalidCredentials
        }
        if text.contains("already registered") || text.contains("user_already_exists") {
            return .emailAlreadyRegistered
        }
        if text.contains("password") && text.contains("short") {
            return .weakPassword
        }
        if SupabaseErrorMapper.isNetwork(error) {
            return .network
        }
        return .unknown(SupabaseErrorMapper.detail(error))
    }
}
