import Foundation

/// Encodes/decodes `ProfileDocument` to/from the JSON string stored in
/// `ProfileDraft.designJSON`.
///
/// JSON shape (envelope is required so we can evolve the schema in place
/// without colliding with the legacy `ProfileDesign` payload that used the
/// same SwiftData field):
///
///     { "schemaVersion": 2, "document": { ...ProfileDocument... } }
///
/// Old drafts written by the legacy `DesignJSONCoder` have no `schemaVersion`
/// and a different top-level shape. The decoder treats those as `.legacy` so
/// the caller can decide whether to display a notice and/or start fresh —
/// **never silently overwrite** prior work.
enum CanvasDocumentCodec {
    static let schemaVersion = 2

    enum DecodeResult {
        case document(ProfileDocument)
        /// JSON parsed but did not match v2 envelope — likely a legacy v1 draft.
        case legacy
        /// Empty / unparseable JSON.
        case empty
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let document: ProfileDocument
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    static func encode(_ document: ProfileDocument) throws -> String {
        let envelope = Envelope(schemaVersion: schemaVersion, document: document)
        let data = try encoder.encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> DecodeResult {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return .empty
        }
        if let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.schemaVersion == schemaVersion {
            return .document(envelope.document)
        }
        // JSON exists but isn't a v2 envelope — treat as legacy and let the
        // caller decide. We don't try to project legacy ProfileDesign blocks
        // into canvas nodes here; that's a one-time migration concern outside
        // the Phase 1 scope.
        return .legacy
    }

    /// JSON for a fresh blank canvas. Used as the seed for new drafts so a
    /// blank `ProfileCanvasBuilderView` always lands on the document path
    /// (not `.legacy` or `.empty`).
    static var fallbackJSON: String {
        (try? encode(.blank)) ?? "{\"schemaVersion\":2,\"document\":{\"id\":\"00000000-0000-0000-0000-000000000000\",\"nodes\":{},\"pageBackgroundHex\":\"#F8F6F2\",\"rootChildrenIDs\":[]}}"
    }
}
