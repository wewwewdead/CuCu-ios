import Foundation
import UIKit

/// File-based asset store for image bytes referenced by canvas image nodes.
///
/// Layout under Application Support:
///
///     profile-canvas-assets/
///       draft_<draftUUID>/
///         image_<nodeUUID>.jpg
///       template_<templateUUID>/
///         image_<nodeUUID>.jpg
///
/// The scene-graph JSON only ever stores the relative path
/// (e.g. `draft_X/image_Y.jpg`). Binary bytes never enter the JSON. Filenames
/// are deterministic per (draft, node) so a user replacing a node's image
/// overwrites the same file — no orphan accumulation per node.
///
/// All inputs are normalized through `ImageNormalizer` before they hit disk:
/// HEIC/PNG/JPEG bytes are decoded, resized to ≤1600 px on the longer side,
/// and re-encoded as true JPEG. The `.jpg` extension on disk is therefore
/// truthful.
///
/// Read paths are forgiving: missing files / corrupt bytes / empty paths
/// return nil so the renderer can fall back to a placeholder rather than
/// crash.
enum LocalCanvasAssetStore {
    static let rootDirectoryName = "profile-canvas-assets"

    enum SaveError: Error {
        /// `ImageNormalizer` couldn't decode the source bytes or encode JPEG.
        case normalizationFailed
        /// The source asset for a copy operation no longer exists.
        case sourceMissing
        /// The source asset exists but couldn't be read.
        case readFailed(underlying: Error)
        /// The JPEG bytes were produced but couldn't be written to disk.
        case writeFailed(underlying: Error)
    }

    // MARK: - Paths

