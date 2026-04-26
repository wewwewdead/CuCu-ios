import Foundation
import SwiftData

/// Local-only reusable canvas template.
///
/// `templateJSON` is the same v2 `ProfileDocument` envelope stored in
/// `ProfileDraft.designJSON`. Templates do not introduce a second editor
/// model; applying one just decodes that document, copies any local assets
/// into the target draft folder, then stores the resulting document on the
/// selected draft.
@Model
final class ProfileTemplate {
    var id: UUID
    var name: String
    var templateJSON: String
    var createdAt: Date
    var updatedAt: Date
    var previewSummary: String?

    init(id: UUID = UUID(),
         name: String,
         templateJSON: String,
         createdAt: Date = .now,
         updatedAt: Date = .now,
         previewSummary: String? = nil) {
        self.id = id
        self.name = name
        self.templateJSON = templateJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.previewSummary = previewSummary
    }
}
