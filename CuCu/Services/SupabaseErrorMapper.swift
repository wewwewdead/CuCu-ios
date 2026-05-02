import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Small string/typed-error classifier for Supabase calls.
///
/// Supabase Swift wraps PostgREST, Storage, Auth, and URLSession failures
/// differently depending on which subsystem produced the error. Keeping this
/// mapping centralized lets services surface stable app-level errors without
/// leaking SDK types into SwiftUI.
nonisolated enum SupabaseErrorMapper {
    static func detail(_ error: Error) -> String {
        let localized = error.localizedDescription
        let described = String(describing: error)
        if localized.isEmpty || localized.hasPrefix("The operation could") {
            return described
        }
        if described.count > localized.count, described.lowercased().contains(localized.lowercased()) {
            return described
        }
        return localized
    }

    static func isNetwork(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }

        let text = detail(error).lowercased()
        let markers = [
            "not connected to the internet",
            "network connection was lost",
            "timed out",
            "cannot connect",
            "could not connect",
            "couldn't connect",
            "offline",
            "dns",
            "host",
            "urlsession",
            "networkerror"
        ]
        return markers.contains { text.contains($0) }
    }

    static func isStoragePolicyDenied(_ error: Error) -> Bool {
        let text = detail(error).lowercased()
        let policyMarkers = [
            "row-level security",
            "violates row-level security policy",
            "new row violates row-level security policy",
            "permission denied",
            "not authorized",
            "unauthorized",
            "forbidden",
            "403",
            "42501"
        ]
        guard policyMarkers.contains(where: { text.contains($0) }) else { return false }
        return text.contains("policy")
            || text.contains("rls")
            || text.contains("storage")
            || text.contains("object")
            || text.contains("permission")
            || text.contains("authorized")
            || text.contains("forbidden")
    }

    static func isUsernameUniqueViolation(_ error: Error) -> Bool {
        #if canImport(Supabase)
        if let pgErr = error as? PostgrestError, pgErr.code == "23505" {
            let text = String(describing: pgErr).lowercased()
            return text.isEmpty || text.contains("username") || text.contains("profiles")
        }
        #endif

        let text = detail(error).lowercased()
        guard text.contains("23505")
            || text.contains("duplicate key")
            || text.contains("unique constraint")
            || text.contains("unique violation")
        else { return false }
        return text.contains("username") || text.contains("profiles_username")
    }
}
