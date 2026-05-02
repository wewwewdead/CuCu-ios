import UIKit
import SwiftUI

/// UIKit-side per-node overlays for canvas edit mode: dashed outlines + small
/// labelled chips that float above each top-level node on every page. Lives
/// inside `CanvasEditorView` because the page coordinate space is the same
/// space `CanvasNode.frame` is authored in — drawing these in SwiftUI would
/// require shipping scroll offsets and per-page origins back across the
/// representable boundary every layout pass.
///
/// One coordinator manages the chip + outline pair for each top-level node.
/// The host (`CanvasEditorView`) calls `apply(...)` whenever the document or
/// edit-mode flag changes. The coordinator reconciles its subview pool against
/// the live id list — adds new pairs, removes stale ones, repositions the rest.
final class CanvasEditModeOverlay {
    /// One pair of overlays per node id.
    private struct Pair {
        let outline: DashedOutlineView
        let chip: NodeEditChipView
    }

    /// Per-page record. The inset stroke layer animates in/out alongside the
    /// dashed outlines so the page reads as a single "armed" surface. The
    /// `accent` is the cherry-or-shell tone the host picked for this page
    /// based on background luminance — stashed so per-pair updates can
    /// re-apply it without the host having to thread it through every call.
    private struct PageOverlay {
        weak var pageView: UIView?
        let insetStroke: CAShapeLayer
        var pairs: [UUID: Pair] = [:]
        var accent: UIColor = .cucuCherry
    }

    private var pages: [UUID: PageOverlay] = [:]

    /// Wired to `CanvasEditorView.onSelectionChanged` so chip taps drop the
    /// host into "node selected, inspector open" without rebuilding the
    /// gesture path.
    var onSelectChip: ((UUID) -> Void)?

    /// Removes every overlay and tears down per-page records. Called when
    /// the canvas reconciles its page surfaces and a page id disappears.
    func purge(pageID: UUID) {
        guard let page = pages.removeValue(forKey: pageID) else { return }
        page.insetStroke.removeFromSuperlayer()
        for pair in page.pairs.values {
            pair.outline.removeFromSuperview()
            pair.chip.removeFromSuperview()
        }
    }

    /// Wholesale reset — used when the editor disappears.
    func purgeAll() {
        for id in Array(pages.keys) {
            purge(pageID: id)
        }
    }

    /// Reconcile one page's overlays against the live node list.
    ///
    /// - Parameters:
    ///   - editMode: Edit mode on/off. Drives visibility (animated) but the
    ///     outlines stay in the view tree so an off→on transition can fade
    ///     in without re-creating views.
    ///   - pageID: Identifier for this page surface.
    ///   - pageView: The page UIView (root container). Outlines and chips are
    ///     installed as subviews here so their frames live in page space.
    ///   - nodeIDs: Editable node ids that should get a chip + outline. May
    ///     include nested nodes (e.g. the hero's children) — the caller
    ///     decides which slice of the document is exposed.
    ///   - lookup: Resolves a node id to its current `CanvasNode` snapshot
    ///     plus its absolute frame in `pageView`'s coordinate space. Nested
    ///     nodes whose `node.frame` lives in a parent container's coords
    ///     must have their frame translated up to the page so chips and
    ///     outlines (which are direct children of `pageView`) anchor
    ///     correctly.
    func apply(editMode: Bool,
               pageID: UUID,
               pageView: UIView,
               accent: UIColor,
               nodeIDs: [UUID],
               lookup: (UUID) -> (node: CanvasNode, frame: CGRect)?) {
        var page = pages[pageID] ?? makePageOverlay(pageID: pageID, pageView: pageView)
        page.pageView = pageView
        page.accent = accent
        // Re-tint the inset stroke whenever the host re-renders so a
        // theme swap or a fresh bg image flips the page's "armed"
        // halo from cherry to shell (or vice versa) without a one-
        // off `setNeedsDisplay` call.
        page.insetStroke.strokeColor = accent.withAlphaComponent(0.28).cgColor

        // Page-level inset stroke: parented to the page itself so the corner
        // radius can match the page (UIKit clipping makes the stroke read
        // clean against rounded page corners). Frame tracks pageView bounds
        // — we don't bother with autolayout since `apply(...)` is called on
        // every `CanvasEditorView.apply(document:)` pass, which is plenty
        // often to keep the frame fresh.
        if page.insetStroke.superlayer !== pageView.layer {
            pageView.layer.addSublayer(page.insetStroke)
        }
        page.insetStroke.frame = pageView.bounds.insetBy(dx: 1, dy: 1)
        page.insetStroke.path = UIBezierPath(
            roundedRect: pageView.bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: pageView.layer.cornerRadius
        ).cgPath
        animateLayerOpacity(page.insetStroke, to: editMode ? 1 : 0)

        let liveSet = Set(nodeIDs)

        // Drop pairs whose nodes were removed.
        for (id, pair) in page.pairs where !liveSet.contains(id) {
            removePair(pair, pageOverlay: &page, id: id, animated: true)
        }

        // Add or update pairs for live ids. We stagger the reveal so a
        // canvas with five sections doesn't read as a wall-of-chips on
        // edit-mode entry — each chip lands ~30ms after the previous,
        // capped so very dense pages don't drag past ~250ms total.
        let perStepDelay: TimeInterval = 0.03
        let totalNodes = max(1, nodeIDs.count)
        for (index, id) in nodeIDs.enumerated() {
            guard let resolved = lookup(id) else { continue }
            let node = resolved.node
            let absoluteFrame = resolved.frame
            let pair: Pair
            if let existing = page.pairs[id] {
                pair = existing
            } else {
                pair = makePair(for: id, in: pageView)
                page.pairs[id] = pair
            }
            position(pair: pair, for: node, absoluteFrame: absoluteFrame)
            pair.outline.applyStyle(node: node, accent: accent)
            pair.chip.label = CanvasEditChipModel.label(for: node)
            pair.chip.onTap = { [weak self] in self?.onSelectChip?(id) }

            // Visibility animates per pair, but the views stay in the tree
            // so springs animate from the previous opacity / transform.
            let progress = Double(index) / Double(totalNodes)
            let cappedDelay = min(perStepDelay * Double(index), 0.22)
            // Bottom-up reveal feels more natural than top-down for a
            // chip cluster: the user's eye is already near the top
            // (where the toggle just morphed) so chips sliding into
            // place from the top reads better than from the bottom.
            // Live-mode exit collapses simultaneously — no cascade.
            let delay = editMode ? cappedDelay : 0
            _ = progress
            setPair(pair: pair, visible: editMode, delay: delay)
            // Keep chips on top of outlines, and outlines on top of nodes
            // (the page's regular subview order draws nodes between the
            // background and the inset stroke).
            pageView.bringSubviewToFront(pair.outline)
            pageView.bringSubviewToFront(pair.chip)
        }

        pages[pageID] = page
    }

