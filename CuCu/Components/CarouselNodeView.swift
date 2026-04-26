import UIKit

/// Renders a `.carousel` node as a horizontal strip of child items.
///
/// The model treats carousel children as ordinary canvas nodes whose
/// frames live in the carousel's scroll-content coordinate space. The
/// canvas reconciler mounts those child render views into `itemHostView`;
/// this view owns only the horizontal `UIScrollView`, content sizing, and
/// gesture arbitration between scrolling the strip and dragging selected
/// items.
final class CarouselNodeView: NodeRenderView {

    private let scrollView: UIScrollView = {
        let s = UIScrollView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.isPagingEnabled = false
        s.showsHorizontalScrollIndicator = true
        s.showsVerticalScrollIndicator = false
        s.alwaysBounceVertical = false
        s.alwaysBounceHorizontal = true
        s.contentInsetAdjustmentBehavior = .never
        s.backgroundColor = .clear
        s.delaysContentTouches = false
        return s
    }()

    /// Render host for carousel child nodes. Frame-based layout is used
    /// here because child positions come from the document model.
    private let contentView: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.clipsToBounds = false
        return v
    }()

    /// Backdrop-filter blur applied to the carousel frame, matching the
    /// container blur behavior.
    private let blurOverlay: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()

    /// UIView into which `CanvasEditorView` should mount carousel child
    /// render views.
    var itemHostView: UIView { contentView }

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)

        addSubview(blurOverlay)
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            blurOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurOverlay.topAnchor.constraint(equalTo: topAnchor),
            blurOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Make the carousel's internal scroll pan defer to `outerPan`.
    /// When the carousel is not selected, the outer pan refuses quickly
    /// and horizontal scrolling proceeds. When it is selected, the
    /// delegate can choose between scrolling and moving the whole node.
    func requireScrollPanToFail(_ outerPan: UIPanGestureRecognizer) {
        scrollView.panGestureRecognizer.require(toFail: outerPan)
    }

    /// Disable horizontal scrolling while a carousel child is selected
    /// so that child's drag-to-move gesture owns the touch space.
    func setScrollingSuppressed(_ suppressed: Bool) {
        let shouldEnableScroll = !suppressed
        if scrollView.isScrollEnabled != shouldEnableScroll {
            scrollView.isScrollEnabled = shouldEnableScroll
        }
    }

    /// When the carousel itself is selected, let mostly-horizontal pans
    /// scroll the strip instead of moving the whole carousel. Vertical /
    /// diagonal drags still move the carousel, and edge swipes that cannot
    /// reveal more content remain available for moving the carousel.
    func shouldPreferScrolling(forPanVelocity velocity: CGPoint) -> Bool {
        guard scrollView.isScrollEnabled,
              scrollView.contentSize.width > scrollView.bounds.width + 1 else { return false }

        let absX = abs(velocity.x)
        let absY = abs(velocity.y)
        guard absX > absY else { return false }

        let maxOffsetX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        if velocity.x < 0, scrollView.contentOffset.x >= maxOffsetX - 0.5 {
            return false
        }
        if velocity.x > 0, scrollView.contentOffset.x <= 0.5 {
            return false
        }
        return true
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        let blur = max(0, min(1, node.style.containerBlur ?? 0))
        blurOverlay.alpha = CGFloat(blur * blur)
        if blur > 0.01 {
            backgroundColor = .clear
        }
        sendSubviewToBack(blurOverlay)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateContentSizeToFitItems()
    }

    /// Recompute scroll content size from current child frames. Called
    /// after reconciliation and while dragging/resizing carousel items.
    func updateContentSizeToFitItems() {
        let viewport = bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }

        let trailingPadding: CGFloat = 16
        let maxChildX = contentView.subviews.reduce(CGFloat.zero) { partial, view in
            guard !view.isHidden else { return partial }
            return max(partial, view.frame.maxX)
        }
        let contentWidth = max(viewport.width, maxChildX + trailingPadding)
        contentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: viewport.height)
        scrollView.contentSize = CGSize(width: contentWidth, height: viewport.height)

        let maxOffsetX = max(0, contentWidth - scrollView.bounds.width)
        if scrollView.contentOffset.x > maxOffsetX {
            scrollView.contentOffset.x = maxOffsetX
        }
    }
}
