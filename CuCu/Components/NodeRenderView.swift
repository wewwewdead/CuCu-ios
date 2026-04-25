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
        frame = node.frame.cgRect
        alpha = CGFloat(node.opacity)

        if let bg = node.style.backgroundColorHex {
            backgroundColor = uiColor(hex: bg)
        } else {
            backgroundColor = .clear
        }

        cachedClipShape = node.style.clipShape ?? .rectangle
        cachedCornerRadius = CGFloat(node.style.cornerRadius)
        applyClipping()

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
    }

    private func applyClipping() {
        switch cachedClipShape {
        case .rectangle:
            layer.cornerRadius = cachedCornerRadius
        case .circle:
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }
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
