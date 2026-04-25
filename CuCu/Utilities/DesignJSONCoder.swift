import Foundation

/// Encodes/decodes ProfileDesign as JSON.
///
/// Decoding is intentionally forgiving: a corrupted draft returns the default
/// design rather than throwing, so a single bad save can never brick a draft.
enum DesignJSONCoder {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    static func encode(_ design: ProfileDesign) throws -> String {
        let data = try encoder.encode(design)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> ProfileDesign {
        guard let data = json.data(using: .utf8),
              let design = try? decoder.decode(ProfileDesign.self, from: data) else {
            return .defaultDesign()
        }
        return design
    }

    /// Used as the persisted JSON for newly created drafts.
    static var fallbackJSON: String {
        (try? encode(.defaultDesign())) ?? "{\"version\":1,\"theme\":{\"backgroundColorHex\":\"#F8F6F2\",\"defaultFontName\":\"System\",\"defaultTextColorHex\":\"#1C1C1E\"},\"blocks\":[]}"
    }
}
