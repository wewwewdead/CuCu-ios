import Foundation
import SwiftData

@MainActor
struct TemplateStore {
    enum TemplateError: Error {
        case decodeFailed
        case encodeFailed
    }

    let context: ModelContext

    @discardableResult
    func createTemplate(name: String, document: ProfileDocument) throws -> ProfileTemplate {
        let templateID = UUID()
        let templateDocument = CanvasTemplateAssetCopier.copyAssetsForTemplateSave(
            document,
            templateID: templateID
        )
        let json = try encode(templateDocument)
        let template = ProfileTemplate(
            id: templateID,
            name: normalizedName(name),
            templateJSON: json,
            previewSummary: Self.previewSummary(for: templateDocument)
        )
        context.insert(template)
        try context.save()
        return template
    }

    @discardableResult
    func apply(_ template: ProfileTemplate, to draft: ProfileDraft) throws -> ProfileDocument {
        let document = try document(from: template, forDraftID: draft.id)
        draft.designJSON = try encode(document)
        draft.updatedAt = .now
        try context.save()
        return document
    }

    // `createDraft(from:title:)` lived here for the now-removed
    // "New From Template" flow on the drafts page. The product is
    // single-document, so users apply templates onto the existing
    // draft instead of spawning a new one — `apply(_:to:)` above
    // covers that. Restore from git history if multi-document
    // returns.

    func deleteTemplate(_ template: ProfileTemplate) {
        LocalCanvasAssetStore.deleteTemplateAssets(templateID: template.id)
        context.delete(template)
        try? context.save()
    }

    func renameTemplate(_ template: ProfileTemplate, name: String) {
        template.name = normalizedName(name)
        template.updatedAt = .now
        try? context.save()
    }

    private func document(from template: ProfileTemplate, forDraftID draftID: UUID) throws -> ProfileDocument {
        let templateDocument = try decode(template)
        return CanvasTemplateAssetCopier.copyAssetsForDraftInstantiation(
            templateDocument,
            draftID: draftID
        )
    }

    private func decode(_ template: ProfileTemplate) throws -> ProfileDocument {
        switch CanvasDocumentCodec.decode(template.templateJSON) {
        case .document(let document):
            return document
        case .legacy, .empty:
            throw TemplateError.decodeFailed
        }
    }

    private func encode(_ document: ProfileDocument) throws -> String {
        do {
            return try CanvasDocumentCodec.encode(document)
        } catch {
            throw TemplateError.encodeFailed
        }
    }

    private func normalizedName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Template" : trimmed
    }

    private static func previewSummary(for document: ProfileDocument) -> String {
        var containerCount = 0
        var textCount = 0
        var imageCount = 0
        var iconCount = 0
        var dividerCount = 0
        var linkCount = 0
        var galleryCount = 0

        for node in document.nodes.values {
            switch node.type {
            case .container: containerCount += 1
            case .text: textCount += 1
            case .image: imageCount += 1
            case .icon: iconCount += 1
            case .divider: dividerCount += 1
            case .link: linkCount += 1
            case .gallery: galleryCount += 1
            }
        }

        var parts: [String] = []
        if containerCount > 0 { parts.append("\(containerCount) container\(containerCount == 1 ? "" : "s")") }
        if textCount > 0 { parts.append("\(textCount) text") }
        if imageCount > 0 { parts.append("\(imageCount) image\(imageCount == 1 ? "" : "s")") }
        if iconCount > 0 { parts.append("\(iconCount) icon\(iconCount == 1 ? "" : "s")") }
        if dividerCount > 0 { parts.append("\(dividerCount) divider\(dividerCount == 1 ? "" : "s")") }
        if linkCount > 0 { parts.append("\(linkCount) link\(linkCount == 1 ? "" : "s")") }
        if galleryCount > 0 { parts.append("\(galleryCount) galler\(galleryCount == 1 ? "y" : "ies")") }
        return parts.isEmpty ? "Blank canvas" : parts.joined(separator: " · ")
    }
}

private enum CanvasTemplateAssetCopier {
    static func copyAssetsForTemplateSave(_ document: ProfileDocument,
                                          templateID: UUID) -> ProfileDocument {
        var copy = document
        if let path = document.pageBackgroundImagePath, !path.isEmpty {
            copy.pageBackgroundImagePath = try? LocalCanvasAssetStore.copyPageBackground(
                from: path,
                templateID: templateID
            )
        }

        for (id, node) in document.nodes {
            var next = node
            if let path = node.content.localImagePath, !path.isEmpty {
                next.content.localImagePath = try? LocalCanvasAssetStore.copyImage(
                    from: path,
                    templateID: templateID,
                    nodeID: id
                )
            }
            if let path = node.style.backgroundImagePath, !path.isEmpty {
                next.style.backgroundImagePath = try? LocalCanvasAssetStore.copyContainerBackground(
                    from: path,
                    templateID: templateID,
                    nodeID: id
                )
            }
            // Gallery payload: each tile under its own fresh asset UUID
            // inside the template's folder so per-tile replace stays
            // independent when the template later instantiates a draft.
            if let paths = node.content.imagePaths, !paths.isEmpty {
                var copied: [String] = []
                for original in paths {
                    let assetID = UUID()
                    if let dest = try? LocalCanvasAssetStore.copyImage(
                        from: original,
                        templateID: templateID,
                        nodeID: assetID
                    ) {
                        copied.append(dest)
                    } else {
                        copied.append(original)
                    }
                }
                next.content.imagePaths = copied
            }
            copy.nodes[id] = next
        }

        return copy
    }

    static func copyAssetsForDraftInstantiation(_ document: ProfileDocument,
                                                draftID: UUID) -> ProfileDocument {
        var copy = document
        copy.id = UUID()

        if let path = document.pageBackgroundImagePath, !path.isEmpty {
            copy.pageBackgroundImagePath = try? LocalCanvasAssetStore.copyPageBackground(
                from: path,
                draftID: draftID
            )
        }

        for (id, node) in document.nodes {
            var next = node
            if let path = node.content.localImagePath, !path.isEmpty {
                next.content.localImagePath = try? LocalCanvasAssetStore.copyImage(
                    from: path,
                    draftID: draftID,
                    nodeID: id
                )
            }
            if let path = node.style.backgroundImagePath, !path.isEmpty {
                next.style.backgroundImagePath = try? LocalCanvasAssetStore.copyContainerBackground(
                    from: path,
                    draftID: draftID,
                    nodeID: id
                )
            }
            if let paths = node.content.imagePaths, !paths.isEmpty {
                var copied: [String] = []
                for original in paths {
                    let assetID = UUID()
                    if let dest = try? LocalCanvasAssetStore.copyImage(
                        from: original,
                        draftID: draftID,
                        nodeID: assetID
                    ) {
                        copied.append(dest)
                    } else {
                        copied.append(original)
                    }
                }
                next.content.imagePaths = copied
            }
            copy.nodes[id] = next
        }

        return copy
    }
}
