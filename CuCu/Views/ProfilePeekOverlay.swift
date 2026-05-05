import SwiftUI

/// Long-press sneak peek summoned from a banner card in Explore.
/// Refined-minimalist surface: theme-aware card (snow / bone /
/// midnight / coal all read through `chrome.theme`), bold Lexend
/// labels, hairline strokes, soft black backdrop. Drops the
/// editorial sticker chrome (PEEK / №01 stamp, sparkle burst,
/// rotating fleuron, cherry-bullet captions, ✦ flourishes) — the
/// peek now matches the rest of the social chrome.
///
/// Choreography preserved (Duolingo-school spring):
///   1. **Press start** — host sets `peekTarget`, mounting this view.
///   2. **Mount** — backdrop fades to 0.55 over 180ms while the card
///      scales `0.5 → 1.08 → 0.97 → 1.0` on a punchy spring
///      (`response 0.42, damping 0.62`).
///   3. **Settled** — `CucuHaptics.duplicate()` lands as the
///      overshoot peaks so haptic and visual punch coincide.
///   4. **Dismiss** — tap backdrop or close glyph; card squishes to
///      `0.94` and fades over 220ms while the backdrop fades out.
///
/// Tap the card itself (not the backdrop) and the host gets the
/// `onOpen` callback, which routes through the existing push to
/// the full `PublishedProfileView`.
struct ProfilePeekOverlay: View {
    let profile: PublishedProfileSummary
    let backgroundImageURL: String?
    let backgroundHex: String?
    let avatarImageURL: String?
    let isOwn: Bool
    /// Fired when the user taps the card itself — host pushes the
    /// full profile via its existing `pushTarget` flow.
    let onOpen: () -> Void
    /// Fired on backdrop tap or close-glyph tap — host nils its
    /// `peekTarget` to dismount this view.
    let onDismiss: () -> Void

    /// Drives the card's scale transform. `false` while the view is
    /// animating in for the first paint, `true` after the settle.
    @State private var settled: Bool = false
    /// Backdrop opacity envelope. Decoupled from `settled` so the
    /// dim can fade on a softer curve than the card's spring.
    @State private var backdropVisible: Bool = false
    /// Drives the dismiss-direction transform — when `true` the
    /// card squishes inward and fades.
    @State private var dismissing: Bool = false
    /// One-shot guard so the medium "thunk" haptic doesn't fire
    /// twice if SwiftUI re-runs `onAppear` during a transition.
    @State private var didFireOpenHaptic: Bool = false

    /// Full profile pulled from Supabase the moment the peek mounts.
    /// `nil` while the fetch is in flight (the polaroid shows a
    /// pulsing skeleton); on success the actual `CanvasEditorContainer`
    /// renders inside the matte for 1:1 parity with the full
    /// `PublishedProfileView`.
    @State private var fetchedProfile: PublishedProfile?
    /// Drives the skeleton's heartbeat pulse while the canvas is
    /// loading.
    @State private var skeletonPulse: Bool = false
    /// Cascading-reveal stage. Starts at 0 (everything hidden) and
    /// increments through 1..3 as the avatar / bio / sparks each
    /// take their turn springing in.
    @State private var revealStage: Int = 0

    @State private var chrome = AppChromeStore.shared

