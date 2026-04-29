import UIKit

/// Renders a `.link` node — a clickable-looking surface with a title and
/// (optionally) a small leading SF Symbol. The actual tap-to-open
/// behavior is intentionally *not* wired in this phase; the node only
/// needs to read as a link visually inside the builder and preview.
///
/// `NodeStyle.linkStyleVariant` switches between five visual treatments:
/// pill, card, underlined, button, badge. Each variant respects the
/// shared `backgroundColorHex` / `borderColorHex` / `cornerRadius`
/// fields where they make sense, and overrides where the variant has a
/// stronger opinion (the underlined variant ignores backgrounds, etc.).
final class LinkNodeView: NodeRenderView {
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 1
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        return l
    }()
    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingMiddle
        return l
    }()
    private let symbolImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        return v
    }()
    /// Wavy underline drawn under the title for the `.underlined`
    /// variant — gives the link a hand-drawn / artsy emphasis.
    private let underlineLayer = CAShapeLayer()

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        addSubview(symbolImageView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        layer.addSublayer(underlineLayer)
        underlineLayer.fillColor = UIColor.clear.cgColor
        underlineLayer.lineCap = .round
        clipsToBounds = false
        layer.masksToBounds = false
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        let variant = node.style.linkStyleVariant ?? .pill
        let title = (node.content.text?.isEmpty == false) ? (node.content.text ?? "") : "my link"
        let url = node.content.url ?? ""

        let textColor = node.style.textColorHex.map(uiColor(hex:)) ?? UIColor(white: 0.1, alpha: 1)
        let bgColor = node.style.backgroundColorHex.map(uiColor(hex:))
        let borderColor = node.style.borderColorHex.map(uiColor(hex:))

        let weight = (node.style.fontWeight ?? .semibold).uiFontWeight
        let size = CGFloat(node.style.fontSize ?? 16)
        // Same resolver as the text node so cute / artsy faces show
        // up here too — a link styled with Caprasimo or Pacifico
        // matches the rest of the canvas's typography vocabulary.
        let family = node.style.fontFamily ?? .system
        titleLabel.font = family.uiFont(size: size, weight: weight)
        titleLabel.textColor = textColor
        titleLabel.text = title
        titleLabel.textAlignment = (node.style.textAlignment ?? .center).uiAlignment

        // Optional symbol on the leading side. We treat
        // `node.content.iconName` as the link's leading glyph if set —
        // same field icon nodes use, so a future cross-reference (e.g.
        // "use this icon as my link's leading mark") works for free.
        if let symbolName = node.content.iconName, !symbolName.isEmpty {
            // Same three-way fork as `IconNodeView`:
            //   • `brand.*` → vendored single-color SVG, tinted.
            //   • `multi.*` → vendored multi-color SVG, original colors.
            //   • everything else → SF Symbol.
            var multicolor = false
            if symbolName.hasPrefix("brand.") {
                let assetName = "SocialIcons/" + String(symbolName.dropFirst("brand.".count))
                symbolImageView.image = UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate)
            } else if symbolName.hasPrefix("multi.") {
                let assetName = "Glyphs/" + String(symbolName.dropFirst("multi.".count))
                symbolImageView.image = UIImage(named: assetName)?.withRenderingMode(.alwaysOriginal)
                multicolor = true
            } else {
                let cfg = UIImage.SymbolConfiguration(weight: .semibold)
                symbolImageView.image = UIImage(systemName: symbolName, withConfiguration: cfg)
            }
            symbolImageView.tintColor = multicolor ? nil : textColor
            symbolImageView.isHidden = (symbolImageView.image == nil)
        } else {
            symbolImageView.image = nil
            symbolImageView.isHidden = true
        }

        // Reset variant-specific overlays.
        underlineLayer.path = nil
        subtitleLabel.isHidden = true
        subtitleLabel.text = nil

        switch variant {
        case .pill:
            backgroundColor = bgColor ?? uiColor(hex: "#FBF6E9")
            layer.cornerRadius = bounds.height / 2
            layer.borderColor = (borderColor ?? UIColor(white: 0.1, alpha: 1)).cgColor
            layer.borderWidth = max(CGFloat(node.style.borderWidth), 1)
        case .card:
            backgroundColor = bgColor ?? uiColor(hex: "#FFFFFF")
            layer.cornerRadius = max(CGFloat(node.style.cornerRadius), 12)
            layer.borderColor = (borderColor ?? uiColor(hex: "#1A140E")).cgColor
            layer.borderWidth = max(CGFloat(node.style.borderWidth), 1)
            // Show the URL as a subtitle line under the title for
            // card-style links — gives the surface its "this is a real
            // destination" cue without claiming the user's full title.
            if !url.isEmpty {
                subtitleLabel.isHidden = false
                subtitleLabel.text = url
                subtitleLabel.font = .systemFont(ofSize: max(11, size - 4), weight: .regular)
                subtitleLabel.textColor = textColor.withAlphaComponent(0.6)
                subtitleLabel.textAlignment = titleLabel.textAlignment
            }
        case .underlined:
            backgroundColor = .clear
            layer.cornerRadius = 0
            layer.borderWidth = 0
            // Wavy underline beneath the title, drawn after layout in
            // `layoutSubviews()` so it tracks the title's measured frame.
            underlineLayer.strokeColor = textColor.cgColor
            underlineLayer.lineWidth = 2
        case .button:
            backgroundColor = bgColor ?? uiColor(hex: "#1A140E")
            layer.cornerRadius = max(CGFloat(node.style.cornerRadius), 8)
            layer.borderColor = UIColor.clear.cgColor
            layer.borderWidth = 0
            titleLabel.textColor = textColor == UIColor(white: 0.1, alpha: 1)
                ? .white
                : textColor
            // Hard offset shadow — the button "pops" off the page.
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 3)
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 0
        case .badge:
            backgroundColor = bgColor ?? uiColor(hex: "#FAD3DD")
            layer.cornerRadius = max(CGFloat(node.style.cornerRadius), 10)
            layer.borderColor = (borderColor ?? uiColor(hex: "#B22A4A")).cgColor
            layer.borderWidth = max(CGFloat(node.style.borderWidth), 1)
            titleLabel.text = "[\(title)]"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hasSymbol = !symbolImageView.isHidden
        let hasSubtitle = !subtitleLabel.isHidden
        let symbolSide: CGFloat = hasSymbol ? min(bounds.height - 12, 22) : 0
        let symbolGap: CGFloat = hasSymbol ? 8 : 0
        let leadingPadding: CGFloat = 14
        let trailingPadding: CGFloat = 14

        if hasSymbol {
            symbolImageView.frame = CGRect(
                x: leadingPadding,
                y: (bounds.height - symbolSide) / 2,
                width: symbolSide,
                height: symbolSide
            )
        }

        let titleX = leadingPadding + symbolSide + symbolGap
        let titleWidth = max(0, bounds.width - titleX - trailingPadding)
        if hasSubtitle {
            titleLabel.frame = CGRect(
                x: titleX,
                y: bounds.height / 2 - 18,
                width: titleWidth,
                height: 22
            )
            subtitleLabel.frame = CGRect(
                x: titleX,
                y: bounds.height / 2 + 2,
                width: titleWidth,
                height: 16
            )
        } else {
            titleLabel.frame = CGRect(
                x: titleX,
                y: 0,
                width: titleWidth,
                height: bounds.height
            )
        }

        // Wavy underline (variant=.underlined). Triangle-wave path
        // sized to the title's text width so it doesn't extend past
        // the visible glyphs.
        if underlineLayer.strokeColor != nil, !titleLabel.text.isNilOrEmpty {
            let textRect = titleLabel.textRect(forBounds: titleLabel.bounds, limitedToNumberOfLines: 1)
            let baseY = titleLabel.frame.maxY - 4
            let p = UIBezierPath()
            let amp: CGFloat = 2.5
            let wavelength: CGFloat = 8
            var x = titleLabel.frame.minX + (titleLabel.frame.width - textRect.width) / 2
            let endX = x + textRect.width
            p.move(to: CGPoint(x: x, y: baseY))
            var goingUp = true
            while x < endX {
                let nextX = min(x + wavelength / 2, endX)
                let mid = CGPoint(x: (x + nextX) / 2, y: baseY + (goingUp ? -amp : amp))
                p.addQuadCurve(to: CGPoint(x: nextX, y: baseY), controlPoint: mid)
                x = nextX
                goingUp.toggle()
            }
            underlineLayer.path = p.cgPath
        }
    }
}

// MARK: - Helpers

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        switch self {
        case .none: return true
        case .some(let s): return s.isEmpty
        }
    }
}

private extension NodeFontWeight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

private extension NodeTextAlignment {
    var uiAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}
