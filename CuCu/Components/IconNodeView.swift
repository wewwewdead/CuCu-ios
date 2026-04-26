import UIKit

/// Renders an `.icon` node — an SF Symbol drawn over a style-family-driven
/// plate. The same heart-glyph reads as a pastel doodle, a chunky pixel
/// sticker, or a glossy y2k blob depending on `NodeStyle.iconStyleFamily`.
///
/// Layer stack (back to front):
///   1. `plateView`     — the family's background plate (disk, rounded
///                        rect, washi-tape rectangle, ...).
///   2. `accentView`    — optional family-specific accent layer (bow
///                        ribbon, scribble shadow, glow, ...).
///   3. `imageView`     — the tinted SF Symbol glyph itself.
///   4. `labelView`     — optional caption underneath the glyph
///                        (taken from `node.content.text`).
///
/// All layers are pinned to the node's bounds (or laid out by hand inside
/// `apply(node:)` for the family-specific composition). The
/// `NodeRenderView` superclass handles outer corner radius / clip
/// shape / border / opacity, but most icon families intentionally use a
/// cornerRadius of 0 on the outer view and let the inner `plateView`
/// supply the visual silhouette so the glyph itself can extend outside
/// the plate (sticker overhangs, etc.) without being clipped.
final class IconNodeView: NodeRenderView {
    private struct RenderSignature: Equatable {
        var family: NodeIconStyleFamily
        var symbolName: String
        var plateFillKey: String
        var outlineKey: String
        var glyphTintKey: String
        var outlineWidth: CGFloat
        var labelText: String
        var size: CGSize
    }

