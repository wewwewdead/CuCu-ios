import SwiftUI
import Observation

/// "Post flies to the feed" choreography model.
///
/// Centralises the multi-phase delight animation that runs when a
/// user submits a new top-level post. The compose sheet calls
/// `launch(...)` at success; the overlay (mounted near the app
/// root) reads `phase`, `post`, `sourceX`, `destination` and renders
/// the ghost card / particles / landing stamp accordingly. The feed
/// observes `landedPostId` to defer its own row prepend until the
/// ghost reaches the destination, so the row appears to "be" the
/// ghost rather than slide in independently.
///
/// Why one coordinator instead of per-call closures: the animation
/// crosses three views (compose sheet → app-root overlay → feed
/// row) and outlives the sheet's dismiss. A shared @Observable
/// model lets each surface read the same phase without prop-drilling
/// callbacks through environment injections that would have to know
/// about each other.
@MainActor
@Observable
final class CucuPostFlightCoordinator {
    enum Phase: Equatable {
        /// No flight in progress — overlay renders nothing.
        case idle
        /// Ghost card has appeared at the source position and is
        /// scaling up with anticipation. Sheet is mid-dismiss.
        case lifting
        /// Ghost is travelling along the parabolic arc toward
        /// the feed's destination point.
        case flying
        /// Ghost is at the destination, shrinking into the new
        /// row's slot while the paper-stamp ring expands outward
        /// and fleurons scatter.
        case landing
        /// Feed has prepended the row; we hold briefly so the
        /// row's spring overshoot reads before resetting.
        case settling
    }

    private(set) var phase: Phase = .idle

    /// The post being delivered. Mirrored into the ghost card so
    /// the user sees their own author handle + body excerpt
    /// flying through the air — not a generic "thing landed."
    private(set) var post: Post?

    /// Window-space x of where the ghost emerges. The compose
    /// sheet captures the submit-button center on tap. y is
    /// implicit: bottom of the screen (where the dismissing sheet
    /// just was), so the ghost reads as being "thrown" up from
    /// the closing sheet rather than appearing in mid-air.
    private(set) var sourceX: CGFloat = 0

    /// Window-space landing target — the top of the feed list,
    /// just under the masthead. Registered by `PostFeedView` via
    /// `registerDestination(_:)` whenever its frame measures.
    /// Falls back to a sensible default when no feed is mounted
    /// (rare — the launch always originates from the feed today,
    /// but this keeps the overlay safe if that ever changes).
    private(set) var destination: CGPoint = CGPoint(x: 0, y: 200)

    /// Set to the post id at the moment the ghost reaches the
    /// destination. The feed observes this and runs `vm.prepend`
    /// inside its own bouncy spring so the row spring-pops into
    /// place exactly when the ghost dissolves into it.
    private(set) var landedPostId: String?

    /// Wall-clock instant the row should begin its spring-overshoot
    /// pulse. Different from `landedPostId` (which gates the
    /// initial insertion) — this fires one tick later so the row
    /// has a chance to settle before being scaled. Read by the
    /// feed via the `pulsingPostId` mirror.
    private(set) var pulsingPostId: String?

    /// Active for the duration of the flight so call sites can
    /// suppress competing transitions (e.g. the feed's standard
    /// top-edge slide insertion would otherwise race the ghost
    /// landing). Convenience accessor — `phase != .idle`.
    var isActive: Bool { phase != .idle }

    // MARK: - Mutators

    /// Called by `PostFeedView` once it has measured the top of
    /// its column in window coordinates. Idempotent — repeated
    /// calls just refresh the target so a tab swap that re-mounts
    /// the feed doesn't strand the destination at a stale point.
    func registerDestination(_ point: CGPoint) {
        destination = point
    }

    /// Compose-sheet entry point. Stages the post, locks the
    /// source x, and drives the phase transitions on a Task so
    /// the caller can `dismiss()` immediately and not block on
    /// the animation. Phase timings are deliberately conservative
    /// — Duolingo-grade delight wants the user to *see* the card
    /// travel, not flicker through. Total run is ~1.25s end to
    /// end; tune the sleeps below to taste.
    func launch(post: Post, sourceX: CGFloat) {
        guard phase == .idle else { return }
        self.post = post
        self.sourceX = sourceX
        self.landedPostId = nil
        self.pulsingPostId = nil

        Task { @MainActor in
            // Hold while the sheet finishes its dismissal so the
            // ghost emerges into a clean canvas, not an overlapping
            // dismissing sheet. Standard iOS sheet dismiss is ~280ms.
            try? await Task.sleep(nanoseconds: 260_000_000)

            self.phase = .lifting
            CucuHaptics.soft()
            try? await Task.sleep(nanoseconds: 180_000_000)

            self.phase = .flying
            try? await Task.sleep(nanoseconds: 520_000_000)

            self.phase = .landing
            CucuHaptics.success()
            // Tell the feed to materialise the row. The view will
            // observe this and run its own spring.
            self.landedPostId = post.id
            try? await Task.sleep(nanoseconds: 180_000_000)

            // One tick later, ask the row to pulse. Two-step so the
            // insertion's own spring isn't fighting the pulse spring.
            self.pulsingPostId = post.id
            self.phase = .settling
            try? await Task.sleep(nanoseconds: 360_000_000)

            // Reset everything. The ghost fades the moment phase
            // returns to .idle (overlay watches for it).
            self.phase = .idle
            self.post = nil
            self.landedPostId = nil
            self.pulsingPostId = nil
        }
    }
}

// Injected via `.environment(_:)` from the App scene — matches the
// AuthViewModel pattern already in use. Consumers read it as
// `@Environment(CucuPostFlightCoordinator.self)`. No fallback is
// provided; previews that exercise the compose sheet should pass
// their own `CucuPostFlightCoordinator()` so the launch is a no-op.
