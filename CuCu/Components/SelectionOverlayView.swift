import UIKit

/// Bounding-box + corner handles drawn on top of the selected node.
///
/// The overlay is always a subview of `CanvasEditorView` (the canvas root)
/// rather than the selected node's superview. That way, even if the selected
/// node is buried inside several containers, the overlay still draws above
/// every other view. `CanvasEditorView` updates `frame` via
/// `convert(node.bounds, from: node)` so the overlay tracks nested nodes.
final class SelectionOverlayView: UIView {
    enum ResizeMode {
        case freeform
        case verticalOnly
        case locked
    }

    let topLeft = ResizeHandleView(corner: .topLeft)
    let topRight = ResizeHandleView(corner: .topRight)
    let bottomLeft = ResizeHandleView(corner: .bottomLeft)
    let bottomRight = ResizeHandleView(corner: .bottomRight)
    let bottomCenter = ResizeHandleView(corner: .bottomCenter)

    var resizeMode: ResizeMode = .freeform {
        didSet { applyResizeMode() }
    }

    var handles: [ResizeHandleView] {
        [topLeft, topRight, bottomLeft, bottomRight, bottomCenter]
    }

    private let strokeLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = UIColor.systemBlue.cgColor
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 1
        return l
    }()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        // The overlay itself doesn't intercept taps — only the corner handles
        // do. This keeps tapping near (but not on) a handle from stealing
        // selection clicks meant for sibling nodes underneath.
        isUserInteractionEnabled = true

        layer.addSublayer(strokeLayer)

        for handle in handles {
            addSubview(handle)
        }
        applyResizeMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.frame = bounds
        strokeLayer.path = UIBezierPath(rect: bounds).cgPath
        layoutHandles()
    }

    private func layoutHandles() {
        let half: CGFloat = 8 // half of handle size
        topLeft.center = CGPoint(x: 0, y: 0)
        topRight.center = CGPoint(x: bounds.width, y: 0)
        bottomLeft.center = CGPoint(x: 0, y: bounds.height)
        bottomRight.center = CGPoint(x: bounds.width, y: bounds.height)
        bottomCenter.center = CGPoint(x: bounds.midX, y: bounds.height)
        _ = half
    }

    private func applyResizeMode() {
        switch resizeMode {
        case .freeform:
            topLeft.isHidden = false
            topRight.isHidden = false
            bottomLeft.isHidden = false
            bottomRight.isHidden = false
            bottomCenter.isHidden = true
        case .verticalOnly:
            topLeft.isHidden = true
            topRight.isHidden = true
            bottomLeft.isHidden = true
            bottomRight.isHidden = true
            bottomCenter.isHidden = false
        case .locked:
            for handle in handles {
                handle.isHidden = true
            }
        }
    }

    /// Pass-through hit-testing: only the four handles consume taps; clicks
    /// elsewhere on the overlay fall through to the node behind it so the
    /// user can interact with the underlying view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for handle in handles where !handle.isHidden {
            let p = convert(point, to: handle)
            if handle.bounds.insetBy(dx: -8, dy: -8).contains(p) {
                return handle
            }
        }
        return nil
    }
}
