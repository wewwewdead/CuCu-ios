import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Applies CoreImage filters to a `UIImage` for the page background.
///
/// Currently supports Gaussian blur and vignette. Both are optional —
/// applying with all zeros returns the original image unchanged. Filters
/// are stacked in fixed order (blur → vignette) so increasing blur never
/// re-introduces sharp vignette edges.
///
/// A single shared `CIContext` is reused since context creation is heavy
/// and the canvas re-applies effects on every document change while a
/// slider is being dragged.
enum PageBackgroundEffects {
    private static let ciContext: CIContext = {
        // Default options use the GPU when available — fast enough on
        // current iOS hardware for ~2400 px source images at slider
        // tick rate.
        return CIContext(options: nil)
    }()

    /// Returns a new `UIImage` with the requested effects baked in. If
    /// both `blur` and `vignette` round to zero, returns the original
    /// (no allocation, no GPU work). Falls back to the original on any
    /// CoreImage failure so the canvas never goes blank.
    static func apply(to image: UIImage, blur: Double, vignette: Double) -> UIImage {
        let blurEnabled = blur > 0.01
        let vignetteEnabled = vignette > 0.01
        guard blurEnabled || vignetteEnabled else { return image }

        guard let cgImage = image.cgImage else { return image }
        var ciImage = CIImage(cgImage: cgImage)
        let originalExtent = ciImage.extent

        if blurEnabled {
            // `clampedToExtent` extends the image with edge pixels so the
            // blur doesn't darken the borders; we crop back to the
            // original rect afterward.
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = ciImage.clampedToExtent()
            filter.radius = Float(blur)
            if let output = filter.outputImage {
                ciImage = output.cropped(to: originalExtent)
            }
        }

        if vignetteEnabled {
            let filter = CIFilter.vignette()
            filter.inputImage = ciImage
            filter.intensity = Float(vignette)
            // Radius controls how broad the dark corners spread. Keeping
            // it constant (broad) produces the most photo-like falloff.
            filter.radius = 2.0
            if let output = filter.outputImage {
                ciImage = output
            }
        }

        guard let outputCG = ciContext.createCGImage(ciImage, from: originalExtent) else {
            return image
        }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: image.imageOrientation)
    }
}
