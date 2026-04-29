import Foundation

/// App-level representation of an authenticated user.
///
/// Kept free of Supabase types so SwiftUI views and view-models compile in
/// builds that don't yet have the `Supabase` SPM package. The auth service
/// constructs `AppUser` from `Supabase.User` in a `#if canImport(Supabase)`
/// branch.
nonisolated struct AppUser: Equatable, Sendable {
    let id: String
    let email: String
}