    var body: some View {
        // Two-layer composition:
        //   • Backdrop fills the entire screen (notch, home
        //     indicator) so the dimmed sheet doesn't leak the
        //     Explore feed at the edges.
        //   • Card content sits inside a GeometryReader that
        //     RESPECTS the safe area so the card never paints
        //     behind the Dynamic Island / status bar / home
        //     indicator. Earlier the body itself had
        //     `.ignoresSafeArea()`, which expanded the reader's
        //     bounds to the full screen and let the card's top-
        //     trailing close button slip behind the notch on real
        //     iPhones (the simulator's iPhone 17 trim happened to
        //     mask the bug).
        ZStack {
            backdrop
            GeometryReader { geo in
                let availableWidth = max(0, min(320, geo.size.width - 32))
                let availableHeight = max(0, geo.size.height - 32)
                ZStack {
                    stickerCard(
                        maxWidth: availableWidth,
                        maxHeight: availableHeight
                    )
                    .scaleEffect(cardScale)
                    .rotationEffect(.degrees(cardTilt))
                    .opacity(dismissing ? 0 : 1)
                    .animation(
                        .spring(response: 0.42, dampingFraction: 0.62),
                        value: settled
                    )
                    .animation(.easeOut(duration: 0.22), value: dismissing)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .accessibilityAddTraits(.isModal)
        .onAppear { runEntrance() }
        // Pull the full profile in parallel with the spring entrance.
        .task(id: profile.username) {
            await loadFullProfile()
        }
    }

    /// Async fetch the full `PublishedProfile`. Enforces a minimum
    /// skeleton duration so a warm-cache hit (< 50ms) doesn't make
    /// the loading state flicker on and off.
    private func loadFullProfile() async {
        guard fetchedProfile == nil else { return }
        let minimumDuration: UInt64 = 700_000_000  // 0.7s
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let p = try await PublishedProfileService().fetch(username: profile.username)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed < minimumDuration {
                try? await Task.sleep(nanoseconds: minimumDuration - elapsed)
            }
            await MainActor.run {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                    fetchedProfile = p
                }
                CucuHaptics.selection()
            }
        } catch {
            // Silent — the polaroid stays in skeleton state. Tap
            // through to the full view, which re-fetches and
            // surfaces the error properly.
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        Color.black
            .opacity(backdropVisible ? 0.55 : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { triggerDismiss() }
            .animation(.easeOut(duration: 0.22), value: backdropVisible)
    }

    // MARK: - Card

    /// Refined card body — avatar + name row, polaroid canvas
    /// preview, vote + freshness footer row, "tap to view" CTA.
    /// Adaptive to the host screen: the polaroid's max canvas
    /// height shrinks to whatever space remains after the chrome
    /// rows, and the entire card content is wrapped in a
    /// `ScrollView` so an unusually tall profile stays scrollable
    /// inside the bounded card on small phones (rather than
    /// overflowing past the screen edges and stealing the close
    /// button with it).
    private func stickerCard(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        // Reserve enough vertical space for the chrome that lives
        // above and below the polaroid: 18pt top + 18pt bottom card
        // padding (36), avatar row (~70), footer row (~30),
        // tap-to-view row (~30), three 14pt VStack gaps (~42), plus
        // a 12pt buffer for the close button's hit area. Sum ≈ 220,
        // bumped to 250 so a tight host (notched iPhone in a
        // tab+nav stack — the actual usable area is ~120pt below the
        // raw screen height) doesn't push the polaroid past the
        // visible rectangle. Whatever remains is the cap the
        // polaroid scales into.
        let chromeReserved: CGFloat = 250
        let polaroidCap = max(160, maxHeight - chromeReserved)
        // Card padding is 18pt each side (36 total) and the matte
        // adds 7pt on each side (14 total) on top of the canvas
        // window. Subtract both so the polaroid never overflows the
        // card's inner content rectangle on narrow phones — the
        // previous fixed 270pt canvas width assumed an iPhone 15-
        // sized card and clipped on anything smaller.
        let canvasMaxWidth = max(180, maxWidth - 36 - 14)

        return ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    avatarAndName
                    pagePreview(maxCanvasWidth: canvasMaxWidth, maxCanvasHeight: polaroidCap)
                    footerRow
                    tapToEnterRow
                }
                .padding(18)
                .frame(maxWidth: maxWidth, alignment: .leading)
                // Tap target lives on the inner content (not the
                // ScrollView) so the close button overlay stays
                // exclusive — tapping the X dismisses, tapping
                // anywhere else opens the profile.
                .contentShape(Rectangle())
                .onTapGesture {
                    CucuHaptics.soft()
                    // Run the dismiss animation first, then ask the
                    // host to open — staging both means the user
                    // sees the card collapse before the push, which
                    // reads as "this peek turned into the profile"
                    // rather than a hard cut.
                    dismissing = true
                    backdropVisible = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        onOpen()
                    }
                }
            }
            // Bound the scroll container to whatever the host
            // screen can spare. SwiftUI shrinks the ScrollView to
            // the content's intrinsic height when it fits; the
            // ceiling only kicks in when the content is too tall.
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .background(cardSurface)
            .overlay(cardStroke)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(chrome.theme.isDark ? 0.5 : 0.28), radius: 26, x: 0, y: 14)

