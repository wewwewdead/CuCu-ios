import Foundation

/// Reads Supabase project credentials from `SupabaseSecrets.plist` in the
/// app bundle.
///
/// Do **not** check `SupabaseSecrets.plist` into source control — keep only
/// the `SupabaseSecrets.example.plist` template at the repo root and copy it
/// to `CuCu/Config/SupabaseSecrets.plist` locally with your project values.
///
/// Why anon (publishable) key only:
/// - The anon key is safe to ship in a mobile binary, *provided RLS is on
///   for every public table* (see `Supabase/schema_phase4.sql`).
/// - The `service_role` key bypasses RLS and **must never** appear in the
///   client app or in any committed file. Use it only in server-side tools.
enum SupabaseConfig {
    /// Project URL (e.g. https://abcd1234.supabase.co).
    /// Returns nil when the plist isn't present or the value is empty — the
    /// app continues to work offline; only publishing is gated on this.
    static let url: URL? = {
        guard
            let raw = readPlist()?["SUPABASE_URL"] as? String,
            !raw.trimmingCharacters(in: .whitespaces).isEmpty,
            let parsed = URL(string: raw)
        else { return nil }
        return parsed
    }()

    /// Anon / publishable key.
    static let anonKey: String? = {
        guard
            let raw = readPlist()?["SUPABASE_ANON_KEY"] as? String,
            !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return raw
    }()

    /// True only when both fields are present. Driven into UI to show a
    /// helpful "configure Supabase" hint instead of cryptic errors.
    static var isConfigured: Bool { url != nil && anonKey != nil }

    private static func readPlist() -> [String: Any]? {
        guard
            let url = Bundle.main.url(forResource: "SupabaseSecrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
        else { return nil }
        return plist
    }
}
