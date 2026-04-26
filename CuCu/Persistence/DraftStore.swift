import Foundation
import SwiftData

/// Thin wrapper around ModelContext for ProfileDraft mutations. Centralizing
/// `updatedAt` and `save()` here keeps view code from forgetting either step.
@MainActor
struct DraftStore {
    let context: ModelContext

    /// Creates a draft seeded with a v2 canvas envelope so the new builder
    /// lands on a real `ProfileDocument` (no `.legacy`/`.empty` branch on
    /// first open).
    ///
    /// The legacy `createDraft(title:)` companion (which seeded a
    /// `ProfileDesign` envelope for the deleted v1 builder) was removed
    /// when the drafts page came out — all surviving callers go through
    /// this v2 path.
    @discardableResult
    func createCanvasDraft(title: String = "Untitled") throws -> ProfileDraft {
        let draft = ProfileDraft(title: title, designJSON: CanvasDocumentCodec.fallbackJSON)
        context.insert(draft)
        try context.save()
        return draft
    }

    func updateDesign(_ draft: ProfileDraft, design: ProfileDesign) {
        guard let json = try? DesignJSONCoder.encode(design) else { return }
        guard draft.designJSON != json else { return }
        draft.designJSON = json
        draft.updatedAt = .now
        try? context.save()
    }

    /// Persist a canvas-shape document to the draft's `designJSON`. Encoding
    /// failures are swallowed (matches the behavior of `updateDesign`) so a
    /// transient encode error never crashes the editor mid-gesture.
    func updateDocument(_ draft: ProfileDraft, document: ProfileDocument) {
        guard let json = try? CanvasDocumentCodec.encode(document) else { return }
        guard draft.designJSON != json else { return }
        draft.designJSON = json
        draft.updatedAt = .now
        try? context.save()
    }

    func updateTitle(_ draft: ProfileDraft, title: String) {
        guard draft.title != title else { return }
        draft.title = title
        draft.updatedAt = .now
        try? context.save()
    }

    func deleteDraft(_ draft: ProfileDraft) {
        context.delete(draft)
        try? context.save()
    }
}
