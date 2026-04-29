import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Decodes arbitrary image bytes (JPEG / HEIC / PNG / etc.), resizes to fit
/// within `maxDimension` on the longer side preserving aspect ratio, drops
/// any unused alpha channel, and re-encodes as JPEG.
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
/// - We then redraw the resized CGImage into a fresh **opaque** RGBX context
///   before handing it to the JPEG encoder. ImageIO will otherwise log
///   "saving an opaque image with AlphaPremulLast — ignoring alpha"
///   whenever the source bitmap was tagged as having an alpha channel
///   (every photo from PHPicker is in RGBA form even though the alpha is
///   100% opaque). Stripping the alpha here avoids the warning, halves
///   the per-pixel decode memory cost, and shaves a small amount off the
///   final JPEG size.
/// - All failure paths return nil: bad data, no decoder, redraw failure,
///   or encode failure.
enum ImageNormalizer {
    /// Default cap for image-block content. 1400 px on the longer side
    /// covers a 3× iPhone Pro Max lightbox (1290 device px) with a small
    /// buffer for cropping while shaving ~25% off the file size we used
    /// to ship at 1600. Single-purpose image nodes that want more pixels
    /// can pass an explicit larger `maxDimension` to `saveImage`.
    /// Marked `nonisolated` so it can be used in default-parameter
    /// expressions from any isolation context (the project defaults to
    /// MainActor).
    nonisolated static let blockImageMaxDimension: CGFloat = 1400

    /// Background images may be displayed full-bleed at large sizes, so they
    /// keep more pixels.
    nonisolated static let backgroundImageMaxDimension: CGFloat = 2400

    /// Gallery tiles are usually viewed inside a small grid cell and
    /// occasionally tapped through to a lightbox at full screen width.
    /// 1200 covers both with margin and is meaningfully tighter than the
    /// generic block cap.
    nonisolated static let galleryImageMaxDimension: CGFloat = 1200

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

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let opaque = opaqueCopy(of: cgImage) else {
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
        CGImageDestinationAddImage(destination, opaque, destinationOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return outData as Data
    }

    /// Redraw `cgImage` into a 32-bit RGBX (no alpha) context using the
    /// device sRGB color space. The resulting image carries
    /// `CGImageAlphaInfo.noneSkipLast` so it round-trips through
    /// `CGImageDestinationAddImage` to JPEG without ImageIO logging the
    /// "ignoring alpha" warning. If the source was already opaque this
    /// is a near-free pass-through; if the source had a real alpha
    /// channel we composite over white (the only sensible default for
    /// JPEG which can't represent transparency).
    private static func opaqueCopy(of cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        // White fill so any genuine transparency in the source flattens
        // to a clean background instead of leaking through as black
        // (the default uninitialized memory for the context).
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
