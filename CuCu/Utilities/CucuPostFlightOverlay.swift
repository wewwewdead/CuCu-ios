import SwiftUI

/// Top-of-tree overlay that renders the post-submission flight.
///
/// Mounted by `RootView` so it sits above every tab and pushes
/// inside those tabs. Doesn't render at all when the coordinator
/// is `.idle`, so it's free to leave in the tree permanently. When
/// a flight is active, it composites four layers:
///
///   1. **Ghost card** — a printed-page facsimile of the post that
///      travels along a parabolic arc from the bottom of the screen
///      (where the dismissing compose sheet was) up to the feed's
///      top-of-list anchor. Scales 0.6 → 1.0 → 0.0 across the run,
///      with a soft rotation oscillation so it reads as a paper
///      tossed in the air rather than a sliding sticker.
///
///   2. **Dotted ink trail** — eight printer-dot specks left
///      behind as the card flies. Sampled along the bezier path so
///      the trail bends with the arc instead of being a straight
///      line. Each dot fades on a staggered timer.
///
///   3. **Fleuron particle burst** — six glyphs (`✦ ❦ ✺`) that
///      spray outward from the takeoff point. Pulled from CuCu's
///      design system rather than generic confetti so the moment
///      stays in voice.
///
///   4. **Paper-stamp ring** — a single ring that expands from the
///      landing point and fades out, suggesting the card was
///      pressed into the page like a printer's mark.
struct CucuPostFlightOverlay: View {
    @Environment(CucuPostFlightCoordinator.self) private var coordinator

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if coordinator.phase != .idle, let post = coordinator.post {
                    let geometry = FlightGeometry(
                        sourceX: coordinator.sourceX,
                        destination: coordinator.destination,
                        canvas: proxy.size
                    )
                    flightContents(post: post, geometry: geometry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Composition

    @ViewBuilder
    private func flightContents(post: Post, geometry: FlightGeometry) -> some View {
        let phase = coordinator.phase
        let progress = phase.progress
        let position = geometry.point(at: progress)
        let scale = phase.cardScale
        let rotation = phase.cardRotation
        let opacity = phase.cardOpacity

        // Trail dots — drawn underneath the ghost so the card can
        // visually "lay" them down behind itself. Each dot is a
        // sample along the bezier with a tiny per-dot offset so they
        // don't overlap on a tight curve. The trail only paints
        // during the flying phase; landing/lifting suppress it so
        // there isn't a stale string of dots at rest.
        if phase == .flying {
            ForEach(0..<8, id: \.self) { i in
                let trailProgress = max(0, progress - Double(i) * 0.08)
                let trailPoint = geometry.point(at: trailProgress)
                Circle()
                    .fill(Color.cucuInk.opacity(0.22))
                    .frame(width: 4, height: 4)
                    .position(trailPoint)
                    .opacity(1.0 - Double(i) / 8.0)
                    .blur(radius: 0.4)
                    .transition(.opacity)
            }
        }

        // Takeoff fleurons — burst outward from the source the
        // moment the lift kicks in, decay through flying, gone by
        // landing. Six glyphs at evenly-spaced angles so it reads
        // as a controlled scatter rather than a chaotic puff.
        if phase == .lifting || phase == .flying {
            FleuronBurst(
                origin: geometry.takeoffPoint,
                progress: phase == .lifting ? 0.5 : 1.0
            )
        }

        // Landing stamp — paper-pressed-onto-page ring. Expands and
        // fades during the landing phase, then disappears.
        if phase == .landing || phase == .settling {
            PaperStampRing(
                origin: coordinator.destination,
                progress: phase == .landing ? 0.6 : 1.0
            )
        }

        // The ghost itself, on top of the trail and fleurons.
        GhostPostCard(post: post)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .position(position)
            .shadow(color: Color.cucuInk.opacity(0.18), radius: 12, x: 0, y: 6)
            .animation(
                phase == .flying
                    ? .timingCurve(0.42, 0.0, 0.32, 1.0, duration: 0.52)
                    : .spring(response: 0.34, dampingFraction: 0.7),
                value: phase
            )
    }
}

// MARK: - Phase → animation parameters

private extension CucuPostFlightCoordinator.Phase {
    /// 0.0 = source, 1.0 = destination. Drives the bezier sampler.
    var progress: Double {
        switch self {
        case .idle, .lifting: return 0
        case .flying: return 1
        case .landing, .settling: return 1
        }
    }

    /// Ghost card scale across phases. Anticipation pop on lift,
    /// shrinks through flight (perspective), collapses on landing.
    var cardScale: CGFloat {
        switch self {
        case .idle: return 0.6
        case .lifting: return 1.0
        case .flying: return 0.62
        case .landing: return 0.18
        case .settling: return 0
        }
    }

    /// Slight rotation oscillation across the flight so the card
    /// reads as physically tossed. Small angles only — overdoing
    /// it would make the post text unreadable mid-flight.
    var cardRotation: Double {
        switch self {
        case .idle, .lifting: return -3
        case .flying: return 6
        case .landing, .settling: return -1
        }
    }

    var cardOpacity: Double {
        switch self {
        case .idle: return 0
        case .lifting, .flying: return 1
        case .landing: return 0.55
        case .settling: return 0
        }
    }
}

// MARK: - Bezier path geometry

/// Encapsulates the parabolic arc the ghost travels. The path is a
/// quadratic bezier: source → control (lifted high above the
/// midpoint) → destination. Sampling `point(at:)` with t∈[0,1]
/// returns interpolated positions; the lift on the control point
/// is what gives the flight its "tossed upward then settles" feel.
private struct FlightGeometry {
    let source: CGPoint
    let control: CGPoint
    let destination: CGPoint

    /// Point the ghost emerges from on lift — same x as the submit
    /// button, y just below where the dismissing sheet ends.
    var takeoffPoint: CGPoint { source }

    init(sourceX: CGFloat, destination: CGPoint, canvas: CGSize) {
        // Source y sits a touch above the bottom safe-area so the
        // ghost emerges from where the sheet was, not from the
        // home-indicator strip itself.
        let src = CGPoint(x: sourceX, y: canvas.height - 110)

        // Destination falls back to roughly the top of the feed
        // column when nothing is registered. This shouldn't be hit
        // in normal flow but keeps the overlay safe.
        let dst = destination == .zero
            ? CGPoint(x: canvas.width / 2, y: 180)
            : destination

        // Control point: midpoint x, lifted ~140pt above the
        // higher of source/destination y. This is what makes the
        // flight visibly arc rather than slide diagonally.
        let midX = (src.x + dst.x) / 2
        let topY = min(src.y, dst.y)
        let lift: CGFloat = 140
        let ctrl = CGPoint(x: midX, y: topY - lift)

        self.source = src
        self.control = ctrl
        self.destination = dst
    }

    /// Quadratic bezier sample. Standard formula —
    /// (1-t)²·P₀ + 2(1-t)t·P₁ + t²·P₂.
    func point(at t: Double) -> CGPoint {
        let oneMinusT = 1.0 - t
        let x = oneMinusT * oneMinusT * source.x
              + 2 * oneMinusT * t * control.x
              + t * t * destination.x
        let y = oneMinusT * oneMinusT * source.y
              + 2 * oneMinusT * t * control.y
              + t * t * destination.y
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Ghost card

/// The flying card. Mirrors the feed row's cream paper + ink rule
/// + serif type so the user recognises it as "their post."
/// Deliberately compact — width capped so it reads as a scrap of
/// paper in flight, not a full-bleed card.
private struct GhostPostCard: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.cucuRose)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Text(initialLetter)
                            .font(.cucuSerif(10, weight: .bold))
                            .foregroundStyle(Color.cucuBurgundy)
                    )
                Text("@\(post.authorUsername)")
                    .font(.cucuSerif(11, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Spacer(minLength: 0)
                Text("✦")
                    .font(.cucuSerif(10))
                    .foregroundStyle(Color.cucuInkFaded)
            }
            Text(bodyExcerpt)
                .font(.cucuSerif(13, weight: .regular))
                .foregroundStyle(Color.cucuInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cucuCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.32), lineWidth: 1)
        )
        // Inner inset hairline echoes the masthead's printed-page
        // detail so the ghost reads as the same publication.
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.cucuInk.opacity(0.08), lineWidth: 0.5)
                .padding(3)
        )
    }

    private var initialLetter: String {
        String(post.authorUsername.prefix(1)).uppercased()
    }

    private var bodyExcerpt: String {
        let trimmed = post.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 80)
        return String(trimmed[..<idx]) + "…"
    }
}

