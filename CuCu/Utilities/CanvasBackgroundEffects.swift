import SwiftUI
import UIKit

// MARK: - Paper grain
//
// A subtle fractal-noise overlay rendered once at launch and tiled
// across every canvas. Lives above the bg color / image and below the
// nodes. Paints at ~22% opacity in `.multiply` blend so it darkens
// and textures whatever it overlays without changing the page hue.
//
// The original mockup ships this as an SVG `feTurbulence` filter
// (canvas.jsx:277). On iOS we generate the equivalent once via Core
// Image and cache the resulting UIImage — re-rendering on every
// frame would be wasteful and the image is small enough to keep
// resident.

enum CucuPaperGrain {
    /// UIKit-friendly tile image. Cached lazily on first access.
    /// Re-generation across launches is fine — the seed isn't
    /// stable, but the grain is supposed to read as random texture
    /// rather than a recognisable pattern, so users won't notice.
    static let uiTile: UIImage = {
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Stipple the surface with small dark dots at varied
            // alpha. Cheap, resolution-independent, and reads like
            // newsprint when tiled at 22% multiply.
            let cg = ctx.cgContext
            cg.setBlendMode(.normal)
            for _ in 0..<3600 {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let r = CGFloat.random(in: 0.25...0.9)
                let a = CGFloat.random(in: 0.10...0.35)
                cg.setFillColor(UIColor(white: 0.06, alpha: a).cgColor)
                cg.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
            }
        }
        return img.resizableImage(withCapInsets: .zero, resizingMode: .tile)
    }()

    /// SwiftUI-side reuses the same tile so previews and the
    /// rendered canvas don't drift apart.
    static let tile: Image = Image(uiImage: uiTile)
}

/// SwiftUI overlay that draws the paper grain edge-to-edge in
/// `.multiply` blend mode at 22% opacity. Pair with `.allowsHitTesting(false)`
/// so it never intercepts node taps.
struct CucuPaperGrainOverlay: View {
    var opacity: Double = 0.22
    var body: some View {
        CucuPaperGrain.tile
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }
}

// MARK: - Background pattern presets
//
// Mirrors `themes.jsx` `BG_IMAGES`: five tile patterns + three
// gradient washes. Drawn above the bg color / image and below the
// nodes. Each case carries its own renderer so the call site is
// `pattern.overlay(palette: …)` — no big switch lives in the canvas.

enum CanvasBackgroundPattern: String, CaseIterable, Codable, Hashable {
    case paperGrid
    case dots
    case hearts
    case sparkles
    case checkers
    case sunset
    case meadow
    case hazyDusk

    /// Decodes a possibly-nil string from `ProfileTheme.backgroundPatternKey`
    /// to the matching case. Unknown keys (older drafts, future cases on
    /// older binaries) decode to `nil` rather than crashing.
    init?(key: String?) {
        guard let key, !key.isEmpty else { return nil }
        self.init(rawValue: key)
    }

    /// User-facing label for the picker.
    var label: String {
        switch self {
        case .paperGrid: return "Grid"
        case .dots:      return "Dots"
        case .hearts:    return "Hearts"
        case .sparkles:  return "Sparkles"
        case .checkers:  return "Checkers"
        case .sunset:    return "Sunset"
        case .meadow:    return "Meadow"
        case .hazyDusk:  return "Haze"
        }
    }

    /// One-line hint shown beneath the tile in the picker.
    var hint: String {
        switch self {
        case .paperGrid: return "subtle paper grid"
        case .dots:      return "polka dots"
        case .hearts:    return "tiled hearts"
        case .sparkles:  return "tiled sparkles"
        case .checkers:  return "soft checker"
        case .sunset:    return "warm wash"
        case .meadow:    return "green ground"
        case .hazyDusk:  return "rose haze"
        }
    }

    /// True for tiled patterns (paperGrid / dots / hearts / sparkles
    /// / checkers); false for the gradient washes which are painted
    /// edge-to-edge as a single drawing.
    var isTiled: Bool {
        switch self {
        case .paperGrid, .dots, .hearts, .sparkles, .checkers: return true
        case .sunset, .meadow, .hazyDusk:                       return false
        }
    }

