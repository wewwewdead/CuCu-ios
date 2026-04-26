import UIKit

/// Renders a `.divider` node as a horizontal decorative break. Two
/// rendering paths share a single `CAShapeLayer`:
///
/// - **Stroke families** (solid, dashed, dotted, double, lace, ribbon,
///   pixel) draw one or more horizontal lines with a `lineDashPattern`
///   tuned per family.
/// - **Chain families** (sparkle, star, flower, heart, bow) repeat an
///   SF Symbol horizontally at a tunable spacing.
///
/// All families respect `borderColorHex` (color), `dividerThickness`
/// (line width / glyph size), and `opacity`. The node's background
/// color is not painted — a divider is purely a foreground glyph
/// against the page or its container.
final class DividerNodeView: NodeRenderView {
    private struct RenderSignature: Equatable {
        var family: NodeDividerStyleFamily
        var colorKey: String
        var thickness: CGFloat
        var size: CGSize
    }

    private let shapeLayer = CAShapeLayer()
    private let secondaryShapeLayer = CAShapeLayer() // for double-line family
    /// Container holding the chain of repeated symbol images. Cleared
    /// and rebuilt on every apply for chain-style families.
    private let chainContainer = UIView()
    private var currentFamily: NodeDividerStyleFamily = .solid
    private var currentColor: UIColor = UIColor(white: 0.1, alpha: 1)
    private var currentColorKey: String = ""
    private var currentThickness: CGFloat = 2
    private var lastRenderSignature: RenderSignature?

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        clipsToBounds = false
        layer.masksToBounds = false
        backgroundColor = .clear

        chainContainer.translatesAutoresizingMaskIntoConstraints = false
        chainContainer.isUserInteractionEnabled = false
        chainContainer.clipsToBounds = false
        addSubview(chainContainer)