// MARK: - Fleuron burst

/// Six glyphs spraying outward from the takeoff point. Each glyph
/// has its own angle, distance, and fade timing so the burst feels
/// hand-set rather than identical-particle-spam.
private struct FleuronBurst: View {
    let origin: CGPoint
    /// 0 = just-spawned (clustered at origin), 1 = fully scattered
    /// and fading out. Driven by phase, not animated internally —
    /// the parent's phase change is what triggers SwiftUI's
    /// implicit animation across these properties.
    let progress: Double

    private static let glyphs: [String] = ["✦", "❦", "✺", "✦", "❦", "✺"]
    private static let angles: [Double] = [
        -100, -135, -75, -45, -160, -20
    ]

    var body: some View {
        ZStack {
            ForEach(0..<Self.glyphs.count, id: \.self) { i in
                let angle = Self.angles[i] * .pi / 180
                let distance = 60.0 + Double(i % 3) * 18.0
                let dx = cos(angle) * distance * progress
                let dy = sin(angle) * distance * progress
                Text(Self.glyphs[i])
                    .font(.cucuSerif(14 + CGFloat(i % 3) * 2, weight: .regular))
                    .foregroundStyle(
                        i.isMultiple(of: 2) ? Color.cucuBurgundy : Color.cucuInkSoft
                    )
                    .opacity(1.0 - progress * 0.85)
                    .scaleEffect(0.4 + progress * 0.9)
                    .rotationEffect(.degrees(progress * Double(i % 2 == 0 ? 80 : -60)))
                    .position(x: origin.x + dx, y: origin.y + dy)
            }
        }
        .animation(.timingCurve(0.16, 0.84, 0.44, 1.0, duration: 0.55), value: progress)
    }
}

