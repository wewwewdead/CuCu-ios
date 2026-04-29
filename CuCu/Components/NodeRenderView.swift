import UIKit

/// Base `UIView` that renders a single `CanvasNode`. Subclasses
/// (`ContainerNodeView`, `TextNodeView`, `ImageNodeView`) override
/// `apply(node:)` to draw type-specific content; common style — background,
/// corner radius, border, opacity, and outer clip shape — is handled here.
///
/// Clip-shape rule (lifted from the image-only path so containers can also
/// be circular):
/// - `.rectangle` (or nil) → `cornerRadius` follows `NodeStyle.cornerRadius`.
/// - `.circle` → `cornerRadius = min(width, height) / 2`. Square frames
///   render as a true circle; non-square frames render as an iOS-standard
///   capsule. Recomputed in `layoutSubviews()` so resize stays correct.
class NodeRenderView: UIView {
    let nodeID: UUID

    private var cachedClipShape: NodeClipShape = .rectangle
    private var cachedCornerRadius: CGFloat = 0

    /// Hold-to-edit dashed outline. Lazily attached the first time
    /// `setEditingOutline(enabled:animated:)` runs so the layer cost is
    /// zero for the (common) viewer-mode + idle-editor cases. zPosition
    /// 999 keeps it above subview-backed effects like
    /// `ContainerNodeView`'s blur and vignette overlays. The path is
    /// purely additive — we do not touch `layer.borderColor` /
    /// `layer.borderWidth`, so subclasses that draw their own borders on
    /// internal plates / image views are unaffected.
    private lazy var editingOutlineLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.clear.cgColor
        // White at 0.85α reads cleanly on the dimmed surround
        // produced by the spotlight overlay without competing with
        // the page's own ink content.
        l.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        l.lineWidth = 1
        l.lineDashPattern = [6, 4]
        l.lineCap = .round
        l.lineJoin = .round
        l.opacity = 0
        // Float above subview-backed effects (ContainerNodeView's
        // backdrop blur + vignette, GalleryNodeView's cell borders,
        // IconNodeView's plate ring, etc.) without touching the
        // view's own borderColor / borderWidth.
        l.zPosition = 999
        // Hidden until first enable so we don't pay even the
        // zero-opacity sublayer cost in viewer mode.
        l.isHidden = true
        return l
    }()
    private var editingOutlineAttached = false
    private var editingOutlineEnabled = false

    init(nodeID: UUID) {
        self.nodeID = nodeID
        super.init(frame: .zero)
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Apply a node to this view. Sets frame, style, and (in subclasses)
    /// content. Frame is interpreted in this view's superview coordinate space
    /// — `CanvasEditorView` enforces that by adding children to their
    /// parent's `ContainerNodeView`, not the canvas root.
    func apply(node: CanvasNode) {
        // IMPORTANT: temporarily reset the transform to identity
        // before mutating `frame`. UIKit's `frame` setter is
        // documented as "undefined" when `transform` is non-
        // identity, and in practice it stuffs the bounding box of
        // the rotated view into bounds.size — which would then
        // grow the un-rotated logical bounds every time apply()
        // re-runs on a tilted node. Reset → set frame → re-apply
        // rotation gives a clean round-trip.
        transform = .identity
        frame = node.frame.cgRect
        alpha = CGFloat(node.opacity)
        // Tilt: rotate around the node's center (anchorPoint
        // defaults to (0.5, 0.5) on UIView, so rotation pivots on
        // the visual middle of the un-rotated frame). Skip the
        // rotation entirely when 0 to keep the transform property
        // truly identity for downstream code that compares.
        if node.style.rotation != 0 {
            let radians = CGFloat(node.style.rotation) * .pi / 180
            transform = CGAffineTransform(rotationAngle: radians)
        }

        if let bg = node.style.backgroundColorHex {
            backgroundColor = uiColor(hex: bg)
        } else {
            backgroundColor = .clear
        }

        cachedClipShape = node.style.clipShape ?? .rectangle
        cachedCornerRadius = CGFloat(node.style.cornerRadius)
        applyClipping()
        if editingOutlineAttached {
            updateEditingOutlinePath()
        }

        layer.borderWidth = CGFloat(node.style.borderWidth)
        if let bc = node.style.borderColorHex {
            layer.borderColor = uiColor(hex: bc).cgColor
        } else {
            layer.borderColor = UIColor.clear.cgColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds may change due to resize; circle radius depends on bounds.
        applyClipping()
        if editingOutlineAttached {
            updateEditingOutlinePath()
        }
    }

    private func applyClipping() {
        switch cachedClipShape {
        case .rectangle:
            layer.cornerRadius = cachedCornerRadius
        case .circle:
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }

    // MARK: - Clip silhouette accessors

    /// The node's outer clip shape, as set by the most recent
    /// `apply(node:)` pass. Exposed so the canvas's spotlight
    /// overlay can trace the focused element's actual silhouette
    /// (rounded rect, capsule, or circle) instead of approximating
    /// it with a circle.
    var clipShape: NodeClipShape { cachedClipShape }

    /// The node's stored corner radius in this view's local coord
    /// space. Only meaningful for `.rectangle` clip — for `.circle`
    /// the rendered radius is `min(width, height) / 2` regardless
    /// of this value.
    var clipCornerRadius: CGFloat { cachedCornerRadius }

    // MARK: - Hold-to-edit outline

    /// Toggle the dashed editing outline. `animated` cross-fades
    /// opacity using asymmetric durations / easings: 0.28s ease-out
    /// for entry (matches the overall edit-mode entry tempo), 0.22s
    /// ease-in for exit (slightly faster + accelerating, so the
    /// outlines disappear before the page de-scales).
    /// Pass `animated: false` for nodes that mount mid-session
    /// while editing mode is already on — fading them in against
    /// the already-static outlines would flicker.
    func setEditingOutline(enabled: Bool, animated: Bool) {
        if enabled && !editingOutlineAttached {
            layer.addSublayer(editingOutlineLayer)
            editingOutlineAttached = true
            updateEditingOutlinePath()
        }
        guard editingOutlineEnabled != enabled else { return }
        editingOutlineEnabled = enabled

        // Reveal the layer ahead of any animation so the fade is
        // actually visible — `isHidden` short-circuits compositing
        // entirely, regardless of opacity.
        if enabled {
            editingOutlineLayer.isHidden = false
        }

        let target: Float = enabled ? 1 : 0
        if animated {
            let from = editingOutlineLayer.presentation()?.opacity
                ?? editingOutlineLayer.opacity
            let duration: CFTimeInterval = enabled ? 0.28 : 0.22
            let timing = CAMediaTimingFunction(
                name: enabled ? .easeOut : .easeIn
            )

            // Wrap the explicit opacity animation in a CATransaction
            // so the completion block can safely flip `isHidden`
            // back on after a fade-out finishes — but only if no
            // re-enable happened mid-animation. The flag check in
            // the completion guards against the
            // disable → enable race.
            CATransaction.begin()
            if !enabled {
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self else { return }
                    if !self.editingOutlineEnabled {
                        self.editingOutlineLayer.isHidden = true
                    }
                }
            }
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = from
            anim.toValue = target
            anim.duration = duration
            anim.timingFunction = timing
            editingOutlineLayer.add(anim, forKey: "editingOutlineOpacity")
            editingOutlineLayer.opacity = target
            CATransaction.commit()
        } else {
            editingOutlineLayer.removeAnimation(forKey: "editingOutlineOpacity")
            editingOutlineLayer.opacity = target
            // Sync isHidden with the model state when there's no
            // animation to wait on.
            editingOutlineLayer.isHidden = !enabled
        }
    }

    private func updateEditingOutlinePath() {
        // 0.5pt inset keeps the 1pt stroke fully inside `layer.bounds`,
        // so `masksToBounds = true` doesn't shave the outer half off.
        let inset: CGFloat = 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else {
            editingOutlineLayer.path = nil
            return
        }
        let radius: CGFloat
        switch cachedClipShape {
        case .rectangle:
            radius = max(0, cachedCornerRadius - inset)
        case .circle:
            radius = max(0, min(rect.width, rect.height) / 2)
        }
        // Disable implicit animation on path swaps so resize / layout
        // updates don't morph the outline through a CA-driven tween.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        editingOutlineLayer.frame = bounds
        editingOutlineLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
        CATransaction.commit()
    }
}

// MARK: - Color parsing

/// Mirrors the parsing rules in `Color(hex:)` (see `Utilities/ColorHex.swift`)
/// so we render canvas nodes through UIColor without bridging through SwiftUI.
func uiColor(hex: String) -> UIColor {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    var value: UInt64 = 0
    guard Scanner(string: cleaned).scanHexInt64(&value) else { return .black }
    let r, g, b, a: CGFloat
    switch cleaned.count {
    case 8:
        r = CGFloat((value >> 24) & 0xFF) / 255
        g = CGFloat((value >> 16) & 0xFF) / 255
        b = CGFloat((value >> 8) & 0xFF) / 255
        a = CGFloat(value & 0xFF) / 255
    case 6:
        r = CGFloat((value >> 16) & 0xFF) / 255
        g = CGFloat((value >> 8) & 0xFF) / 255
        b = CGFloat(value & 0xFF) / 255
        a = 1.0
    case 3:
        r = CGFloat((value >> 8) & 0xF) * 17.0 / 255
        g = CGFloat((value >> 4) & 0xF) * 17.0 / 255
        b = CGFloat(value & 0xF) * 17.0 / 255
        a = 1.0
    default:
        return .black
    }
    return UIColor(red: r, green: g, blue: b, alpha: a)
}