        layer.addSublayer(shapeLayer)
        layer.addSublayer(secondaryShapeLayer)
        shapeLayer.fillColor = UIColor.clear.cgColor
        secondaryShapeLayer.fillColor = UIColor.clear.cgColor
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)
        // The divider doesn't want a perimeter border or background;
        // its color comes from `borderColorHex` and we paint the line
        // ourselves.
        backgroundColor = .clear
        layer.borderWidth = 0
        layer.borderColor = UIColor.clear.cgColor

        let family = node.style.dividerStyleFamily ?? .solid
        let colorKey = node.style.borderColorHex ?? "__default"
        let color = node.style.borderColorHex.map(uiColor(hex:)) ?? UIColor(white: 0.1, alpha: 1)
        let thickness = max(CGFloat(node.style.dividerThickness ?? 2), 0.5)
        currentFamily = family
        currentColor = color
        currentColorKey = colorKey
        currentThickness = thickness

        let signature = RenderSignature(
            family: family,
            colorKey: colorKey,
            thickness: thickness,
            size: bounds.size
        )
        guard lastRenderSignature != signature else { return }
        lastRenderSignature = signature

        // Tear down whichever rendering path was active last apply pass.
        chainContainer.subviews.forEach { $0.removeFromSuperview() }
        shapeLayer.path = nil
        secondaryShapeLayer.path = nil
        shapeLayer.lineDashPattern = nil
        secondaryShapeLayer.lineDashPattern = nil
        shapeLayer.strokeColor = color.cgColor
        secondaryShapeLayer.strokeColor = color.cgColor
        shapeLayer.lineWidth = thickness
        secondaryShapeLayer.lineWidth = thickness

        if let symbol = family.chainSymbol {
            renderChain(symbol: symbol, color: color, thickness: thickness)
        } else {
            renderStroke(family: family, color: color, thickness: thickness)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        chainContainer.frame = bounds
        // Re-render on bounds change so dashes / chain density stay
        // consistent at the new width. Cheap.
        let signature = RenderSignature(
            family: currentFamily,
            colorKey: currentColorKey,
            thickness: currentThickness,
            size: bounds.size
        )
        guard lastRenderSignature != signature else { return }
        lastRenderSignature = signature
        chainContainer.subviews.forEach { $0.removeFromSuperview() }
        shapeLayer.path = nil
        secondaryShapeLayer.path = nil
        if let symbol = currentFamily.chainSymbol {
            renderChain(symbol: symbol, color: currentColor, thickness: currentThickness)
        } else {
            renderStroke(family: currentFamily, color: currentColor, thickness: currentThickness)
        }
    }

    // MARK: - Stroke families

    private func renderStroke(family: NodeDividerStyleFamily,
                              color: UIColor,
                              thickness: CGFloat) {
        let midY = bounds.midY
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: bounds.width, y: midY))
        shapeLayer.path = path.cgPath

        switch family {
        case .solid:
            shapeLayer.lineDashPattern = nil
            shapeLayer.lineCap = .round
        case .dashed:
            shapeLayer.lineDashPattern = [10, 6]
            shapeLayer.lineCap = .butt
        case .dotted:
            shapeLayer.lineDashPattern = [0.1, NSNumber(value: Double(thickness * 3))]
            shapeLayer.lineCap = .round
        case .double:
            // Two parallel lines, one above and one below the centerline.
            let offset = max(thickness * 1.5, 3)
            let upper = UIBezierPath()
            upper.move(to: CGPoint(x: 0, y: midY - offset))
            upper.addLine(to: CGPoint(x: bounds.width, y: midY - offset))
            shapeLayer.path = upper.cgPath
            let lower = UIBezierPath()
            lower.move(to: CGPoint(x: 0, y: midY + offset))
            lower.addLine(to: CGPoint(x: bounds.width, y: midY + offset))
            secondaryShapeLayer.path = lower.cgPath
            shapeLayer.lineCap = .round
            secondaryShapeLayer.lineCap = .round
        case .lace:
            // Scalloped half-circles along the line — fake "lace" edge.
            let scallopRadius: CGFloat = max(thickness * 3, 6)
            let p = UIBezierPath()
            var x: CGFloat = 0
            while x < bounds.width {
                p.move(to: CGPoint(x: x, y: midY))
                p.addArc(withCenter: CGPoint(x: x + scallopRadius, y: midY),
                         radius: scallopRadius,
                         startAngle: .pi, endAngle: 0, clockwise: true)
                x += scallopRadius * 2
            }
            shapeLayer.path = p.cgPath
            shapeLayer.lineCap = .round
        case .ribbon:
            // Wavy ribbon — sine wave along the centerline.
            let p = UIBezierPath()
            let amp: CGFloat = max(bounds.height / 4, 4)
            let wavelength: CGFloat = max(bounds.height * 1.5, 24)
            var x: CGFloat = 0
            p.move(to: CGPoint(x: 0, y: midY))
            while x < bounds.width {
                let next = min(x + wavelength / 2, bounds.width)
                let cp = CGPoint(x: (x + next) / 2,
                                 y: midY + (((Int(x / (wavelength / 2))) % 2 == 0) ? -amp : amp))
                p.addQuadCurve(to: CGPoint(x: next, y: midY), controlPoint: cp)
                x = next
            }
            shapeLayer.path = p.cgPath
            shapeLayer.lineCap = .round
        case .pixel:
            // Stepped square-wave line — a pixel-art break.
            let p = UIBezierPath()
            let step: CGFloat = 6
            let amp = max(thickness * 2, 4)
            var x: CGFloat = 0
            var goingDown = false
            p.move(to: CGPoint(x: 0, y: midY - amp / 2))
            while x < bounds.width {
                let nextX = min(x + step, bounds.width)
                let y = goingDown ? midY + amp / 2 : midY - amp / 2
                p.addLine(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: nextX, y: y))
                goingDown.toggle()
                x = nextX
            }
            shapeLayer.path = p.cgPath
            shapeLayer.lineCap = .square
        default:
            // Chain families never reach here; if a new stroke family
            // ships without a switch arm, draw a plain solid line.
            shapeLayer.lineDashPattern = nil
            shapeLayer.lineCap = .round
        }
    }

    // MARK: - Chain families

    private func renderChain(symbol: String, color: UIColor, thickness: CGFloat) {
        let glyphSize = max(thickness * 6, min(bounds.height, 24))
        let spacing = glyphSize * 0.6
        let count = max(1, Int(bounds.width / (glyphSize + spacing)))
        let totalWidth = CGFloat(count) * glyphSize + CGFloat(max(0, count - 1)) * spacing
        let startX = (bounds.width - totalWidth) / 2
        let y = bounds.midY - glyphSize / 2

        let config = UIImage.SymbolConfiguration(weight: .bold)
        let image = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)

        for i in 0..<count {
            let iv = UIImageView(image: image)
            iv.contentMode = .scaleAspectFit
            iv.frame = CGRect(
                x: startX + CGFloat(i) * (glyphSize + spacing),
                y: y,
                width: glyphSize,
                height: glyphSize
            )
            chainContainer.addSubview(iv)
        }
    }
}
