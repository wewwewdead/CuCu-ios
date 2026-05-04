import Foundation
import SwiftData

@MainActor
private enum DraftDocumentSaveDebouncer {
    static var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func cancel(for draft: ProfileDraft) {
        let key = ObjectIdentifier(draft)
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    static func schedule(draft: ProfileDraft,
                         document: ProfileDocument,
                         context: ModelContext,
                         delayNanoseconds: UInt64) {
        let key = ObjectIdentifier(draft)
        tasks[key]?.cancel()
        tasks[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard let json = try? CanvasDocumentCodec.encode(document),
                  draft.designJSON != json else {
                tasks[key] = nil
                return
            }
            draft.designJSON = json
            draft.updatedAt = .now
            try? context.save()
            tasks[key] = nil
        }
    }
}

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
        DraftDocumentSaveDebouncer.cancel(for: draft)
        guard let json = try? CanvasDocumentCodec.encode(document) else { return }
        guard draft.designJSON != json else { return }
        draft.designJSON = json
        draft.updatedAt = .now
        try? context.save()
    }

    /// Debounced variant for inspector sliders and other bursty commit
    /// sources. Live canvas state updates immediately; only the SwiftData
    /// write is delayed and coalesced. Any immediate `updateDocument` call
    /// cancels the pending save to avoid an older snapshot landing later.
    func updateDocumentDebounced(_ draft: ProfileDraft,
                                 document: ProfileDocument,
                                 delayNanoseconds: UInt64 = 250_000_000) {
        DraftDocumentSaveDebouncer.schedule(
            draft: draft,
            document: document,
            context: context,
            delayNanoseconds: delayNanoseconds
        )
    }

    func updateTitle(_ draft: ProfileDraft, title: String) {
        guard draft.title != title else { return }
        draft.title = title
        draft.updatedAt = .now
        try? context.save()
    }

    func deleteDraft(_ draft: ProfileDraft) {
        DraftDocumentSaveDebouncer.cancel(for: draft)
        context.delete(draft)
        try? context.save()
    }
}
