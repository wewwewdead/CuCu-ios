import SwiftUI

// MARK: - Adaptive width-class system
//
// CuCu's design system was originally hex colors + font ramps with no
// notion of screen size. Every layout invented its own magic numbers
// (220-pt inspector cards, 320-pt picker headers, 240-pt CTA buttons),
// which crowded on iPhone SE / iPhone 15 and floated awkwardly on iPad.
//
// `CucuWidthClass` is a four-way bucket — `compact` / `regular` /
// `expanded` / `iPad` — derived from the *available width* of the
// hosting view (not from `UITraitCollection.horizontalSizeClass`,
// which only distinguishes phone vs iPad and lumps SE in with Pro
// Max). Surfaces consult the bucket through the SwiftUI environment
// and branch their padding, max-widths, and column counts on it.
//
// One root view per scene calls `.cucuWidthClass()` (typically a
// modifier on the navigation root); its `GeometryReader` measures the
// actual width and writes the bucket into the environment so children
// can read `@Environment(\.cucuWidthClass)` without each one having
// to take its own GeometryReader.

/// Width-class bucket for adaptive layout. Backed by absolute width
/// breakpoints rather than `horizontalSizeClass` so we can tell SE
/// apart from a Pro Max — both are `.compact` in UIKit's eyes.
enum CucuWidthClass: Sendable, Equatable {
    /// iPhone SE-class devices (≤ ~380 pt). Tightest layouts: single-
    /// card inspector, abbreviated CTAs, minimum padding.
    case compact
    /// Standard iPhones (iPhone 13/14/15/17 — ~390-410 pt). Default
    /// layout: ~1.5 cards visible, full CTAs, comfortable padding.
    case regular
    /// Plus / Pro Max (~410-700 pt). Two-card layouts, generous
    /// padding, more breathing room.
    case expanded
    /// iPad and larger (≥ ~700 pt). Multi-column grids, capped
    /// content widths, centered canvas.
    case iPad

    /// Derive the bucket from a measured width (typically the
    /// scene's available width, not the safe-area-insetted content
    /// width — read as far up the hierarchy as you can).
    static func from(width: CGFloat) -> CucuWidthClass {
        switch width {
        case ..<380:    return .compact
        case ..<410:    return .regular
        case ..<700:    return .expanded
        default:        return .iPad
        }
    }

    var isPhone: Bool { self != .iPad }
    var isCompact: Bool { self == .compact }
    var isAtLeastExpanded: Bool { self == .expanded || self == .iPad }

    /// Multiplier applied to the inspector's per-card design widths
    /// (the existing `220 / 200 / 180 / 170 / 150` widths in
    /// `PropertyInspectorView.cardShell`). Keeps the relative
    /// hierarchy (slider stays wider than color picker) but shrinks
    /// the whole set on SE so 1.4 cards still fit on screen, and
    /// grows it on Pro Max / iPad so users see more at a glance.
    var inspectorCardScale: CGFloat {
        switch self {
        case .compact:  return 0.86
        case .regular:  return 1.00
        case .expanded: return 1.08
        case .iPad:     return 1.25
        }
    }
}

// MARK: - Spacing scale
//
// Tokens for padding / inter-element gaps, scaled per width class.
// Surfaces should consult these instead of hard-coding 14 / 18 / 22.

enum CucuSpacing {
    /// Outer page-edge padding (left/right of the screen content).
    static func screenInset(_ wc: CucuWidthClass) -> CGFloat {
        switch wc {
        case .compact:  return 14
        case .regular:  return 18
        case .expanded: return 22
        case .iPad:     return 32
        }
    }

    /// Gap between sibling cards / sections within a row.
    static func gap(_ wc: CucuWidthClass) -> CGFloat {
        switch wc {
        case .compact:  return 8
        case .regular:  return 10
        case .expanded: return 12
        case .iPad:     return 14
        }
    }

    /// Vertical gap between major content blocks (header → body → footer).
    static func sectionGap(_ wc: CucuWidthClass) -> CGFloat {
        switch wc {
        case .compact:  return 14
        case .regular:  return 18
        case .expanded: return 22
        case .iPad:     return 28
        }
    }
}

// MARK: - Layout caps
//
// On wide devices (iPad, large windows) a profile canvas or modal
// shouldn't expand to fill the entire width — it stops being a phone
// canvas and starts being an awkward stretched form. These caps let
// surfaces clamp their own content width while the surrounding chrome
// (scroll view, sheet) stays edge-to-edge.

enum CucuLayoutCap {
    /// Comfortable max width for a phone-shaped canvas being shown on
    /// an iPad. Roughly iPhone 14 Plus width (428pt) so the canvas
    /// reads as "phone-sized" rather than letterboxed.
    static let canvasOnIPad: CGFloat = 540

    /// Max usable width for picker / sheet content. On iPad the cards
    /// themselves can stay phone-sized but the grid uses multiple
    /// columns inside this cap rather than running to the screen
    /// edge. Wider than `canvasOnIPad` because the picker is a
    /// browsing surface, not a single canvas.
    static let modalContent: CGFloat = 920
}

// MARK: - SwiftUI environment plumbing

private struct CucuWidthClassKey: EnvironmentKey {
    /// Default bucket if no parent has measured yet — assume regular
    /// iPhone so compile-time previews and untested surfaces look
    /// like a normal phone instead of an iPad or SE.
    static let defaultValue: CucuWidthClass = .regular
}

extension EnvironmentValues {
    /// Adaptive width class for the current scene. Surfaces read this
    /// to pick the right padding / card count / abbreviation, e.g.
    /// `@Environment(\.cucuWidthClass) private var widthClass`.
    var cucuWidthClass: CucuWidthClass {
        get { self[CucuWidthClassKey.self] }
        set { self[CucuWidthClassKey.self] = newValue }
    }
}

extension View {
    /// Measure the receiver's width once and broadcast the resulting
    /// `CucuWidthClass` to children via the environment. Apply this
    /// near the top of a screen (e.g. on the root `NavigationStack`
    /// or sheet body) — applying it deeper in the hierarchy still
    /// works, but you'll measure a smaller available width and may
    /// wrongly bucket a wide screen as `.compact`.
    func cucuWidthClass() -> some View {
        modifier(CucuWidthClassReader())
    }
}

private struct CucuWidthClassReader: ViewModifier {
    @State private var widthClass: CucuWidthClass = .regular

    func body(content: Content) -> some View {
        content
            .environment(\.cucuWidthClass, widthClass)
            .background(
                GeometryReader { geo in
                    // Background is the cleanest place to host a
                    // GeometryReader without messing with the
                    // content's own intrinsic sizing — it always
                    // matches the content's frame, never expands or
                    // contracts the layout.
                    Color.clear
                        .onAppear { widthClass = CucuWidthClass.from(width: geo.size.width) }
                        .onChange(of: geo.size.width) { _, newWidth in
                            let next = CucuWidthClass.from(width: newWidth)
                            if next != widthClass { widthClass = next }
                        }
                }
            )
    }
}