// MARK: - Row landing transition

/// Insertion modifier the feed swaps in for the freshly-landed
/// post. The standard insertion would slide the row down from the
/// top edge — fine for a backend push, but it competes with the
/// ghost dissolving in place. This one starts the row at 0.5 scale
/// (anchored to the top so the column below doesn't visibly jump)
/// with zero opacity, and the parent `withAnimation` springs it up
/// to identity. Pair with the `pulsingPostId` scale-effect on the
/// host row for the overshoot pulse beat.
struct CucuPostLandingInsertion: ViewModifier {
    /// 0 = active (invisible/small), 1 = identity (full row).
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.45 + progress * 0.55, anchor: .top)
            .opacity(progress)
            .blur(radius: (1.0 - progress) * 4)
    }
}

extension AnyTransition {
    /// Used by the post feed for the row that the flight ghost
    /// dissolved into. Replaces the standard top-edge slide so the
    /// row reads as having *materialised* at the landing point
    /// rather than scrolled in from above.
    static var cucuPostLanding: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: CucuPostLandingInsertion(progress: 0),
                identity: CucuPostLandingInsertion(progress: 1)
            ),
            removal: .modifier(
                active: CucuPostPopRemoval(progress: 1),
                identity: CucuPostPopRemoval(progress: 0)
            )
        )
    }
}

// MARK: - Paper stamp landing ring

/// The "card pressed into page" mark. A ring stroke that expands
/// outward from the destination and fades as it goes. Subtle
/// secondary glyph (`❦`) sits at the centre for one beat, gone
/// before the ring finishes — a stamped-fleuron impression rather
/// than persistent decoration.
private struct PaperStampRing: View {
    let origin: CGPoint
    let progress: Double

    var body: some View {
        ZStack {
            // Soft rose halo behind the ring — warms the landing
            // moment so it reads as a victory beat without going
            // bright. Fades completely by the end of progress.
            Circle()
                .fill(Color.cucuRose.opacity(0.45 * (1.0 - progress)))
                .frame(width: 72 + 80 * progress, height: 72 + 80 * progress)
                .blur(radius: 14)
                .position(origin)

            Circle()
                .strokeBorder(Color.cucuInk.opacity(0.55 * (1.0 - progress)), lineWidth: 1.2)
                .frame(width: 28 + 90 * progress, height: 28 + 90 * progress)
                .position(origin)

            // Tighter inner ring that lags the outer by a fraction
            // — gives the stamp a double-impression feel.
            Circle()
                .strokeBorder(Color.cucuInk.opacity(0.35 * (1.0 - progress)), lineWidth: 0.8)
                .frame(
                    width: 14 + 60 * progress,
                    height: 14 + 60 * progress
                )
                .position(origin)

            Text("❦")
                .font(.cucuSerif(20, weight: .regular))
                .foregroundStyle(Color.cucuBurgundy.opacity(0.7 * (1.0 - progress * 1.4)))
                .position(origin)
        }
        .animation(.timingCurve(0.2, 0.7, 0.4, 1.0, duration: 0.5), value: progress)
    }
}
