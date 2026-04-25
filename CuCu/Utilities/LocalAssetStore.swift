import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// File-based asset store for image data referenced from `designJSON`.
///
/// Layout under Application Support:
///
///     profile-assets/
///       draft_<UUID>/
///         block_<UUID>.jpg
///         background.jpg
///
/// The JSON schema only stores the relative path (e.g. `draft_X/block_Y.jpg`),
/// never the binary. Filenames are deterministic per (draft, block) so
/// replacing an image overwrites the existing file — no leaked orphans.
///
/// As of Phase 3.5, public save methods normalize raw picker bytes into JPEG
/// via `ImageNormalizer` *before* hitting disk, so the `.jpg` extension on
/// disk is truthful and safe for a future web/Supabase consumer. The legacy
/// raw-bytes Phase 3 helpers are deliberately gone — there is no path that
/// writes a non-JPEG into a `.jpg` file anymore.
///
/// All read/delete operations remain best-effort: a missing file or a failed
/// delete never crashes; views fall back to placeholders. Phase 3 files
/// written before normalization existed still load (UIImage / NSImage sniff
/// content, not extensions).
@MainActor
enum LocalAssetStore {
    static let rootDirectoryName = "profile-assets"

    /// Errors thrown by the normalizing save APIs.
    enum SaveError: Error {
        /// `ImageNormalizer` couldn't decode the input or encode JPEG output.
        case normalizationFailed
        /// The JPEG bytes were produced but couldn't be written to disk.
        case writeFailed(underlying: Error)
    }

    /// Application Support is the right home for app-private files that
    /// persist across launches but aren't user documents. Falls back to
    /// Documents only if Application Support is unavailable for some reason.
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

    // MARK: - Save (normalize → write)

    /// Normalize raw picker data to JPEG (≤1600 px on the longer side) and
    /// write it as `block_<blockID>.jpg`. Filenames are deterministic so
    /// replacing an image always overwrites cleanly.
    @discardableResult
    static func saveBlockImageData(
        _ rawData: Data,
        draftID: UUID,
        blockID: UUID,
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
        return try writeJPEG(jpeg, draftID: draftID, filename: "block_\(blockID.uuidString).jpg")
    }

    /// Normalize raw picker data to JPEG (≤2400 px on the longer side) and
    /// write it as `background.jpg` for the given draft.
    @discardableResult
    static func saveBackgroundImageData(
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
        return try writeJPEG(jpeg, draftID: draftID, filename: "background.jpg")
    }

    private static func writeJPEG(_ data: Data, draftID: UUID, filename: String) throws -> String {
        let folder = draftFolder(draftID: draftID, create: true)
        let url = folder.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SaveError.writeFailed(underlying: error)
        }
        let relative = "draft_\(draftID.uuidString)/\(filename)"
        #if DEBUG
        print("[LocalAssetStore] Saved \(relative) — \(data.count) bytes")
        #endif
        return relative
    }

    // MARK: - Resolve

    /// Resolve a stored relative path to an absolute URL, or nil if the file
    /// is missing. Empty paths are treated as "no image" and return nil.
    static func resolveURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let url = rootURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Delete

    /// Delete a single asset. Best-effort — silent failure if the file is gone.
    static func delete(relativePath: String) {
        guard !relativePath.isEmpty else { return }
        let url = rootURL.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete an entire draft's asset folder. Used when a draft is removed
    /// from the list — keeps Application Support tidy.
    static func deleteDraftAssets(draftID: UUID) {
        let folder = draftFolder(draftID: draftID, create: false)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Image loading helpers

    /// Load a SwiftUI Image from a stored relative path. Returns nil for
    /// empty paths, missing files, or unreadable image data.
    ///
    /// Phase 3 files written before normalization (potentially HEIC bytes
    /// inside a `.jpg` filename) still load here because UIImage/NSImage
    /// sniff content, not the filename extension.
    static func loadImage(relativePath: String) -> Image? {
        guard let url = resolveURL(relativePath: relativePath) else { return nil }
        return loadImage(at: url)
    }

    static func loadImage(at url: URL) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }

    /// Load a SwiftUI Image from in-memory data — used by editors to preview
    /// a freshly picked image before it's been written to disk.
    static func loadImage(data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}