    // MARK: - Helpers

    private func makePageOverlay(pageID: UUID, pageView: UIView) -> PageOverlay {
        let inset = CAShapeLayer()
        // Initial color is a placeholder — the next `apply(...)` call
        // overwrites it with the page's adaptive accent. Stays
        // transparent until edit mode flips on so pre-edit users
        // never see a flash of the placeholder tone.
        inset.strokeColor = UIColor.cucuCherry.withAlphaComponent(0.25).cgColor
        inset.fillColor = UIColor.clear.cgColor
        inset.lineWidth = 2
        inset.opacity = 0
        return PageOverlay(pageView: pageView, insetStroke: inset)
    }

    private func makePair(for id: UUID, in pageView: UIView) -> Pair {
        let outline = DashedOutlineView()
        outline.alpha = 0
        // Outline starts a hair larger and settles back to 1.0 — reads
        // as the dashed border "snapping" onto the node rather than
        // appearing flat.
        outline.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
        pageView.addSubview(outline)

        let chip = NodeEditChipView()
        chip.alpha = 0
        chip.transform = CGAffineTransform(translationX: 0, y: 6)
        pageView.addSubview(chip)
        return Pair(outline: outline, chip: chip)
    }

    private func removePair(_ pair: Pair,
                            pageOverlay: inout PageOverlay,
                            id: UUID,
                            animated: Bool) {
        pageOverlay.pairs.removeValue(forKey: id)
        if animated {
            UIView.animate(withDuration: 0.18,
                           delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction],
                           animations: {
                pair.outline.alpha = 0
                pair.chip.alpha = 0
                pair.chip.transform = CGAffineTransform(translationX: 0, y: 6)
            }, completion: { _ in
                pair.outline.removeFromSuperview()
                pair.chip.removeFromSuperview()
            })
        } else {
            pair.outline.removeFromSuperview()
            pair.chip.removeFromSuperview()
        }
    }

    private func position(pair: Pair, for node: CanvasNode, absoluteFrame: CGRect) {
        // `absoluteFrame` is already in the host pageView's coordinate
        // space — for top-level nodes that's identical to
        // `node.frame.cgRect`, but for nested nodes (e.g. the hero's
        // avatar / name / bio children) the caller has already walked
        // the parent chain and translated the frame onto the page.
        let frame = absoluteFrame
        // Outline tracks the node's box plus a 3pt gutter on every side
        // — same spec as the JSX prototype.
        let outlineFrame = frame.insetBy(dx: -3, dy: -3)
        // Position via bounds + center so the in-flight scale transform
        // on a freshly-revealed outline doesn't get clobbered (setting
        // `.frame` on a transformed view is documented as "undefined").
        pair.outline.bounds = CGRect(origin: .zero, size: outlineFrame.size)
        pair.outline.center = CGPoint(x: outlineFrame.midX, y: outlineFrame.midY)
        let cornerRadius: CGFloat
        if node.style.clipShape == .circle {
            cornerRadius = min(outlineFrame.width, outlineFrame.height) / 2
        } else {
            cornerRadius = max(0, CGFloat(node.style.cornerRadius)) + 3
        }
        pair.outline.cornerRadius = cornerRadius

        // Chip floats above the node, anchored to its right edge so it
        // never bleeds off the left of the page. Spec puts the chip's
        // right edge 4pt inside the node's right edge — `frame.maxX -
        // chipWidth - 4` gives that. Above the node by `chipHeight + 4`.
        let chipWidth: CGFloat = 80
        let chipHeight: CGFloat = 22
        let aboveChipY = frame.minY - chipHeight - 4
        // When the node hugs the page top there's no room to float the
        // chip above it without crashing into the floating Edit / Editing
        // chrome (top-left and top-right of the page). Drop the chip to
        // y=38 inside the node — clear of the chrome band [12, 36] but
        // still pinned to the node's top-right corner. Threshold is
        // `chipHeight + page chrome band (~36)` so the inside-fallback
        // only fires when an above-placement would clip; everything
        // else sits above as the JSX spec specifies.
        let chipY: CGFloat = aboveChipY < 36 ? CGFloat(38) : aboveChipY
        let chipX = frame.maxX - chipWidth - 4
        let chipFrame = CGRect(
            x: max(4, chipX),
            y: chipY,
            width: chipWidth,
            height: chipHeight
        )
        pair.chip.bounds = CGRect(origin: .zero, size: chipFrame.size)
        pair.chip.center = CGPoint(x: chipFrame.midX, y: chipFrame.midY)
    }

    private func setPair(pair: Pair, visible: Bool, delay: TimeInterval = 0) {
        let target = visible ? CGFloat(1) : CGFloat(0)
        let outlineTarget: CGAffineTransform = visible
            ? .identity
            : CGAffineTransform(scaleX: 1.04, y: 1.04)
        let chipTarget: CGAffineTransform = visible
            ? .identity
            : CGAffineTransform(translationX: 0, y: 6)

        if pair.outline.alpha == target && pair.chip.alpha == target { return }
        UIView.animate(withDuration: visible ? 0.36 : 0.16,
                       delay: delay,
                       usingSpringWithDamping: 0.78,
                       initialSpringVelocity: 0.4,
                       options: [.curveEaseOut, .allowUserInteraction],
                       animations: {
            pair.outline.alpha = target
            pair.chip.alpha = target
            pair.outline.transform = outlineTarget
            pair.chip.transform = chipTarget
        })
    }

    private func animateLayerOpacity(_ layer: CALayer, to value: Float) {
        guard layer.opacity != value else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = value
        animation.duration = value == 1 ? 0.32 : 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = value
        layer.add(animation, forKey: "opacity")
    }
}

