import Foundation

/// Page-level styling shared across all blocks. Stored inside ProfileDesign.
///
/// Each new field carries a property default *and* is read with
/// `decodeIfPresent` in the extension below — defaults keep the memberwise
/// initializer usable in app code, and `decodeIfPresent` lets older JSON open
/// without throwing.
struct ProfileTheme: Codable, Hashable {
    var backgroundColorHex: String
    var defaultFontName: ProfileFontName
    var defaultTextColorHex: String
    var pageHorizontalPadding: Double = 20
    var blockSpacing: Double = 16
    /// Phase 3: optional path (relative to LocalAssetStore.rootURL) to a local
    /// background image for this draft. Nil means "use backgroundColorHex".
    var backgroundImagePath: String? = nil

    static func defaultTheme() -> ProfileTheme {
        ProfileTheme(
            backgroundColorHex: "#F8F6F2",
            defaultFontName: .system,
            defaultTextColorHex: "#1C1C1E",
            pageHorizontalPadding: 20,
            blockSpacing: 16,
            backgroundImagePath: nil
        )
    }
}

extension ProfileTheme {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backgroundColorHex = try c.decode(String.self, forKey: .backgroundColorHex)
        self.defaultFontName = try c.decode(ProfileFontName.self, forKey: .defaultFontName)
        self.defaultTextColorHex = try c.decode(String.self, forKey: .defaultTextColorHex)
        self.pageHorizontalPadding = try c.decodeIfPresent(Double.self, forKey: .pageHorizontalPadding) ?? 20
        self.blockSpacing = try c.decodeIfPresent(Double.self, forKey: .blockSpacing) ?? 16
        self.backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
    }
}
