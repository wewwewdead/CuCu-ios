import Foundation

/// The full, JSON-serializable description of a profile page.
///
/// This is the source of truth for the renderer. Both the iOS app and a future
/// web fallback viewer must be able to read this exact shape.
struct ProfileDesign: Codable, Hashable {
    var version: Int
    var theme: ProfileTheme
    var blocks: [ProfileBlock]

    static let currentVersion = 1

    static func defaultDesign() -> ProfileDesign {
        ProfileDesign(
            version: currentVersion,
            theme: .defaultTheme(),
            blocks: []
        )
    }
}