// MARK: - Dashed outline UIView

/// Thin dashed border used as the per-node accent in edit mode. Keeps the
/// dash phase fixed during resize so the dashes don't crawl as a node grows.
final class DashedOutlineView: UIView {
    private let stroke = CAShapeLayer()

    var cornerRadius: CGFloat = 6 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        stroke.fillColor = UIColor.clear.cgColor
        stroke.lineWidth = 1.4
        stroke.lineDashPattern = [4, 3]
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.opacity = 0.85
        layer.addSublayer(stroke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func applyStyle(node: CanvasNode, accent: UIColor) {
        stroke.strokeColor = accent.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stroke.frame = bounds
        let inset: CGFloat = 0.7
        let path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, cornerRadius - inset)
        )
        stroke.path = path.cgPath
    }
}

// MARK: - Edit chip UIView

struct CanvasEditChipModel {
    static func label(for node: CanvasNode) -> String {
        if let role = node.role {
            switch role {
            case .profileHero:   return "Header"
            case .profileAvatar: return "Avatar"
            case .profileName:   return "Name"
            case .profileBio:    return "Bio"
            case .profileMeta:   return "Meta"
            case .fixedDivider:  return "Spacer"
            case .sectionCard:   return "Section"
            }
        }
        if let custom = node.name, !custom.isEmpty, custom.count <= 12 {
            return custom
        }
        switch node.type {
        case .container: return "Section"
        case .text:      return "Text"
        case .image:     return "Image"
        case .icon:      return "Icon"
        case .divider:   return "Spacer"
        case .link:      return "Link"
        case .gallery:   return "Gallery"
        case .carousel:  return "Carousel"
        }
    }
}