    /// Application Support is private to the app and persists across launches
    /// (and most OS updates) without being user-visible. Falls back to
    /// Documents if Application Support is unavailable.
    static var rootURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let root = base.appendingPathComponent(rootDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func draftFolder(draftID: UUID, create: Bool = false) -> URL {
        let folder = rootURL.appendingPathComponent("draft_\(draftID.uuidString)", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func templateFolder(templateID: UUID, create: Bool = false) -> URL {
        let folder = rootURL.appendingPathComponent("template_\(templateID.uuidString)", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    // MARK: - Save

    /// Normalize raw picker bytes and save as the *page background* image
    /// for a draft. Filename is fixed (`page_background.jpg`), so each
    /// draft has at most one — replacing overwrites cleanly with no leak.
    /// Larger max dimension than node images since backgrounds are
    /// displayed full-bleed.
    @discardableResult
    static func savePageBackground(
        _ rawData: Data,
        draftID: UUID,
        maxDimension: CGFloat = ImageNormalizer.backgroundImageMaxDimension,
        compressionQuality: CGFloat = ImageNormalizer.defaultCompressionQuality
    ) throws -> String {
        guard let jpeg = ImageNormalizer.normalizedJPEGData(
            from: rawData,
            maxDimension: maxDimension,
            compressionQuality: compressionQuality
        ) else {
            throw SaveError.normalizationFailed
        }
        let folder = draftFolder(draftID: draftID, create: true)
        let filename = "page_background.jpg"
        let url = folder.appendingPathComponent(filename)
        do {
            try jpeg.write(to: url, options: .atomic)
            LocalImageCache.shared.remove(relativePath: "draft_\(draftID.uuidString)/\(filename)")
        } catch {
            throw SaveError.writeFailed(underlying: error)
        }
        return "draft_\(draftID.uuidString)/\(filename)"
    }

    /// Normalize raw picker bytes and save as a *container* background
    /// image. Distinct filename prefix from `saveImage` so a node that
    /// is both an image (via `localImagePath`) and a container (via
    /// `style.backgroundImagePath`) wouldn't clash — though current
    /// schema disallows that, the separation keeps the asset folder
    /// readable.
    @discardableResult
    static func saveContainerBackground(
        _ rawData: Data,
        draftID: UUID,
        nodeID: UUID,
        maxDimension: CGFloat = ImageNormalizer.blockImageMaxDimension,
        compressionQuality: CGFloat = ImageNormalizer.defaultCompressionQuality
    ) throws -> String {
        guard let jpeg = ImageNormalizer.normalizedJPEGData(
            from: rawData,
            maxDimension: maxDimension,
            compressionQuality: compressionQuality
        ) else {
            throw SaveError.normalizationFailed
        }
        let folder = draftFolder(draftID: draftID, create: true)
        let filename = "container_\(nodeID.uuidString).jpg"
        let url = folder.appendingPathComponent(filename)
        do {
            try jpeg.write(to: url, options: .atomic)
            LocalImageCache.shared.remove(relativePath: "draft_\(draftID.uuidString)/\(filename)")
        } catch {
            throw SaveError.writeFailed(underlying: error)
        }
        return "draft_\(draftID.uuidString)/\(filename)"
    }

    /// Normalize raw picker bytes (HEIC / PNG / JPEG / etc.) and write to a
    /// deterministic per-node JPEG. Returns the relative path that should be
    /// stored in `NodeContent.localImagePath`.
    @discardableResult
    static func saveImage(
        _ rawData: Data,
        draftID: UUID,
        nodeID: UUID,
        maxDimension: CGFloat = ImageNormalizer.blockImageMaxDimension,
        compressionQuality: CGFloat = ImageNormalizer.defaultCompressionQuality
    ) throws -> String {
        guard let jpeg = ImageNormalizer.normalizedJPEGData(
            from: rawData,
            maxDimension: maxDimension,
            compressionQuality: compressionQuality
        ) else {
            throw SaveError.normalizationFailed
        }

        let folder = draftFolder(draftID: draftID, create: true)
        let filename = "image_\(nodeID.uuidString).jpg"
        let url = folder.appendingPathComponent(filename)
        do {
            try jpeg.write(to: url, options: .atomic)
            LocalImageCache.shared.remove(relativePath: "draft_\(draftID.uuidString)/\(filename)")
        } catch {
            throw SaveError.writeFailed(underlying: error)
        }
        return "draft_\(draftID.uuidString)/\(filename)"
    }

    /// Copy an existing image-node asset to the deterministic filename for
    /// `nodeID`. Used when duplicating image nodes so each editable node owns
    /// its own local file while still preserving the same pixels.
    @discardableResult
    static func copyImage(
        from relativePath: String,
        draftID: UUID,
        nodeID: UUID
    ) throws -> String {
        try copyExistingAsset(
            from: relativePath,
            toFolder: draftFolder(draftID: draftID, create: true),
            relativeFolderName: "draft_\(draftID.uuidString)",
            filename: "image_\(nodeID.uuidString).jpg"
        )
    }

    /// Copy an existing image-node asset into a template-owned folder.
    /// Templates store relative paths under `template_<UUID>/...`, so they
    /// keep working even if the original draft is later edited or deleted.
    @discardableResult
    static func copyImage(
        from relativePath: String,
        templateID: UUID,
        nodeID: UUID
    ) throws -> String {
        try copyExistingAsset(
            from: relativePath,
            toFolder: templateFolder(templateID: templateID, create: true),
            relativeFolderName: "template_\(templateID.uuidString)",
            filename: "image_\(nodeID.uuidString).jpg"
        )
    }

    @discardableResult
    static func copyPageBackground(
        from relativePath: String,
        draftID: UUID
    ) throws -> String {
        try copyExistingAsset(
            from: relativePath,
            toFolder: draftFolder(draftID: draftID, create: true),
            relativeFolderName: "draft_\(draftID.uuidString)",
            filename: "page_background.jpg"
        )
    }

    @discardableResult
    static func copyPageBackground(
        from relativePath: String,
        templateID: UUID
    ) throws -> String {
        try copyExistingAsset(
            from: relativePath,
            toFolder: templateFolder(templateID: templateID, create: true),
            relativeFolderName: "template_\(templateID.uuidString)",
            filename: "page_background.jpg"
        )
    }

    @discardableResult
    static func copyContainerBackground(
        from relativePath: String,
        draftID: UUID,
        nodeID: UUID
    ) throws -> String {
        try copyExistingAsset(
            from: relativePath,
            toFolder: draftFolder(draftID: draftID, create: true),
            relativeFolderName: "draft_\(draftID.uuidString)",
            filename: "container_\(nodeID.uuidString).jpg"
        )
    }

    @discardableResult
    static func copyContainerBackground(
        from relativePath: String,
        templateID: UUID,
        nodeID: UUID
    ) throws -> String {
        try copyExistingAsset(
            from: relativePath,
            toFolder: templateFolder(templateID: templateID, create: true),
            relativeFolderName: "template_\(templateID.uuidString)",
            filename: "container_\(nodeID.uuidString).jpg"
        )
    }

    private static func copyExistingAsset(
        from relativePath: String,
        toFolder folder: URL,
        relativeFolderName: String,
        filename: String
    ) throws -> String {
        guard let sourceURL = resolveURL(relativePath) else {
            throw SaveError.sourceMissing
        }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destinationURL = folder.appendingPathComponent(filename)
        let destinationPath = "\(relativeFolderName)/\(filename)"

        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return destinationPath
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw SaveError.readFailed(underlying: error)
        }

        do {
            try data.write(to: destinationURL, options: .atomic)
            LocalImageCache.shared.remove(relativePath: destinationPath)
        } catch {
            throw SaveError.writeFailed(underlying: error)
        }

        return destinationPath
    }

    // MARK: - Resolve / load

    /// Resolve a stored relative path to an absolute URL, or nil if the file
    /// is missing. Empty/nil paths return nil.
    static func resolveURL(_ relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let url = rootURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Modification date of a stored asset. Used as a cache-busting key
    /// by the canvas renderers: filenames are deterministic per node /
    /// page, so a *replace* doesn't change the path — the renderer
    /// detects the new bytes via mtime and invalidates its `UIImage`
    /// cache. Returns `nil` for missing files.
    static func modificationDate(_ relativePath: String?) -> Date? {
        guard let url = resolveURL(relativePath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Load a UIImage from a stored relative path. Returns nil for empty
    /// paths, missing files, or unreadable bytes — callers should render a
    /// placeholder instead.
    static func loadUIImage(_ relativePath: String?) -> UIImage? {
        guard let relativePath, !relativePath.isEmpty,
              let url = resolveURL(relativePath) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        return LocalImageCache.shared.image(
            for: relativePath,
            fileURL: url,
            modificationDate: mtime
        )
    }

    // MARK: - Delete

    /// Delete a single asset. Best-effort — silent if the file is gone.
    static func delete(relativePath: String?) {
        guard let relativePath, !relativePath.isEmpty else { return }
        let url = rootURL.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
        LocalImageCache.shared.remove(relativePath: relativePath)
    }

    /// Remove a draft's entire asset folder. Use when deleting a draft so
    /// Application Support stays tidy.
    static func deleteDraftAssets(draftID: UUID) {
        let folder = draftFolder(draftID: draftID, create: false)
        try? FileManager.default.removeItem(at: folder)
        LocalImageCache.shared.removeAll(under: "draft_\(draftID.uuidString)/")
    }

    static func deleteTemplateAssets(templateID: UUID) {
        let folder = templateFolder(templateID: templateID, create: false)
        try? FileManager.default.removeItem(at: folder)
        LocalImageCache.shared.removeAll(under: "template_\(templateID.uuidString)/")
    }
}
