import Foundation

/// Per-type payload for a node. All fields optional so old drafts decode
/// cleanly when a new field is added (no migration needed).
///
/// Currently meaningful fields per type:
/// - `.text`  → `text`
/// - `.image` → `localImagePath` (relative path under `LocalCanvasAssetStore`)
/// - `.container` → none
struct NodeContent: Codable, Hashable {
    var text: String?

    /// Relative path resolvable via `LocalCanvasAssetStore.resolveURL`.
    /// Stored relative (not absolute) so the JSON stays portable across
    /// app reinstalls / backup restores.
    var localImagePath: String?

    init(text: String? = nil, localImagePath: String? = nil) {
        self.text = text
        self.localImagePath = localImagePath
    }
}