/// Small floating button that labels a node in edit mode and routes the user
/// into the inspector on tap. Visual spec matches `NodeEditChip` in the
/// handoff JSX: cream fill, ink stroke, soft shadow, pencil glyph trailing
/// the label.
final class NodeEditChipView: UIControl {
    private let bgLayer = CAShapeLayer()
    private let labelView = UILabel()
    private let glyphView = PencilGlyphView(size: 11, color: .cucuInk)

    var label: String = "Edit" {
        didSet {
            labelView.text = label
            accessibilityLabel = "Edit \(label)"
        }
    }

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button

        bgLayer.fillColor = UIColor.cucuCard.cgColor
        bgLayer.strokeColor = UIColor.cucuInk.withAlphaComponent(0.18).cgColor
        bgLayer.lineWidth = 1
        bgLayer.shadowColor = UIColor.black.cgColor
        bgLayer.shadowOpacity = 0.18
        bgLayer.shadowRadius = 3
        bgLayer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(bgLayer)

        labelView.textColor = .cucuInk
        labelView.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        labelView.textAlignment = .center
        labelView.adjustsFontSizeToFitWidth = true
        labelView.minimumScaleFactor = 0.85
        labelView.isUserInteractionEnabled = false
        addSubview(labelView)

        glyphView.isUserInteractionEnabled = false
        addSubview(glyphView)

        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleTouchUpInside), for: .touchUpInside)
        addTarget(self, action: #selector(handleTouchCancel), for: [.touchUpOutside, .touchCancel])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: radius)
        bgLayer.frame = bounds
        bgLayer.path = path.cgPath
        bgLayer.shadowPath = path.cgPath

        // Layout: label sits centered with the glyph hugging the right edge.
        let glyphSize: CGFloat = 11
        let glyphX = bounds.width - glyphSize - 8
        let glyphY = (bounds.height - glyphSize) / 2
        glyphView.frame = CGRect(x: glyphX, y: glyphY, width: glyphSize, height: glyphSize)

        let labelLeft: CGFloat = 8
        let labelRight: CGFloat = glyphX - 4
        labelView.frame = CGRect(x: labelLeft,
                                 y: 0,
                                 width: max(0, labelRight - labelLeft),
                                 height: bounds.height)
    }

    // Slight tap target inflation — chips are 22pt tall and easy to miss
    // under a real fingertip.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6, dy: -6).contains(point)
    }

    /// VoiceOver / programmatic activation funnels through here. The default
    /// UIControl impl fires `.primaryActionTriggered`, but our touch
    /// handlers are wired only to `.touchUpInside` — explicitly send that
    /// so a chip activated via accessibility opens the inspector the same
    /// way a real fingertip would.
    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    @objc private func handleTouchDown() {
        animatePress(true)
    }

    @objc private func handleTouchUpInside() {
        animatePress(false)
        // Drop the press animation back to identity before we ask the host
        // to open the inspector — keeps the chip from looking "stuck" in
        // its pressed state if the host immediately tears it down.
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
        onTap?()
    }

    @objc private func handleTouchCancel() {
        animatePress(false)
    }

    private func animatePress(_ pressed: Bool) {
        UIView.animate(withDuration: pressed ? 0.12 : 0.22,
                       delay: 0,
                       usingSpringWithDamping: 0.7,
                       initialSpringVelocity: 0,
                       options: [.curveEaseOut, .allowUserInteraction],
                       animations: {
            self.transform = pressed
                ? CGAffineTransform(scaleX: 0.94, y: 0.94)
                : .identity
        })
    }
}

// MARK: - Pencil glyph UIView

/// UIKit twin of `PencilSquareShape` so the chip's trailing glyph stays
/// faithful to the spec without dragging in SwiftUI.
final class PencilGlyphView: UIView {
    private let stroke = CAShapeLayer()

    init(size: CGFloat, color: UIColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        backgroundColor = .clear

        stroke.fillColor = UIColor.clear.cgColor
        stroke.strokeColor = color.cgColor
        stroke.lineWidth = max(1.2, size * 0.135)
        stroke.lineCap = .round
        stroke.lineJoin = .round
        layer.addSublayer(stroke)
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        stroke.frame = bounds
        let unit = min(bounds.width, bounds.height) / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + x * unit, y: bounds.minY + y * unit)
        }
        let path = UIBezierPath()
        // top bar
        path.move(to: p(3, 3))
        path.addLine(to: p(9, 3))
        // L body
        path.move(to: p(3, 3))
        path.addLine(to: p(3, 13))
        path.addLine(to: p(13, 13))
        path.addLine(to: p(13, 8))
        // pencil head
        path.move(to: p(9.5, 12.5))
        path.addLine(to: p(13, 9))
        path.addLine(to: p(14.5, 10.5))
        path.addLine(to: p(11, 14))
        path.addLine(to: p(9.5, 14))
        path.close()
        stroke.path = path.cgPath
    }
}