            // Close button is a sibling of the ScrollView, not a
            // child — guarantees it stays pinned to the card
            // frame's top-trailing corner regardless of how much
            // the user has scrolled inside.
            closeButton
                .accessibilitySortPriority(1)
        }
    }

    /// Theme-aware card surface. Snow theme paints pure white,
    /// bone paints cream, midnight paints deep navy elevation —
    /// the peek always reads as a card lifted off the active room.
    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(chrome.theme.cardColor)
    }

    /// Single hairline stroke. Drops the previous double-rule
    /// (1.4pt outer + 1pt inset) in favour of a quiet ink-on-card
    /// line that respects the theme's mood.
    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(chrome.theme.rule, lineWidth: 1)
    }

    /// Avatar circle + name stack. 64pt avatar, bold display name
    /// in the chrome's primary ink, faded handle, and a refined
    /// "You" pill when this is the viewer's own profile.
    private var avatarAndName: some View {
        HStack(spacing: 14) {
            avatarMedallion
            VStack(alignment: .leading, spacing: 3) {
                if let displayName = profile.cardMetadata?.displayName,
                   !displayName.isEmpty {
                    Text(displayName)
                        .font(.cucuSans(20, weight: .bold))
                        .foregroundStyle(chrome.theme.cardInkPrimary)
                        .lineLimit(1)
                }
                Text("@\(profile.username)")
                    .font(.cucuSans(14, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded)
                    .lineLimit(1)
                if isOwn {
                    Text("You")
                        .font(.cucuSans(11, weight: .bold))
                        .foregroundStyle(chrome.theme.cardColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(chrome.theme.cardInkPrimary)
                        )
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Refined avatar medallion — 64pt circle, real avatar if
    /// available, faded fill fallback otherwise. Drops the
    /// decorative cherry tape sparkle and the cream "passport
    /// frame" outer ring; the hairline stroke alone is enough.
    private var avatarMedallion: some View {
        avatarImage
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(chrome.theme.rule, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let url = avatarImageURL.flatMap({ CucuImageTransform.resized($0, square: 64) }) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                avatarLetterFallback
            }
        } else {
            avatarLetterFallback
        }
    }

    /// Refined fallback — bold Lexend initial on a quiet recess of
    /// the chrome's card surface. Drops the italic Fraunces letter
    /// and the hash-tinted seed colour.
    private var avatarLetterFallback: some View {
        ZStack {
            Circle().fill(avatarFallbackFill)
            Text(initial(for: profile.username))
                .font(.cucuSans(28, weight: .bold))
                .foregroundStyle(chrome.theme.cardInkPrimary)
        }
    }

    private var avatarFallbackFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    /// The peek's main attraction — a scaled-down render of the
    /// **actual** published canvas, all pages stacked, mounted via
    /// the same `CanvasEditorContainer` `PublishedProfileView` uses.
    /// Takes an adaptive `maxCanvasHeight` so the polaroid shrinks
    /// to whatever space remains after the surrounding chrome on
    /// small phones — the previous fixed 460pt ceiling caused the
    /// card to overflow on SE-class devices and hide the close
    /// button.
    @ViewBuilder
    private func pagePreview(maxCanvasWidth: CGFloat, maxCanvasHeight: CGFloat) -> some View {
        if let full = fetchedProfile {
            loadedPolaroid(
                profile: full,
                maxCanvasWidth: maxCanvasWidth,
                maxCanvasHeight: maxCanvasHeight
            )
        } else {
            skeletonPolaroid(
                maxCanvasWidth: maxCanvasWidth,
                maxCanvasHeight: maxCanvasHeight
            )
        }
    }

    private static let pageGap: CGFloat = 24

    @ViewBuilder
    private func loadedPolaroid(
        profile: PublishedProfile,
        maxCanvasWidth: CGFloat,
        maxCanvasHeight: CGFloat
    ) -> some View {
        let pages = profile.document.pages
        if pages.isEmpty {
            skeletonPolaroid(
                maxCanvasWidth: maxCanvasWidth,
                maxCanvasHeight: maxCanvasHeight
            )
        } else {
            let designWidth = (0..<pages.count)
                .map { CGFloat(profile.document.contentDesignWidth(forPageAt: $0)) }
                .max() ?? 390
            let pageHeights = pages.map { max(1, CGFloat($0.height)) }
            let totalContentHeight = pageHeights.reduce(0, +)
                + Self.pageGap * CGFloat(max(0, pages.count - 1))

            let widthFitScale = maxCanvasWidth / max(1, designWidth)
            let heightFitScale = maxCanvasHeight / max(1, totalContentHeight)
            let scale = min(widthFitScale, heightFitScale)

            let renderedWidth = designWidth * scale
            let renderedHeight = totalContentHeight * scale

            polaroidMatte(width: renderedWidth, height: renderedHeight) {
                VStack(spacing: Self.pageGap) {
                    ForEach(0..<pages.count, id: \.self) { pageIndex in
                        let pageHeight = pageHeights[pageIndex]
                        CanvasEditorContainer(
                            document: .constant(profile.document),
                            selectedID: .constant(nil),
                            onCommit: { _ in /* read-only peek */ },
                            isInteractive: false,
                            onOpenURL: { _ in },
                            onOpenImage: { _, _ in },
                            onOpenJournal: { _ in },
                            onOpenFullGallery: { _ in },
                            onOpenNote: { _ in },
                            viewerPageIndex: pageIndex
                        )
                        .frame(width: designWidth, height: pageHeight)
                    }
                }
                .frame(width: designWidth, height: totalContentHeight, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: renderedWidth, height: renderedHeight, alignment: .topLeading)
                .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    /// Refined polaroid chrome. Single hairline stroke, soft
    /// shadow, theme-aware matte fill. Drops the heavy 1.2pt outer
    /// ink stroke + 0.8pt inset rule double-stroke pattern.
    private func polaroidMatte<Content: View>(
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(matteFill)
            content()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(7)
        }
        .frame(width: width + 14, height: height + 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(chrome.theme.rule, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(chrome.theme.isDark ? 0.30 : 0.14), radius: 6, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Quiet recess matching the search field / reply bar surface
    /// family — the polaroid mat reads as the same paper as every
    /// other refined input on the chrome.
    private var matteFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    /// Loading-state polaroid. Sizes to the same canvas window the
    /// loaded polaroid will occupy so the card layout stays stable
    /// when content lands. Width adapts to the host card's inner
    /// content rectangle (was previously a fixed 270pt that
    /// overflowed the card on phones narrower than iPhone 15);
    /// height fills the polaroid cap so the skeleton fully
    /// occupies the reserved space rather than reading as a
    /// half-filled placeholder.
    private func skeletonPolaroid(maxCanvasWidth: CGFloat, maxCanvasHeight: CGFloat) -> some View {
        let height = max(160, maxCanvasHeight)
        return polaroidMatte(width: maxCanvasWidth, height: height) {
            skeletonCanvas
        }
    }

    /// Refined skeleton — cream ground, three cascading reveal
    /// shapes (avatar, body bars, divider), and a quiet "Loading"
    /// caption pinned to the bottom. Drops the diagonal shimmer
    /// sweep, the cherry-bullet "DEVELOPING" mono caption, and the
    /// sparkle row.
    private var skeletonCanvas: some View {
        ZStack {
            chrome.theme.cardColor

            VStack(alignment: .leading, spacing: 10) {
                avatarSkeleton
                bioBars
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack {
                Spacer(minLength: 0)
                loadingCaption
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .allowsHitTesting(false)
        }
        .opacity(skeletonPulse ? 1.0 : 0.78)
        .onAppear { runSkeletonChoreography() }
    }

    /// Stage 1 — avatar puck + handle bars. Springs in from
    /// scale 0.4 with a small upward drift.
    private var avatarSkeleton: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(skeletonBarFill)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(skeletonBarFill)
                    .frame(width: 110, height: 12)
                Capsule()
                    .fill(skeletonBarFill.opacity(0.7))
                    .frame(width: 60, height: 8)
            }
            Spacer(minLength: 0)
        }
        .scaleEffect(revealStage >= 1 ? 1.0 : 0.4, anchor: .leading)
        .opacity(revealStage >= 1 ? 1.0 : 0)
        .offset(y: revealStage >= 1 ? 0 : 8)
    }

    /// Stage 2 — two body lines standing in for the bio.
    private var bioBars: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(skeletonBarFill.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 8)
            Capsule()
                .fill(skeletonBarFill.opacity(0.6))
                .frame(width: 160, height: 8)
        }
        .scaleEffect(revealStage >= 2 ? 1.0 : 0.6, anchor: .leading)
        .opacity(revealStage >= 2 ? 1.0 : 0)
        .offset(y: revealStage >= 2 ? 0 : 10)
    }

    /// Skeleton fill — uses the chrome's faded ink at low opacity
    /// so the bars read as quiet placeholders against the matte
    /// regardless of theme.
    private var skeletonBarFill: Color {
        chrome.theme.cardInkFaded.opacity(0.30)
    }

    /// Refined loading caption. Drops the cherry bullet, tracked
    /// uppercase mono "DEVELOPING", three-dot phase animation,
    /// and the cream pill chrome. Just plain "Loading" in faded
    /// ink with a quiet pulse.
    private var loadingCaption: some View {
        Text("Loading")
            .font(.cucuSans(13, weight: .regular))
            .foregroundStyle(chrome.theme.cardInkFaded)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(chrome.theme.cardColor.opacity(0.92))
            )
            .overlay(
                Capsule().strokeBorder(chrome.theme.rule, lineWidth: 1)
            )
    }

    /// Two-pass skeleton choreography. Heartbeat pulse + cascading
    /// reveal — drops the shimmer sweep + dot phase animations.
    private func runSkeletonChoreography() {
        // Soft heartbeat across the whole skeleton.
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            skeletonPulse = true
        }
        // Cascading reveal: each stage is a punchy spring 110ms
        // after the previous one.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                revealStage = 1
            }
            try? await Task.sleep(nanoseconds: 110_000_000)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                revealStage = 2
            }
            try? await Task.sleep(nanoseconds: 110_000_000)
            withAnimation(.spring(response: 0.46, dampingFraction: 0.55)) {
                revealStage = 3
            }
        }
    }

    /// Refined footer — vote count on the leading edge, freshness
    /// label on the trailing. Vote chip uses a clean ink heart +
    /// bold count instead of the burgundy-on-rose wax-seal chip.
    private var footerRow: some View {
        HStack(spacing: 10) {
            voteChip
            Spacer(minLength: 0)
            Text(freshLabel)
                .font(.cucuSans(12, weight: .regular))
                .foregroundStyle(chrome.theme.cardInkFaded)
        }
    }

    /// Refined vote chip. Drops the rose-on-burgundy wax-seal
    /// styling + cucuMono digit treatment. Plain ink heart with
    /// the count in bold sans, no chip chrome.
    private var voteChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chrome.theme.cardInkPrimary)
            Text("\(profile.voteCount)")
                .font(.cucuSans(13, weight: .bold))
                .foregroundStyle(chrome.theme.cardInkPrimary)
        }
    }

    /// Refined CTA. Plain "Tap to view" in faded ink, no spec line
    /// + ✦ flourish. The card itself is the affordance; the label
    /// just confirms it.
    private var tapToEnterRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("Tap to view")
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(chrome.theme.cardInkFaded)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chrome.theme.cardInkFaded)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// Refined close button. Theme-aware fill + hairline stroke,
    /// no editorial double-rule chrome.
    private var closeButton: some View {
        Button {
            triggerDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(chrome.theme.cardInkPrimary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(chrome.theme.cardColor)
                )
                .overlay(
                    Circle().strokeBorder(chrome.theme.rule, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(10)
        .accessibilityLabel("Dismiss peek")
    }

    // MARK: - Animation driver

    /// Card scale curve. Spring physics handle the in-between
    /// values; we just provide the targets. On dismiss the card
    /// squishes to 0.94 instead of collapsing to zero so the
    /// close reads as "tucked away" rather than "vanished into
    /// nothing."
    private var cardScale: CGFloat {
        if dismissing { return 0.94 }
        return settled ? 1.0 : 0.5
    }

    /// Tiny tilt seasoning so the card reads as physical paper
    /// being held off-axis. -2.5° on entry, settles to 0.
    private var cardTilt: Double {
        if dismissing { return 0 }
        return settled ? 0 : -2.5
    }

    private func runEntrance() {
        // Backdrop fades in immediately while the card is still
        // tiny — the user reads "context dimmed" before the card
        // pops in.
        backdropVisible = true

        // One frame later, kick the spring so the visual punch and
        // the haptic land at the same time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                settled = true
            }
            if !didFireOpenHaptic {
                // Land the medium thunk just past the overshoot
                // peak (~120ms in) so haptic and visual punch line
                // up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    CucuHaptics.duplicate()
                    didFireOpenHaptic = true
                }
            }
        }
    }

    private func triggerDismiss() {
        guard !dismissing else { return }
        CucuHaptics.selection()
        dismissing = true
        backdropVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onDismiss()
        }
    }

    // MARK: - Helpers

    private func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private var freshLabel: String {
        guard let date = profile.sortDate else { return "Just published" }
        let interval = Date().timeIntervalSince(date)
        switch interval {
        case ..<60:        return "Just now"
        case ..<3600:      return "\(Int(interval / 60))m ago"
        case ..<86_400:    return "\(Int(interval / 3600))h ago"
        case ..<604_800:   return "\(Int(interval / 86_400))d ago"
        default:           return "\(Int(interval / 604_800))w ago"
        }
    }
}