    /// UIKit-side tile image for the canvas. Returns the same
    /// precomputed UIImage the SwiftUI overlay uses, or nil for
    /// gradient-wash cases.
    var tileImage: UIImage? {
        guard isTiled else { return nil }
        return CucuTilePatternCache.shared.image(for: self)
    }

    /// UIKit-side gradient layer for the canvas. Returns nil for
    /// tile patterns. Caller is responsible for setting `frame`.
    func makeGradientLayer() -> CAGradientLayer? {
        switch self {
        case .paperGrid, .dots, .hearts, .sparkles, .checkers:
            return nil
        case .sunset:
            let g = CAGradientLayer()
            g.colors = [
                UIColor(red: 1.0,  green: 0.72, blue: 0.55, alpha: 0.55).cgColor,
                UIColor(red: 1.0,  green: 0.89, blue: 0.78, alpha: 0.0).cgColor,
                UIColor(red: 0.72, green: 0.55, blue: 0.78, alpha: 0.35).cgColor,
            ]
            g.locations = [0.0, 0.55, 1.0]
            g.startPoint = CGPoint(x: 0.5, y: 0.0)
            g.endPoint = CGPoint(x: 0.5, y: 1.0)
            return g
        case .meadow:
            let g = CAGradientLayer()
            g.type = .radial
            g.colors = [
                UIColor(red: 0.31, green: 0.55, blue: 0.35, alpha: 0.30).cgColor,
                UIColor(red: 0.31, green: 0.55, blue: 0.35, alpha: 0.0).cgColor,
            ]
            g.locations = [0.0, 1.0]
            // Centered at bottom; CAGradientLayer's radial extends
            // to the corner farthest from `startPoint` toward
            // `endPoint`. Setting endPoint to a corner lets the
            // gradient cover most of the page.
            g.startPoint = CGPoint(x: 0.5, y: 1.0)
            g.endPoint = CGPoint(x: 1.0, y: 0.0)
            return g
        case .hazyDusk:
            let g = CAGradientLayer()
            g.colors = [
                UIColor(red: 0.96, green: 0.65, blue: 0.71, alpha: 0.18).cgColor,
                UIColor(red: 0.13, green: 0.12, blue: 0.17, alpha: 0.0).cgColor,
            ]
            g.locations = [0.0, 0.6]
            g.startPoint = CGPoint(x: 0.5, y: 0.0)
            g.endPoint = CGPoint(x: 0.5, y: 1.0)
            return g
        }
    }

    /// Renders the pattern as a SwiftUI view. Defers tile patterns
    /// to their precomputed image and gradient washes to the
    /// matching SwiftUI gradient.
    @ViewBuilder
    func overlay() -> some View {
        switch self {
        case .paperGrid, .dots, .hearts, .sparkles, .checkers:
            CucuTilePatternView(pattern: self)
        case .sunset:
            LinearGradient(
                stops: [
                    .init(color: Color(red: 1.0, green: 0.72, blue: 0.55, opacity: 0.55), location: 0.0),
                    .init(color: Color(red: 1.0, green: 0.89, blue: 0.78, opacity: 0.0),  location: 0.55),
                    .init(color: Color(red: 0.72, green: 0.55, blue: 0.78, opacity: 0.35), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        case .meadow:
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.31, green: 0.55, blue: 0.35, opacity: 0.30),
                    Color(red: 0.31, green: 0.55, blue: 0.35, opacity: 0.0),
                ]),
                center: UnitPoint(x: 0.5, y: 1.0),
                startRadius: 0,
                endRadius: 480
            )
            .allowsHitTesting(false)
        case .hazyDusk:
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.96, green: 0.65, blue: 0.71, opacity: 0.18), location: 0.0),
                    .init(color: Color(red: 0.13, green: 0.12, blue: 0.17, opacity: 0.0),  location: 0.6),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Tile pattern renderer

/// Renders a tiled pattern from a precomputed `UIImage`. Each
/// pattern is generated once and cached on first use, then drawn
/// edge-to-edge with `.tile` resizing. Hue / opacity are baked into
/// the cached image so callers don't need to know per-pattern
/// recipes.
struct CucuTilePatternView: View {
    let pattern: CanvasBackgroundPattern

