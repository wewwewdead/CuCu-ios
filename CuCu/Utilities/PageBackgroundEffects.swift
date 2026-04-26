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
            // `CIFilter.vignette()` gives only `intensity` and
            // `radius` — no falloff curve, so the dark-to-clear
            // transition looks like a flat darkened ring at the
            // edges instead of a true radial gradient.
            // `CIFilter.vignetteEffect()` adds a `falloff` parameter
            // that explicitly controls how gradually the corners
            // fade in, which is the smooth-gradient feel the user
            // is asking for.
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = ciImage

            // Anchor the effect at the image's geometric center.
            // Without this, CoreImage uses (150, 150) by default —
            // off-center for any image larger than 300×300, which
            // produces a lopsided vignette.
            filter.center = CGPoint(x: originalExtent.midX,
                                    y: originalExtent.midY)

            // Inner radius = "clear circle in the middle." Sized to
            // the smaller of width/height so portraits and
            // landscapes both keep a generous clean center. 30%
            // leaves a comfortably large unaffected area; the
            // gradient lives in the remaining 70%.
            let minSide = min(originalExtent.width, originalExtent.height)
            filter.radius = Float(minSide * 0.3)

            // Quadratic ramp on the slider value: gives the user
            // fine control at the low end and a clearly visible
            // (but not crushing) effect at 100%. Clamped so legacy
            // drafts that persisted values up to 1.5 (the old
            // slider max) tame down to the new curve.
            let clamped = max(0, min(1, vignette))
            filter.intensity = Float(clamped * clamped)

            // Smaller `falloff` ⇒ more gradual transition between
            // the clear center and the dark corners. The default
            // 0.5 produces a fairly hard band; 0.15 yields a long,
            // smooth gradient that reads as a real photo vignette
            // rather than a darkened frame around the edges.
            filter.falloff = 0.15

            if let output = filter.outputImage {
                ciImage = output.cropped(to: originalExtent)
            }
        }

        guard let outputCG = ciContext.createCGImage(ciImage, from: originalExtent) else {
            return image
        }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: image.imageOrientation)
    }
}
