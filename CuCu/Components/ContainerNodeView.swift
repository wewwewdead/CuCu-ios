import UIKit

/// Renders a container node. Children are added by `CanvasEditorView` as
/// subviews of this view, which means UIKit's normal `frame`-in-superview
/// semantics carry the model's "frame is in parent coordinates" rule for
/// free — no manual coordinate translation required when laying out
/// nested nodes.
///
/// Optionally renders a background image (`NodeStyle.backgroundImagePath`)
/// pinned to the container's bounds, behind every child node and on top
/// of the background color. The image can have effects applied
/// (`backgroundBlur`, `backgroundVignette`) which are baked into the
/// displayed bitmap on every change. To keep slider drags smooth we use
/// the same three optimizations as `CanvasEditorView`'s page-bg path:
///
///   1. Cache the loaded `UIImage` by path (no re-decoding on every tick).
///   2. Skip work entirely when the (path, blur, vignette) signature
///      hasn't changed since the last apply.
///   3. Run the CoreImage filter pass on a background queue with
///      coalesced in-flight requests. Latest-wins, so the user's final
///      slider position always lands in the visible result.
final class ContainerNodeView: NodeRenderView {
    private let backgroundImageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        // Don't intercept touches — children and ancestor gesture
        // recognizers must still receive taps and pans through here.
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// **Backdrop-filter blur**: a `UIVisualEffectView` placed at the
    /// *back* of the container's subview stack. It samples content
    /// rendered BEHIND the container (page background, sibling nodes)
    /// and shows a blurred version. The container's own children
    /// render sharp on top — same semantic as CSS `backdrop-filter:
    /// blur()`. While blur > 0, `apply(...)` clears the container's
    /// own background color and hides the background image so the
    /// blurred backdrop isn't covered up.
    /// Real-time, GPU-backed; alpha is the user-controlled intensity.
    /// `isUserInteractionEnabled = false` so taps still fall through
    /// to children rendered above it.
    private let blurOverlay: UIVisualEffectView = {
        // `.systemUltraThinMaterial` is the lightest backdrop material
        // iOS ships. Combined with the quadratic alpha ramp in
        // `apply(...)`, it gives the slider a gentle, progressive feel
        // — a small slide produces a *barely visible* blur instead of
        // the abrupt heavy frosting `.regular` produced.
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()

    /// Radial darkening at the corners of the container. A `UIView`
    /// whose backing layer is a radial `CAGradientLayer` so we just
    /// adjust the colors (not snapshot anything).
    private let vignetteOverlay = RadialGradientView()

    /// Cache the original bitmap by path **and** file mtime. Filenames
    /// are deterministic per node, so a *replace* keeps the same path —
    /// without `mtime` in the key, the canvas would keep rendering the
    /// previous bytes after the user picked a new image.
    private var cachedBackgroundOriginal: (path: String, mtime: Date?, image: UIImage)?
    private var lastBackgroundSignature: (path: String?, mtime: Date?, blur: Double, vignette: Double) = (nil, nil, 0, 0)
    private var isRenderingBackground = false
    private var pendingBackgroundEffects: (image: UIImage, blur: Double, vignette: Double)?

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        addSubview(backgroundImageView)
        NSLayoutConstraint.activate([
            backgroundImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundImageView.topAnchor.constraint(equalTo: topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Blur overlay sits on top of all children; vignette on top of
        // blur so the dark corners apply over everything. Both pinned
        // to the container's bounds.
        addSubview(blurOverlay)
        addSubview(vignetteOverlay)
        NSLayoutConstraint.activate([
            blurOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurOverlay.topAnchor.constraint(equalTo: topAnchor),
            blurOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            vignetteOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            vignetteOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            vignetteOverlay.topAnchor.constraint(equalTo: topAnchor),
            vignetteOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Restore the container's effect-overlay layering after a
    /// reconciliation pass added children: vignette to the very front
    /// (so it darkens everything), blur to the very back (so it acts
    /// as a backdrop filter beneath the container's own content and
    /// children).
    func bringEffectOverlaysToFront() {
        sendSubviewToBack(blurOverlay)
        bringSubviewToFront(vignetteOverlay)
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        let path = node.style.backgroundImagePath
        let blur = node.style.backgroundBlur ?? 0
        let vignette = node.style.backgroundVignette ?? 0
        let mtime = LocalCanvasAssetStore.modificationDate(path)

        let signatureChanged =
            lastBackgroundSignature.path != path ||
            lastBackgroundSignature.mtime != mtime ||
            lastBackgroundSignature.blur != blur ||
            lastBackgroundSignature.vignette != vignette

        if signatureChanged {
            if let path, !path.isEmpty,
               let original = cachedOrLoadOriginal(path: path, mtime: mtime) {
                backgroundImageView.isHidden = false
                if blur <= 0.01 && vignette <= 0.01 {
                    backgroundImageView.image = original
                } else {
                    scheduleFilterRender(image: original, blur: blur, vignette: vignette)
                }
            } else {
                cachedBackgroundOriginal = nil
                backgroundImageView.image = nil
                backgroundImageView.isHidden = true
            }
            lastBackgroundSignature = (path, mtime, blur, vignette)
        }
        // Always at the back of the subview stack so child node views
        // render on top, no matter what order they were added in.
        sendSubviewToBack(backgroundImageView)

        // Whole-container effects.
        let containerBlur = max(0, min(1, node.style.containerBlur ?? 0))
        let containerVignette = max(0, min(1, node.style.containerVignette ?? 0))
        // Quadratic ramp: slider 0.1 → alpha 0.01, slider 0.5 → alpha
        // 0.25, slider 1.0 → alpha 1.0. Gives the user fine control at
        // the low end (where the difference between "no blur" and "a
        // hint of blur" matters most) and full strength at max.
        blurOverlay.alpha = CGFloat(containerBlur * containerBlur)
        vignetteOverlay.setIntensity(containerVignette)

        // Backdrop-filter mode: while blur > 0, hide the container's
        // own background fill (color + image) so the blurred backdrop
        // sampled from BEHIND the container is actually visible. Both
        // restore on the next apply pass when the user dials blur back
        // to 0 because `super.apply(...)` resets `backgroundColor` and
        // the cached signature drives a re-load of the image.
        if containerBlur > 0.01 {
            backgroundColor = .clear
            backgroundImageView.isHidden = true
        }

        // Vignette stays on top of everything; blur stays at the very
        // back (behind even the bg image) so it functions as a
        // backdrop filter, not an over-content frosting.
        sendSubviewToBack(blurOverlay)
        bringSubviewToFront(vignetteOverlay)
    }

    private func cachedOrLoadOriginal(path: String, mtime: Date?) -> UIImage? {
        if let cached = cachedBackgroundOriginal,
           cached.path == path,
           cached.mtime == mtime {
            return cached.image
        }
        guard let image = LocalCanvasAssetStore.loadUIImage(path) else {
            cachedBackgroundOriginal = nil
            return nil
        }
        cachedBackgroundOriginal = (path, mtime, image)
        return image
    }

    /// Helper class — a `UIView` whose backing layer is a radial
    /// `CAGradientLayer`. Lets us adjust the vignette darkness via
    /// `setIntensity(_:)` without snapshotting or repainting the
    /// container, and the gradient automatically scales with the
    /// container's bounds (so rotation / resize follow for free).
    final class RadialGradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            isUserInteractionEnabled = false
            gradientLayer.type = .radial
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
            gradientLayer.locations = [0.4, 1.0]
            gradientLayer.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// `0` = no vignette, `1` = strongly darkened corners. Maps
        /// linearly to the alpha of the outer gradient stop.
        func setIntensity(_ intensity: Double) {
            let clamped = max(0, min(1, intensity))
            let outer = UIColor(white: 0, alpha: CGFloat(clamped) * 0.85).cgColor
            gradientLayer.colors = [UIColor.clear.cgColor, outer]
        }
    }

    private func scheduleFilterRender(image: UIImage, blur: Double, vignette: Double) {
        if isRenderingBackground {
            pendingBackgroundEffects = (image, blur, vignette)
            return
        }
        isRenderingBackground = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = PageBackgroundEffects.apply(to: image, blur: blur, vignette: vignette)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Only display the result if the cached source is still
                // the one we rendered against — avoids briefly flashing
                // a stale image after the user removes / replaces the
                // background mid-render.
                if let cached = self.cachedBackgroundOriginal, cached.image === image {
                    self.backgroundImageView.image = result
                }
                self.isRenderingBackground = false
                if let pending = self.pendingBackgroundEffects {
                    self.pendingBackgroundEffects = nil
                    self.scheduleFilterRender(
                        image: pending.image,
                        blur: pending.blur,
                        vignette: pending.vignette
                    )
                }
            }
        }
    }
}
