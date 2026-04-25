import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Decodes arbitrary image bytes (JPEG / HEIC / PNG / etc.), resizes to fit
/// within `maxDimension` on the longer side preserving aspect ratio, and
/// re-encodes as JPEG.
///
/// Implementation notes:
/// - Uses ImageIO's `CGImageSourceCreateThumbnailAtIndex` with
///   `kCGImageSourceCreateThumbnailFromImageAlways` so we generate from the
///   full-resolution image data, not an embedded EXIF thumbnail.
/// - `kCGImageSourceCreateThumbnailWithTransform` bakes EXIF orientation into
///   the pixels — the saved JPEG has no orientation tag, so any future web
///   renderer doesn't need rotation logic.
/// - `kCGImageSourceThumbnailMaxPixelSize` does the resize on our behalf and
///   never upscales, so a small source is preserved at its native size.
/// - All failure paths return nil: bad data, no decoder, or encode failure.
enum ImageNormalizer {
    /// Default cap for image-block content. ~1600 px on the longer side keeps
    /// retina-display sharpness while staying small enough for fast loads.
    /// Marked `nonisolated` so it can be used in default-parameter expressions
    /// from any isolation context (the project defaults to MainActor).
    nonisolated static let blockImageMaxDimension: CGFloat = 1600

    /// Background images may be displayed full-bleed at large sizes, so they
    /// keep more pixels.
    nonisolated static let backgroundImageMaxDimension: CGFloat = 2400

    /// Slightly above the "good enough" knee of JPEG quality — visually
    /// indistinguishable from quality 1.0 in nearly all cases.
    nonisolated static let defaultCompressionQuality: CGFloat = 0.82

    static func normalizedJPEGData(
        from data: Data,
        maxDimension: CGFloat,
        compressionQuality: CGFloat = defaultCompressionQuality
    ) -> Data? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension)),
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let outData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ]
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return outData as Data
    }
}
