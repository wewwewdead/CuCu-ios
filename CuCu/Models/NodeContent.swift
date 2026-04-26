import Foundation

/// Per-type payload for a node. All fields optional so old drafts decode
/// cleanly when a new field is added (no migration needed).
///
/// Currently meaningful fields per type:
/// - `.text`     → `text`
/// - `.image`    → `localImagePath` (relative path under `LocalCanvasAssetStore`)
/// - `.container`→ none
/// - `.icon`     → `iconName` (SF Symbol identifier), optional `text` (label)
/// - `.divider`  → none (style only)
/// - `.link`     → `text` (visible title), `url` (destination)
/// - `.gallery`  → `imagePaths` (ordered list of relative paths)
struct NodeContent: Codable, Hashable {
    var text: String?

    /// Relative path resolvable via `LocalCanvasAssetStore.resolveURL`.
    /// Stored relative (not absolute) so the JSON stays portable across
    /// app reinstalls / backup restores.
    var localImagePath: String?

    /// SF Symbol identifier rendered by `IconNodeView`. The actual visual
    /// treatment (colors, weight, background plate) is driven by
    /// `NodeStyle.iconStyleFamily`. `nil` = "no icon picked yet" — the
    /// renderer falls back to a star placeholder.
    var iconName: String?

    /// Destination URL for `.link` nodes. Free-form string so users can
    /// type partial values mid-edit; the renderer never tries to open
    /// the URL in this phase, so a malformed value is harmless.
    var url: String?

    /// Ordered list of relative image paths for `.gallery` nodes. Each
    /// path resolves via `LocalCanvasAssetStore.resolveURL`. Stored
    /// outside `localImagePath` so a single gallery can host many
    /// images without conflicting with the single-image schema used
    /// by `.image` nodes.
    var imagePaths: [String]?

    init(text: String? = nil,
         localImagePath: String? = nil,
         iconName: String? = nil,
         url: String? = nil,
         imagePaths: [String]? = nil) {
        self.text = text
        self.localImagePath = localImagePath
        self.iconName = iconName
        self.url = url
        self.imagePaths = imagePaths
    }
}

extension NodeContent {
    private enum CodingKeys: String, CodingKey {
        case text
        case localImagePath
        case iconName
        case url
        case imagePaths
    }

    /// Custom decoder so old drafts (which don't include the four
    /// post-Phase-1 fields) decode cleanly. Synthesised encoders would
    /// also work since every field is optional, but spelling the
    /// `decodeIfPresent` path out makes the backward-compatibility
    /// contract explicit and matches the pattern used by
    /// `ProfileDocument` and `ProfileTheme`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.localImagePath = try c.decodeIfPresent(String.self, forKey: .localImagePath)
        self.iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths)
    }
}
