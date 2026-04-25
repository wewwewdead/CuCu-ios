import Foundation
#if canImport(Supabase)
import Supabase
#endif

/// Holds the lazily-initialized `SupabaseClient`.
///
/// Builds without the `Supabase` SPM package compile too — every Supabase
/// reference is gated behind `#if canImport(Supabase)`. The runtime
/// `isAvailable` and `notConfiguredReason` surfaces a clear UX state instead
/// of silently doing nothing.
///
/// Reminder: only the anon (publishable) key is read here. Never embed the
/// `service_role` key in the client — it bypasses RLS.
enum SupabaseClientProvider {
    /// Reasons the publish flow can't reach Supabase right now. Drives the
    /// "configure Supabase to publish" UI.
    ///
    /// Marked `nonisolated` because it's read from nonisolated contexts
    /// (default-parameter expressions, `Equatable` synthesis) and the
    /// project defaults to MainActor isolation.
    nonisolated enum Unavailability: Equatable, Sendable {
        case packageNotAdded
        case missingCredentials
    }

    #if canImport(Supabase)
    /// Singleton client. Nil if credentials aren't configured.
    static let shared: SupabaseClient? = {
        guard let url = SupabaseConfig.url, let key = SupabaseConfig.anonKey else {
            return nil
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    static var isAvailable: Bool { shared != nil }

    static var unavailability: Unavailability? {
        shared == nil ? .missingCredentials : nil
    }
    #else
    static var isAvailable: Bool { false }
    static var unavailability: Unavailability? { .packageNotAdded }
    #endif
}
