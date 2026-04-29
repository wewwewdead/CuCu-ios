import Foundation
import SwiftData

/// Inserts (or refreshes) the seven prebuilt default templates so the
/// "Apply Template" picker always has them available. Called from
/// `RootView.task` on every launch — the first call inserts all rows;
/// subsequent calls are no-ops unless the bundled `seedVersion` bumps,
/// in which case each row's JSON is overwritten in place via
/// `TemplateStore.upsertSeededTemplate(...)`.
///
/// Why a version key: any change to `TemplateBuilder.kawaii()` (or
/// any other builder) needs to land in already-installed apps without
/// the user noticing. Bump `seedVersion` whenever you edit a template
/// definition; the next launch detects the mismatch and refreshes
/// every default row's `templateJSON`. Never decrement.
@MainActor
enum DefaultTemplateSeeder {

    /// Bumped whenever a default template's authored content changes.
    /// Stored in `UserDefaults` after the seed completes so the
    /// per-launch fast-path costs only a string compare.
    private static let seedVersion = "3"
    private static let seedVersionKey = "CuCu.DefaultTemplates.seedVersion"

    static func seedIfNeeded(context: ModelContext) {
        let store = TemplateStore(context: context)
        let lastVersion = UserDefaults.standard.string(forKey: seedVersionKey)
        let forceRefresh = lastVersion != seedVersion

        for spec in DefaultTemplates.all {
            do {
                _ = try store.upsertSeededTemplate(
                    id: spec.id,
                    name: spec.name,
                    document: spec.build(),
                    forceRefresh: forceRefresh
                )
            } catch {
                // Best-effort: a single template's encode failure
                // shouldn't block the rest. The picker will simply
                // show whichever templates did seed successfully.
                #if DEBUG
                print("DefaultTemplateSeeder: failed to upsert \(spec.name): \(error)")
                #endif
            }
        }

        if forceRefresh {
            UserDefaults.standard.set(seedVersion, forKey: seedVersionKey)
        }
    }
}