    private let plateView = UIView()
    private let accentView = UIView()
    private let imageView = UIImageView()
    private let labelView: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textAlignment = .center
        l.numberOfLines = 1
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        return l
    }()

    /// Cached so we know whether to re-layout the inner plate / accent
    /// when family or label visibility flips.
    private var lastFamily: NodeIconStyleFamily?
    private var lastHasLabel: Bool = false
    private var lastRenderSignature: RenderSignature?

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        clipsToBounds = false
        layer.masksToBounds = false

        plateView.translatesAutoresizingMaskIntoConstraints = false
        accentView.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        plateView.isUserInteractionEnabled = false
        accentView.isUserInteractionEnabled = false
        imageView.isUserInteractionEnabled = false
        labelView.isUserInteractionEnabled = false

        addSubview(plateView)
        addSubview(accentView)
        addSubview(imageView)
        addSubview(labelView)
    }

    override func apply(node: CanvasNode) {
        // The icon view supplies its OWN plate, so we deliberately
        // suppress the inherited background / border / corner radius
        // by zeroing them on the underlying NodeStyle copy before
        // forwarding to super. This way the user's `backgroundColorHex`
        // can still drive the plate fill while not clashing with the
        // outer rounded rectangle.
        super.apply(node: node)
        backgroundColor = .clear
        layer.borderWidth = 0
        layer.borderColor = UIColor.clear.cgColor
        layer.masksToBounds = false
        clipsToBounds = false

        let family = node.style.iconStyleFamily ?? .pastelDoodle
        let symbolName = node.content.iconName ?? "star.fill"
        let plateFillKey = node.style.backgroundColorHex ?? "__default_plate_\(family.rawValue)"
        let outlineKey = node.style.borderColorHex ?? "__default_outline"
        let glyphTintKey = node.style.tintColorHex ?? "__default_tint_\(family.rawValue)"
        let plateFill = node.style.backgroundColorHex.map(uiColor(hex:)) ?? defaultPlate(for: family)
        let outline = node.style.borderColorHex.map(uiColor(hex:)) ?? UIColor(white: 0.1, alpha: 1)
        let glyphTint = node.style.tintColorHex.map(uiColor(hex:)) ?? defaultTint(for: family)
        let outlineWidth = max(CGFloat(node.style.borderWidth), 0)
        let labelText = node.content.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasLabel = !labelText.isEmpty
        labelView.isHidden = !hasLabel
        labelView.text = labelText
        labelView.textColor = glyphTint
        labelView.font = UIFont.systemFont(ofSize: 13, weight: .semibold)

        // Allocate vertical space for the label so the glyph stays
        // centered above it rather than slipping under it.
        let labelHeight: CGFloat = hasLabel ? 18 : 0
        let plateRect = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(0, bounds.height - labelHeight)
        )
        plateView.frame = plateRect
        accentView.frame = plateRect
        labelView.frame = CGRect(
            x: 0,
            y: bounds.height - labelHeight,
            width: bounds.width,
            height: labelHeight
        )

        // Family-specific composition (plate shape, accents, weight).
        let signature = RenderSignature(
            family: family,
            symbolName: symbolName,
            plateFillKey: plateFillKey,
            outlineKey: outlineKey,
            glyphTintKey: glyphTintKey,
            outlineWidth: outlineWidth,
            labelText: labelText,
            size: bounds.size
        )
        if lastRenderSignature != signature {
            layoutFamily(
                family,
                plateFill: plateFill,
                outline: outline,
                outlineWidth: outlineWidth,
                glyphTint: glyphTint,
                symbolName: symbolName,
                in: plateRect
            )
            lastRenderSignature = signature
        }

        lastFamily = family
        lastHasLabel = hasLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-run family composition on resize so plate / accents track
        // the new bounds. Cheap — no image re-decoding.
        guard bounds.width > 0, bounds.height > 0 else { return }
        let labelHeight: CGFloat = lastHasLabel ? 18 : 0
        let plateRect = CGRect(
            x: 0, y: 0,
            width: bounds.width,
            height: max(0, bounds.height - labelHeight)
        )
        plateView.frame = plateRect
        accentView.frame = plateRect
        labelView.frame = CGRect(
            x: 0,
            y: bounds.height - labelHeight,
            width: bounds.width,
            height: labelHeight
        )
        relayoutPlateLayers(in: plateRect)
        relayoutAccentLayers(in: plateRect)
        layoutGlyph(in: plateRect)
    }

    // MARK: - Family composition

    private func layoutFamily(_ family: NodeIconStyleFamily,
                              plateFill: UIColor,
                              outline: UIColor,
                              outlineWidth: CGFloat,
                              glyphTint: UIColor,
                              symbolName: String,
                              in rect: CGRect) {
        // Fresh state: drop any layers from the previous family so we
        // don't accumulate strokes on every apply pass.
        plateView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        accentView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        plateView.backgroundColor = .clear
        accentView.backgroundColor = .clear
        plateView.layer.cornerRadius = 0
        plateView.layer.borderWidth = 0
        plateView.layer.shadowOpacity = 0

        // Per-family plate.
        switch family {
        case .pastelDoodle:
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2
            plateView.backgroundColor = plateFill
            plateView.layer.borderColor = outline.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 1.5)
            // Doodled offset shadow — same disk, dark, offset down-right.
            let shadow = CAShapeLayer()
            shadow.path = UIBezierPath(ovalIn: rect.insetBy(dx: 0, dy: 0).offsetBy(dx: 3, dy: 3)).cgPath
            shadow.fillColor = outline.withAlphaComponent(0.85).cgColor
            accentView.layer.insertSublayer(shadow, at: 0)
            plateView.superview?.sendSubviewToBack(plateView)
            // We want the shadow BEHIND the plate; achieved by adding
            // accent before plate in z-order.
            sendSubviewToBack(accentView)
            bringSubviewToFront(plateView)
        case .y2kCute:
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2
            // Vertical chrome gradient.
            let g = CAGradientLayer()
            g.frame = plateView.bounds
            g.colors = [
                UIColor(white: 1.0, alpha: 1).cgColor,
                plateFill.cgColor,
                UIColor(white: 0.7, alpha: 1).cgColor
            ]
            g.locations = [0, 0.55, 1]
            g.cornerRadius = plateView.layer.cornerRadius
            plateView.layer.addSublayer(g)
            plateView.layer.borderColor = outline.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 1.5)
            // Glossy highlight: small white half-circle near the top.
            let gloss = CAShapeLayer()
            let glossRect = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18)
            let glossPath = UIBezierPath(arcCenter: CGPoint(x: glossRect.midX, y: glossRect.minY + 2),
                                         radius: glossRect.width * 0.45,
                                         startAngle: .pi, endAngle: 0, clockwise: true)
            glossPath.close()
            gloss.path = glossPath.cgPath
            gloss.fillColor = UIColor.white.withAlphaComponent(0.55).cgColor
            accentView.layer.addSublayer(gloss)
        case .pixelCute:
            plateView.layer.cornerRadius = 4
            plateView.backgroundColor = plateFill
            plateView.layer.borderColor = outline.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 3)
            // Inner pixel border — second rectangle inset 4pt.
            let inner = CAShapeLayer()
            inner.path = UIBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), cornerRadius: 2).cgPath
            inner.fillColor = UIColor.clear.cgColor
            inner.strokeColor = outline.withAlphaComponent(0.45).cgColor
            inner.lineWidth = 1.5
            accentView.layer.addSublayer(inner)
        case .handDrawn:
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2 - 2
            plateView.backgroundColor = plateFill
            // Wobbly halo — slightly larger oval, dashed.
            let halo = CAShapeLayer()
            halo.path = UIBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3)).cgPath
            halo.fillColor = UIColor.clear.cgColor
            halo.strokeColor = outline.cgColor
            halo.lineWidth = max(outlineWidth, 1.5)
            halo.lineDashPattern = [3, 3]
            accentView.layer.addSublayer(halo)
        case .sticker:
            // Thick white border + drop shadow.
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2
            plateView.backgroundColor = plateFill
            plateView.layer.borderColor = UIColor.white.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 4)
            plateView.layer.shadowColor = UIColor.black.cgColor
            plateView.layer.shadowOffset = CGSize(width: 0, height: 4)
            plateView.layer.shadowRadius = 6
            plateView.layer.shadowOpacity = 0.25
            plateView.layer.masksToBounds = false
        case .softMinimal:
            // No plate. Optional subtle ring.
            if outlineWidth > 0 {
                let ring = CAShapeLayer()
                ring.path = UIBezierPath(ovalIn: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2)).cgPath
                ring.fillColor = UIColor.clear.cgColor
                ring.strokeColor = outline.cgColor
                ring.lineWidth = outlineWidth
                accentView.layer.addSublayer(ring)
            }
        case .glossyKawaii:
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2
            let g = CAGradientLayer()
            g.frame = plateView.bounds
            g.colors = [plateFill.lighter(by: 0.18).cgColor, plateFill.cgColor, plateFill.darker(by: 0.18).cgColor]
            g.locations = [0, 0.5, 1]
            g.cornerRadius = plateView.layer.cornerRadius
            plateView.layer.addSublayer(g)
            // Shine: angled white ellipse.
            let shine = CAShapeLayer()
            let path = UIBezierPath(ovalIn: CGRect(x: rect.minX + rect.width * 0.18,
                                                    y: rect.minY + rect.height * 0.10,
                                                    width: rect.width * 0.55,
                                                    height: rect.height * 0.22))
            shine.path = path.cgPath
            shine.fillColor = UIColor.white.withAlphaComponent(0.55).cgColor
            accentView.layer.addSublayer(shine)
            plateView.layer.borderColor = outline.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 1.5)
        case .scrapbook:
            // Washi-tape rectangle behind the glyph: slightly tilted,
            // diagonal stripes.
            plateView.transform = .identity
            plateView.layer.cornerRadius = 2
            plateView.backgroundColor = plateFill
            // Diagonal stripes via a CAReplicatorLayer pattern.
            let stripeLayer = CAShapeLayer()
            let stripePath = UIBezierPath()
            let step: CGFloat = 8
            var x = rect.minX - rect.height
            while x < rect.maxX + rect.height {
                stripePath.move(to: CGPoint(x: x, y: rect.minY))
                stripePath.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
                x += step
            }
            stripeLayer.path = stripePath.cgPath
            stripeLayer.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
            stripeLayer.lineWidth = 2
            stripeLayer.frame = rect
            stripeLayer.masksToBounds = true
            plateView.layer.addSublayer(stripeLayer)
            plateView.transform = CGAffineTransform(rotationAngle: -0.06)
        case .dreamy:
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2
            plateView.backgroundColor = plateFill.withAlphaComponent(0.85)
            // Soft outer glow.
            plateView.layer.shadowColor = plateFill.cgColor
            plateView.layer.shadowOffset = .zero
            plateView.layer.shadowRadius = max(rect.width, rect.height) * 0.18
            plateView.layer.shadowOpacity = 0.7
            plateView.layer.masksToBounds = false
        case .coquette:
            plateView.layer.cornerRadius = min(rect.width, rect.height) / 2
            plateView.backgroundColor = plateFill
            plateView.layer.borderColor = outline.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 1.5)
            // Bow accent in the top-right — small curved shape.
            let bow = CAShapeLayer()
            let bowRect = CGRect(x: rect.maxX - rect.width * 0.36,
                                 y: rect.minY - rect.height * 0.04,
                                 width: rect.width * 0.36,
                                 height: rect.height * 0.28)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: bowRect.midX, y: bowRect.midY))
            p.addQuadCurve(to: CGPoint(x: bowRect.minX, y: bowRect.midY),
                           controlPoint: CGPoint(x: bowRect.minX + 2, y: bowRect.minY))
            p.addQuadCurve(to: CGPoint(x: bowRect.midX, y: bowRect.midY),
                           controlPoint: CGPoint(x: bowRect.minX + 2, y: bowRect.maxY))
            p.move(to: CGPoint(x: bowRect.midX, y: bowRect.midY))
            p.addQuadCurve(to: CGPoint(x: bowRect.maxX, y: bowRect.midY),
                           controlPoint: CGPoint(x: bowRect.maxX - 2, y: bowRect.minY))
            p.addQuadCurve(to: CGPoint(x: bowRect.midX, y: bowRect.midY),
                           controlPoint: CGPoint(x: bowRect.maxX - 2, y: bowRect.maxY))
            bow.path = p.cgPath
            bow.fillColor = outline.cgColor
            bow.strokeColor = outline.cgColor
            bow.lineWidth = 1
            accentView.layer.addSublayer(bow)
        case .retroWeb:
            plateView.layer.cornerRadius = 6
            plateView.backgroundColor = plateFill
            plateView.layer.borderColor = outline.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 2)
            // Hard offset shadow — bottom-right rectangle.
            let shadow = CAShapeLayer()
            shadow.path = UIBezierPath(roundedRect: rect.offsetBy(dx: 3, dy: 3), cornerRadius: 6).cgPath
            shadow.fillColor = outline.cgColor
            accentView.layer.insertSublayer(shadow, at: 0)
            sendSubviewToBack(accentView)
            bringSubviewToFront(plateView)
        case .cyberCute:
            plateView.layer.cornerRadius = 12
            plateView.backgroundColor = UIColor(white: 0.08, alpha: 1)
            plateView.layer.borderColor = plateFill.cgColor
            plateView.layer.borderWidth = max(outlineWidth, 2)
            plateView.layer.shadowColor = plateFill.cgColor
            plateView.layer.shadowOffset = .zero
            plateView.layer.shadowRadius = 8
            plateView.layer.shadowOpacity = 0.8
            plateView.layer.masksToBounds = false
        }

        // Glyph rendering with a family-tuned weight + scale.
        let weight: UIImage.SymbolWeight
        let scale: UIImage.SymbolScale
        switch family {
        case .pixelCute, .retroWeb, .sticker, .y2kCute: weight = .heavy; scale = .large
        case .softMinimal, .dreamy, .handDrawn:         weight = .regular; scale = .medium
        default:                                         weight = .bold; scale = .large
        }
        let config = UIImage.SymbolConfiguration(weight: weight)
            .applying(UIImage.SymbolConfiguration(scale: scale))
        let glyph = UIImage(systemName: symbolName, withConfiguration: config)
            ?? UIImage(systemName: "star.fill", withConfiguration: config)
        imageView.image = glyph
        imageView.tintColor = (family == .cyberCute) ? plateFill : glyphTint
        bringSubviewToFront(imageView)
        layoutGlyph(in: rect)

        relayoutPlateLayers(in: rect)
        relayoutAccentLayers(in: rect)
    }

    /// Re-pin any plate-internal sublayers to a fresh rect (CAShapeLayer
    /// paths are absolute, not auto-resizing — UIView frame changes
    /// don't reflow them).
    private func relayoutPlateLayers(in rect: CGRect) {
        for sub in plateView.layer.sublayers ?? [] {
            if let g = sub as? CAGradientLayer {
                g.frame = plateView.bounds
                g.cornerRadius = plateView.layer.cornerRadius
            }
        }
    }

    private func relayoutAccentLayers(in rect: CGRect) {
        // Cheap rebuild: family composition is keyed off the cached
        // values so a dedicated reflow path isn't worth the cost — we
        // just re-run `layoutFamily` on resize via the apply path.
    }

    private func layoutGlyph(in rect: CGRect) {
        // Glyph fills 60% of the plate's smaller dimension, centered.
        let side = min(rect.width, rect.height) * 0.60
        imageView.frame = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
    }

    private func defaultPlate(for family: NodeIconStyleFamily) -> UIColor {
        switch family {
        case .pastelDoodle: return uiColor(hex: "#FFE3EC")
        case .y2kCute:      return uiColor(hex: "#D8B6FF")
        case .pixelCute:    return uiColor(hex: "#FFE082")
        case .handDrawn:    return uiColor(hex: "#FFF6D6")
        case .sticker:      return uiColor(hex: "#F2A0BC")
        case .softMinimal:  return UIColor.clear
        case .glossyKawaii: return uiColor(hex: "#FFC2D9")
        case .scrapbook:    return uiColor(hex: "#FFD6D6")
        case .dreamy:       return uiColor(hex: "#C4D7FF")
        case .coquette:     return uiColor(hex: "#FAD3DD")
        case .retroWeb:     return uiColor(hex: "#FFE066")
        case .cyberCute:    return uiColor(hex: "#74F2DC")
        }
    }

    private func defaultTint(for family: NodeIconStyleFamily) -> UIColor {
        switch family {
        case .pastelDoodle: return uiColor(hex: "#B22A4A")
        case .y2kCute:      return uiColor(hex: "#341B62")
        case .pixelCute:    return uiColor(hex: "#3A1D00")
        case .handDrawn:    return uiColor(hex: "#3D2E12")
        case .sticker:      return uiColor(hex: "#FFFFFF")
        case .softMinimal:  return uiColor(hex: "#3A3A3C")
        case .glossyKawaii: return uiColor(hex: "#FFFFFF")
        case .scrapbook:    return uiColor(hex: "#5A2231")
        case .dreamy:       return uiColor(hex: "#2A3D7C")
        case .coquette:     return uiColor(hex: "#5A1A2E")
        case .retroWeb:     return uiColor(hex: "#1A1A1A")
        case .cyberCute:    return uiColor(hex: "#0A0F18")
        }
    }
}

// MARK: - UIColor helpers

private extension UIColor {
    /// Mix this color toward white by `amount` (0…1). Used for glossy
    /// kawaii gradient stops.
    func lighter(by amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return UIColor(red: r + (1 - r) * amount,
                       green: g + (1 - g) * amount,
                       blue: b + (1 - b) * amount,
                       alpha: a)
    }

    /// Mix this color toward black by `amount` (0…1).
    func darker(by amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return UIColor(red: r * (1 - amount),
                       green: g * (1 - amount),
                       blue: b * (1 - amount),
                       alpha: a)
    }
}