    var body: some View {
        Image(uiImage: CucuTilePatternCache.shared.image(for: pattern))
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

private final class CucuTilePatternCache {
    static let shared = CucuTilePatternCache()
    private var cache: [CanvasBackgroundPattern: UIImage] = [:]
    private let lock = NSLock()

    func image(for pattern: CanvasBackgroundPattern) -> UIImage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        let img = render(pattern)
        cache[pattern] = img
        return img
    }

    private func render(_ pattern: CanvasBackgroundPattern) -> UIImage {
        switch pattern {
        case .paperGrid: return renderPaperGrid()
        case .dots:      return renderDots()
        case .hearts:    return renderHearts()
        case .sparkles:  return renderSparkles()
        case .checkers:  return renderCheckers()
        case .sunset, .meadow, .hazyDusk:
            // Gradient washes don't tile — the overlay() switch
            // above paints them directly. This branch never runs
            // in practice; return a clear pixel as a no-op fallback.
            return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        }
    }

    // ── Tile renderers ──────────────────────────────────────────

    /// 40×40 cross-hatch grid at 7% black, mirroring
    /// themes.jsx's `paperGrid` SVG.
    private func renderPaperGrid() -> UIImage {
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.black.withAlphaComponent(0.07).cgColor)
            cg.setLineWidth(1)
            cg.move(to: CGPoint(x: 0, y: 0.5))
            cg.addLine(to: CGPoint(x: size.width, y: 0.5))
            cg.move(to: CGPoint(x: 0.5, y: 0))
            cg.addLine(to: CGPoint(x: 0.5, y: size.height))
            cg.strokePath()
        }
    }

    /// 22×22 polka dot at 18% black.
    private func renderDots() -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            cg.fillEllipse(in: CGRect(x: 0.6, y: 0.6, width: 2.8, height: 2.8))
        }
    }

    /// 32×32 heart in cherry @ 22%.
    private func renderHearts() -> UIImage {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.72, green: 0.20, blue: 0.29, alpha: 0.22).cgColor)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 16, y: 24))
            path.addCurve(
                to: CGPoint(x: 10, y: 9),
                controlPoint1: CGPoint(x: 8, y: 18),
                controlPoint2: CGPoint(x: 6, y: 12)
            )
            path.addCurve(
                to: CGPoint(x: 16, y: 12),
                controlPoint1: CGPoint(x: 13, y: 7),
                controlPoint2: CGPoint(x: 16, y: 9)
            )
            path.addCurve(
                to: CGPoint(x: 22, y: 9),
                controlPoint1: CGPoint(x: 16, y: 9),
                controlPoint2: CGPoint(x: 19, y: 7)
            )
            path.addCurve(
                to: CGPoint(x: 16, y: 24),
                controlPoint1: CGPoint(x: 26, y: 12),
                controlPoint2: CGPoint(x: 24, y: 18)
            )
            path.close()
            cg.addPath(path.cgPath)
            cg.fillPath()
        }
    }

    /// 40×40 with two four-point sparkles in cherry @ 28%.
    private func renderSparkles() -> UIImage {
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.72, green: 0.20, blue: 0.29, alpha: 0.28).cgColor)
            drawSparkle(into: cg, center: CGPoint(x: 9, y: 9), size: 5)
            drawSparkle(into: cg, center: CGPoint(x: 30, y: 27), size: 3)
        }
    }

    /// 24×24 soft checker at 5% black, mirroring the conic gradient
    /// in the source CSS.
    private func renderCheckers() -> UIImage {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.black.withAlphaComponent(0.05).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            cg.fill(CGRect(x: 12, y: 12, width: 12, height: 12))
        }
    }

    /// Fills a 4-point sparkle (diamond + perpendicular diamond)
    /// centered at `center`. Cheap analog of an SF-Symbol sparkle.
    private func drawSparkle(into cg: CGContext, center: CGPoint, size: CGFloat) {
        let path = UIBezierPath()
        // Vertical diamond
        path.move(to: CGPoint(x: center.x, y: center.y - size))
        path.addLine(to: CGPoint(x: center.x + size * 0.35, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + size))
        path.addLine(to: CGPoint(x: center.x - size * 0.35, y: center.y))
        path.close()
        // Horizontal diamond
        path.move(to: CGPoint(x: center.x - size, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y - size * 0.35))
        path.addLine(to: CGPoint(x: center.x + size, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + size * 0.35))
        path.close()
        cg.addPath(path.cgPath)
        cg.fillPath()
    }
}
