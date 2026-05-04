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

    /// Linear-gradient fill drawn between the solid `backgroundColor`
    /// and the optional `backgroundImageView`. Pinned to the
    /// container's bounds via Auto Layout; the layer auto-resizes via
    /// the layer's `frame` from `layoutSubviews()`. When the user
    /// disables the gradient or the configuration is incomplete,
    /// `apply(node:)` hides the view and lets the solid fill +
    /// background image show through normally.
    private let gradientView = LinearGradientView()

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
        addSubview(gradientView)
        addSubview(backgroundImageView)
        NSLayoutConstraint.activate([
            gradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gradientView.topAnchor.constraint(equalTo: topAnchor),
            gradientView.bottomAnchor.constraint(equalTo: bottomAnchor),

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
    /// children). The gradient view sits behind the background image
    /// (and therefore behind every child) so it acts as a fill — the
    /// solid `backgroundColor` is hidden while the gradient is on.
    func bringEffectOverlaysToFront() {
        sendSubviewToBack(blurOverlay)
        sendSubviewToBack(gradientView)
        bringSubviewToFront(vignetteOverlay)
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        // Linear-gradient fill. When enabled and both colors are
        // present, paint the gradient layer and clear the solid
        // `backgroundColor` set by `super.apply(...)` so the gradient
        // is the visible fill. Disabled / incomplete configurations
        // hide the layer and let the solid color show through.
        let gradientOn = node.style.gradientEnabled == true
            && node.style.gradientStartColorHex != nil
            && node.style.gradientEndColorHex != nil
        if gradientOn,
           let startHex = node.style.gradientStartColorHex,
           let endHex = node.style.gradientEndColorHex {
            gradientView.isHidden = false
            gradientView.configure(
                startColor: uiColor(hex: startHex),
                endColor: uiColor(hex: endHex),
                direction: node.style.gradientDirection ?? .topToBottom,
                spread: node.style.gradientSpread ?? 1.0,
                smoothness: node.style.gradientSmoothness ?? 0.0
            )
            backgroundColor = .clear
        } else {
            gradientView.isHidden = true
        }

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
        // own background fill (color + image + gradient) so the
        // blurred backdrop sampled from BEHIND the container is
        // actually visible. All three restore on the next apply pass
        // when the user dials blur back to 0 because `super.apply(...)`
        // resets `backgroundColor`, the cached signature drives a
        // re-load of the image, and the gradient block above re-shows
        // the gradient view.
        if containerBlur > 0.01 {
            backgroundColor = .clear
            backgroundImageView.isHidden = true
            gradientView.isHidden = true
        }

        // Final z-order, back → front: blur, gradient, background
        // image, children, vignette. `sendSubviewToBack` always
        // inserts at index 0, so the LAST `sendSubviewToBack` call
        // determines what sits at the very back — call them in
        // reverse-z order (frontmost-of-the-back-stack first).
        sendSubviewToBack(backgroundImageView)
        sendSubviewToBack(gradientView)
        sendSubviewToBack(blurOverlay)
        bringSubviewToFront(vignetteOverlay)
    }

    private func cachedOrLoadOriginal(path: String, mtime: Date?) -> UIImage? {
        if let cached = cachedBackgroundOriginal,
           cached.path == path,
           cached.mtime == mtime {
            return cached.image
        }
        // Local files fast-load synchronously; remote (post-publish)
        // URLs resolve via the shared cache. A remote miss returns
        // nil here, then the async fetch below applies the bytes
        // directly when they arrive. (An earlier version only reset
        // the signature + called `setNeedsLayout` — but `apply(node:)`
        // is driven by the canvas's reconciliation pass, which doesn't
        // re-run on its own when an async image is cached, leaving
        // container backgrounds blank until something else triggered
        // a re-apply.)
        guard let image = CanvasImageLoader.loadSync(path) else {
            cachedBackgroundOriginal = nil
            if CanvasImageLoader.isRemote(path) {
                CanvasImageLoader.loadAsync(path) { [weak self] fetched in
                    guard let self, let fetched else { return }
                    // Race-guard: skip stale completions where the
                    // container has since been pointed at a different
                    // image (or the user scrubbed effects so blur /
                    // vignette differ). The signature carries those
                    // values from the last `apply(node:)`, which is
                    // exactly what we want to compare against.
                    guard self.lastBackgroundSignature.path == path,
                          self.lastBackgroundSignature.mtime == mtime
                    else { return }
                    self.applyFetchedBackground(image: fetched, path: path, mtime: mtime)
                }
            }
            return nil
        }
        cachedBackgroundOriginal = (path, mtime, image)
        return image
    }

    /// Apply a freshly-fetched remote bitmap directly to the container's
    /// background image view, skipping the filter pipeline when blur
    /// and vignette are both off. Reads the current blur / vignette
    /// from `lastBackgroundSignature` (which was set by the latest
    /// `apply(node:)` pass) so we don't need a separate way to get the
    /// node's style into this closure.
    private func applyFetchedBackground(image: UIImage, path: String, mtime: Date?) {
        cachedBackgroundOriginal = (path, mtime, image)

        let blur = lastBackgroundSignature.blur
        let vignette = lastBackgroundSignature.vignette
        backgroundImageView.isHidden = false
        if blur <= 0.01 && vignette <= 0.01 {
            backgroundImageView.image = image
        } else {
            scheduleFilterRender(image: image, blur: blur, vignette: vignette)
        }
        // Restore the back-to-front layering when applying out-of-band:
        // bgImage above gradient above blurOverlay, all behind any
        // children. Same order as the tail of `apply(node:)`.
        sendSubviewToBack(backgroundImageView)
        sendSubviewToBack(gradientView)
        sendSubviewToBack(blurOverlay)
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

    /// Helper class — a `UIView` whose backing layer is a linear
    /// `CAGradientLayer`. Owns the start/end-point math for the four
    /// supported axes plus the spread + smoothness fields surfaced
    /// in the inspector.
    ///
    /// **Spread** narrows or widens the transition band: `1` = the
    /// two stops sit at the container's edges (smooth corner-to-corner
    /// blend), `0` = both stops collapse to the midpoint (razor-sharp
    /// 50/50 split).
    ///
    /// **Smoothness** controls the easing curve. `0` produces the
    /// stock two-stop linear interpolation `CAGradientLayer` paints by
    /// default; `>0` adds a fixed number of intermediate color stops
    /// inside the spread band whose colors are blended via a
    /// smoothstep curve (`3t² − 2t³`) lerped against linear by the
    /// smoothness amount, so the user can dial from "linear" → "soft
    /// S-curve" without leaving the control.
    final class LinearGradientView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func configure(startColor: UIColor,
                       endColor: UIColor,
                       direction: NodeGradientDirection,
                       spread: Double,
                       smoothness: Double) {
            let (start, end): (CGPoint, CGPoint)
            switch direction {
            case .topToBottom: start = CGPoint(x: 0.5, y: 0); end = CGPoint(x: 0.5, y: 1)
            case .bottomToTop: start = CGPoint(x: 0.5, y: 1); end = CGPoint(x: 0.5, y: 0)
            case .leftToRight: start = CGPoint(x: 0, y: 0.5); end = CGPoint(x: 1, y: 0.5)
            case .rightToLeft: start = CGPoint(x: 1, y: 0.5); end = CGPoint(x: 0, y: 0.5)
            }
            gradientLayer.startPoint = start
            gradientLayer.endPoint = end

            let clampedSpread = CGFloat(max(0, min(1, spread)))
            let clampedSmoothness = max(0, min(1, smoothness))
            let lo = 0.5 - clampedSpread / 2
            let hi = 0.5 + clampedSpread / 2

            // 0 smoothness → just the two anchor stops, which gives
            // CAGradientLayer's stock linear interpolation across the
            // band. >0 smoothness inserts intermediate color stops
            // whose color blend follows a smoothstep curve so the
            // perceived gradient eases in / out of the band.
            if clampedSmoothness <= 0.001 {
                gradientLayer.colors = [startColor.cgColor, endColor.cgColor]
                gradientLayer.locations = [NSNumber(value: Double(lo)), NSNumber(value: Double(hi))]
            } else {
                let stepCount = 9
                var colors: [CGColor] = []
                var locations: [NSNumber] = []
                for i in 0...stepCount {
                    let t = Double(i) / Double(stepCount)
                    let smoothstep = t * t * (3 - 2 * t)
                    let mix = (1 - clampedSmoothness) * t + clampedSmoothness * smoothstep
                    colors.append(blend(start: startColor, end: endColor, t: mix).cgColor)
                    let loc = Double(lo) + t * Double(hi - lo)
                    locations.append(NSNumber(value: loc))
                }
                gradientLayer.colors = colors
                gradientLayer.locations = locations
            }
        }

        private func blend(start: UIColor, end: UIColor, t: Double) -> UIColor {
            var sR: CGFloat = 0, sG: CGFloat = 0, sB: CGFloat = 0, sA: CGFloat = 0
            var eR: CGFloat = 0, eG: CGFloat = 0, eB: CGFloat = 0, eA: CGFloat = 0
            start.getRed(&sR, green: &sG, blue: &sB, alpha: &sA)
            end.getRed(&eR, green: &eG, blue: &eB, alpha: &eA)
            let f = CGFloat(t)
            return UIColor(
                red: sR + (eR - sR) * f,
                green: sG + (eG - sG) * f,
                blue: sB + (eB - sB) * f,
                alpha: sA + (eA - sA) * f
            )
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
