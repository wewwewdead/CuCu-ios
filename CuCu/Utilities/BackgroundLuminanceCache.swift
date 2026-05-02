import CoreGraphics
import Foundation
import UIKit

/// In-memory cache of average Rec. 709 luminance values for canvas
/// background images. Used by `StructuredProfileLayout` to drive the
/// hero's adaptive text contrast — sampling the image once per
/// (path, mtime) pair keeps the structured-profile normalizer's hot
/// path cheap, since a normalize call fires on every commit.
///
/// The cache is process-local and intentionally not persisted: the
/// keying includes the file's modification date, so an in-place
/// replace (which keeps the deterministic filename) busts the cache
/// entry transparently. Cache hits are O(1); misses do one CoreImage
/// downscale to a 1×1 RGBA pixel via `CGContext` and read the bytes.
enum BackgroundLuminanceCache {

    private struct Key: Hashable {
        let path: String
        let mtime: Date
    }

    private static var cache: [Key: Double] = [:]
    private static let cacheLock = NSLock()

    /// Returns the average luminance (0…1) of the image at the given
    /// relative path, or `nil` if the file can't be read or decoded.
    /// `path` is interpreted exactly as `LocalCanvasAssetStore` does.
    static func luminance(forImageAt path: String) -> Double? {
        guard !path.isEmpty else { return nil }
        let mtime = modificationDate(forRelativePath: path) ?? Date.distantPast
        let key = Key(path: path, mtime: mtime)

        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let lum = computeLuminance(forImageAt: path) else { return nil }

        cacheLock.lock()
        cache[key] = lum
        // Cap at 24 entries so a user who churns through many bg
        // images doesn't grow the cache unbounded. LRU isn't worth
        // the complexity for a per-document feature; once we're
        // over the cap, drop the oldest insertion order keys.
        if cache.count > 24 {
            let extras = cache.count - 24
            for key in cache.keys.prefix(extras) {
                cache.removeValue(forKey: key)
            }
        }
        cacheLock.unlock()
        return lum
    }

    private static func computeLuminance(forImageAt path: String) -> Double? {
        guard let image = LocalCanvasAssetStore.loadUIImage(path),
              let cgImage = image.cgImage else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Drawing the image into a 1×1 context produces a single
        // pixel that approximates the image's mean color. Coarse but
        // perfect for a "is this image bright or dark overall" check.
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        // Rec. 709 luminance — same coefficients the hex check and
        // toolbar tint already use, so a single threshold (0.5)
        // governs the "dark vs light" decision across both paths.
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func modificationDate(forRelativePath relativePath: String) -> Date? {
        // Cache-bust on in-place replace via the existing helper
        // (`LocalCanvasAssetStore.modificationDate`). A `nil` (asset
        // not on disk yet) just means we fall through to a single
        // sample per process keyed by the path alone.
        LocalCanvasAssetStore.modificationDate(relativePath)
    }
}
