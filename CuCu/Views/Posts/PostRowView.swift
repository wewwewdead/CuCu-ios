import SwiftUI

/// Single-post card. Two style variants:
///
///   - **`.full`** for feed + thread: avatar, header, body, action
///     row (heart / reply / overflow). Tappable as a whole row to
///     push the thread view, with the inner controls escaping that
///     gesture so heart / reply / overflow only do their own thing.
///   - **`.compact`** for the upcoming profile-page surface (Phase
///     6): drop the avatar, tighten padding, cap the body at 4
///     lines so a column of recent posts stays scannable.
///
/// The view itself is dumb — it doesn't fetch, mutate, or know
/// which feed it's part of. Tap intents flow up through closures
/// the parent feeds it (`onTap`, `onReply`, `onLike`, `onDelete`).
struct PostRowView: View {
    enum Style {
        case full
        case compact
    }

    let post: Post
    let style: Style
    let viewerHasLiked: Bool
    /// True when the current viewer authored this post — drives
    /// whether the overflow menu shows the destructive Delete
    /// item. Computed by the parent so the row doesn't need a
    /// reference to AuthViewModel.
    let isOwnPost: Bool

    /// Optional override that paints the author's actual hero
    /// avatar (pulled from their published profile by the parent
    /// feed's enrichment pass) in place of the bookplate letter
    /// tile. Nil when the author hasn't published a profile or
    /// hasn't set a hero avatar — the letter fallback covers that
    /// case so every row stays renderable offline / pre-fetch.
    var avatarURL: String? = nil

    var onTap: () -> Void = {}
    var onLike: () -> Void = {}
    var onReply: () -> Void = {}
    var onDelete: () -> Void = {}
    var onReport: () -> Void = {}
    var onBlock: () -> Void = {}
    /// Fired when the viewer taps the avatar tile or the `@handle`
    /// text. Hosts (feed, thread) hand a closure that pushes the
    /// author's `PublishedProfileView`. Default no-op so callers
    /// that don't want author navigation (e.g. inside the
    /// `PublishedProfileView` posts section, where every row is
    /// already by the visible profile owner) can simply omit it
    /// without a visible behaviour change.
    var onAuthorTap: () -> Void = {}

    /// Thread descendants want their own card-less treatment so the
    /// indent spine reads as the visual structure. PostThreadView
    /// flips this on; every other surface (feed, profile list)
    /// leaves it at the default and gets the standard floating card.
    @Environment(\.cucuPostRowSuppressCard) private var suppressCard

    /// Process-wide app-chrome theme. Drives the card surface +
    /// in-card text colour so a dark-mode pick gives the row a true
    /// dark elevated card with light text, not a cream paper sat on
    /// a dark backdrop.
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Group {
            if style == .full && !suppressCard {
                Button(action: onTap) {
                    rowBody
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chrome.theme.cardColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chrome.theme.cardStroke, lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            } else {
                Button(action: onTap) {
                    rowBody
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 14) {
            if style == .full {
                avatar
            }
            VStack(alignment: .leading, spacing: 8) {
                header
                bodyText
                if style == .full {
                    actionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(paddingForStyle)
        .contentShape(Rectangle())
    }

    // MARK: - Pieces

    /// Square bookplate avatar — rounded-rect tile, muted palette
    /// fill, Fraunces-italic initial in deep ink. The square shape
    /// reads as a printed monogram rather than a social-media
    /// circle, which is exactly the editorial register the page is
    /// going for.
    ///
    /// When `avatarURL` resolves, the tile flips to a real image
    /// (loaded through `CachedRemoteImage` so the bytes come from
    /// the shared cache `PublishedProfilesListView` already warms),
    /// keeping the same square geometry + ink-stroke overlay so the
    /// row's rhythm doesn't change between fallback and real-photo
    /// states.
    private var avatar: some View {
        // Wrapped in a plain Button so a tap on the bookplate tile
        // navigates to the author's published profile rather than
        // bubbling to the outer thread-push gesture. The plain
        // button style suppresses SwiftUI's default press tint so
        // the editorial monogram doesn't flash blue under the
        // finger — the haptic + push are the feedback.
        Button {
            CucuHaptics.selection()
            onAuthorTap()
        } label: {
            Group {
                // 40pt tile rendered at retina pixels — Supabase's
                // image renderer crops/scales server-side so a
                // megapixel avatar doesn't cross the wire just to
                // be downsampled on-device. Foreign URLs (or any
                // non-Supabase host) fall through unchanged.
                if let urlString = avatarURL,
                   let url = CucuImageTransform.resized(urlString, square: 40) {
                    CachedRemoteImage(url: url, contentMode: .fill) {
                        letterAvatar
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(chrome.theme.cardInkPrimary.opacity(0.35), lineWidth: 0.8)
                    )
                } else {
                    letterAvatar
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View @\(post.authorUsername)'s profile")
    }

    private var letterAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.avatarColor(for: post.authorUsername))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(chrome.theme.cardInkPrimary.opacity(0.35), lineWidth: 0.8)
                )
            Text(Self.avatarInitial(for: post.authorUsername))
                .font(.cucuEditorial(20, italic: true))
                .foregroundStyle(chrome.theme.cardInkPrimary)
        }
    }

    /// Two-line header — username on top in serif semibold,
    /// timestamp on its own line in tracked uppercased mono. The
    /// vertical split frees the body from a single long inline run
    /// of metadata and gives the row a printed-spec rhythm.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // The handle is the second tap target for navigating
                // to the author's profile (the avatar is the first).
                // Wrapped in a plain Button so the tap escapes the
                // outer row Button — without this, tapping `@user`
                // would push the thread view rather than the author.
                Button {
                    CucuHaptics.selection()
                    onAuthorTap()
                } label: {
                    Text("@\(post.authorUsername)")
                        .font(.cucuSerif(15, weight: .semibold))
                        .foregroundStyle(chrome.theme.cardInkPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View @\(post.authorUsername)'s profile")

                if post.editedAt != nil {
                    Text("· edited")
                        .font(.cucuSans(11, weight: .regular))
                        .foregroundStyle(chrome.theme.cardInkFaded)
                }
                Spacer(minLength: 0)
                if style == .full {
                    overflowMenu
                }
            }
            Text(Self.relativeTimestamp(for: post.createdAt))
                .font(.cucuMono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(chrome.theme.cardInkFaded)
        }
    }

    private var bodyText: some View {
        Text(post.body)
            .font(.cucuSans(15))
            .foregroundStyle(chrome.theme.cardInkPrimary)
            .lineSpacing(4)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(style == .compact ? 4 : nil)
            .truncationMode(.tail)
    }

    /// Right-aligned action cluster — reply count then heart,
    /// both in faded ink at rest, both with monospaced counts.
    /// Right-alignment is the magazine / reading-mode pattern;
    /// it keeps the body's left margin clean for the eye.
    private var actionRow: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            // Reply
            Button {
                onReply()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(chrome.theme.cardInkFaded)
                    if post.replyCount > 0 {
                        Text("\(post.replyCount)")
                            .font(.cucuMono(11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(chrome.theme.cardInkMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply")

            // Heart / like — wax-seal love stamp. On like: bouncy
            // pop + rotational wobble, cherry halo ring radiates
            // outward, and a six-piece petal burst (mini hearts +
            // sparkles) scatters from the center. On unlike: a
            // softer deflate pinch with a contracting dust ring,
            // no particles. The whole choreography lives inside
            // `AnimatedHeartButton` so the row body stays readable.
            AnimatedHeartButton(
                isLiked: viewerHasLiked,
                likeCount: post.likeCount,
                onTap: onLike
            )
        }
        .padding(.top, 2)
    }

    private var overflowMenu: some View {
        Menu {
            if isOwnPost {
                // You can't report or block yourself — the only
                // meaningful destructive action on your own post
                // is Delete.
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button {
                    onReport()
                } label: {
                    Label("Report", systemImage: "flag")
                }
                Button(role: .destructive) {
                    onBlock()
                } label: {
                    Label("Block @\(post.authorUsername)", systemImage: "hand.raised")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(chrome.theme.cardInkFaded)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        // Stop a Menu tap from also firing the row's outer Button.
        .buttonStyle(.plain)
    }

    // MARK: - Layout helpers

    private var paddingForStyle: EdgeInsets {
        switch style {
        case .full:
            return EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        case .compact:
            return EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        }
    }

    // MARK: - Static formatting helpers

    /// Relative timestamp tuned for social text. Uppercased units
    /// pair with the monospaced timestamp font (`cucuMono`) so the
    /// row's metadata reads as a printer's spec line.
    static func relativeTimestamp(for date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "JUST NOW" }
        if interval < 3600 {
            return "\(Int(interval / 60))M AGO"
        }
        if interval < 86_400 {
            return "\(Int(interval / 3600))H AGO"
        }
        if interval < 7 * 86_400 {
            return "\(Int(interval / 86_400))D AGO"
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date).uppercased()
    }

    /// Deterministic palette pick. Hashing the username (rather
    /// than `id`) means the same author always gets the same
    /// colour across every row — a tiny visual signal of identity
    /// before the eye reaches the `@handle`.
    static func avatarColor(for username: String) -> Color {
        let lower = username.lowercased()
        let sum = lower.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    /// Muted bookplate palette — drops the most saturated picks
    /// (cucuShell, cucuMatcha) in favour of paper-toned tiles so
    /// the avatar reads as a printed monogram rather than a candy
    /// dot. The repeated paper tones are intentional: variation
    /// without saturation.
    private static let palette: [Color] = [
        .cucuRose, .cucuMossSoft, .cucuSky, .cucuBone,
        .cucuPaperDeep, .cucuAccentSoft, .cucuCardSoft, .cucuRose
    ]

    static func avatarInitial(for username: String) -> String {
        guard let first = username.first else { return "?" }
        return String(first).uppercased()
    }
}

// MARK: - Card-suppression environment

/// Internal opt-out so a host (e.g. `PostThreadView`) can render a
/// `PostRowView` without its default ink-stroked card wrap. Used to
/// keep thread descendants visually attached to the indent spine
/// while the root post keeps its own larger card chrome.
private struct CucuPostRowSuppressCardKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var cucuPostRowSuppressCard: Bool {
        get { self[CucuPostRowSuppressCardKey.self] }
        set { self[CucuPostRowSuppressCardKey.self] = newValue }
    }
}

// MARK: - Animated heart (Duolingo-style confetti pop)
//
// The heart pops with classic cartoon-animation principles —
// exaggerated squash and stretch, anticipation, big overshoot,
// secondary settle — and showers a Duolingo-flavoured confetti
// burst from its center. Both directions get confetti so a tap
// always feels celebratory; the direction only changes the
// flavour of the celebration:
//
//   - Liking (empty → filled): deep 0.55 anticipation squash,
//     huge 1.75× stretch overshoot, snap-back to 0.88 squish,
//     1.06 wobble, then settle at 1.0. Heavy rotational rocking
//     across four phases. A 12-piece confetti burst — mixed
//     rectangles, circles, triangles, and stars in a five-colour
//     palette (cherry, cobalt, matcha, shell, accent) — launches
//     in a gravity-influenced arc, tumbling with random spin and
//     dropping past each piece's peak.
//   - Unliking (filled → empty): gentler 0.65 squash, 1.18
//     stretch, 0.94 squish, 1.0 settle. A smaller 7-piece "puff"
//     confetti in muted tones (rose, ink-faded, paper-deep)
//     scatters outward without the dramatic gravity arc — feels
//     like letting confetti drift off rather than launching it.
//
// The component owns its own animation tick and direction so a
// single tap retriggers the whole sequence cleanly even when the
// parent's `isLiked` flips synchronously. The like count uses a
// numeric content transition so the digit rolls into place rather
// than snapping.

/// Direction the current tap is taking the heart in. File-scope so
/// the same value can flow into the burst and halo subviews without
/// either having to import the parent's namespace. Captured at tap
/// time (before `isLiked` flips on the parent) so the keyframe
/// tracks can branch on intent rather than landing state.
private enum HeartTapFlavour { case like, unlike }

private struct AnimatedHeartButton: View {
    let isLiked: Bool
    let likeCount: Int
    let onTap: () -> Void

    @State private var tick: Int = 0
    @State private var direction: HeartTapFlavour = .like
    /// Local chrome ref so the rest icon and the count text follow
    /// whatever paper stock the user picked, even though the heart
    /// button is its own sub-view.
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Button {
            // Capture intent before the parent flips `isLiked`.
            direction = isLiked ? .unlike : .like
            switch direction {
            case .like:   CucuHaptics.soft()
            case .unlike: CucuHaptics.selection()
            }
            tick &+= 1
            onTap()
        } label: {
            HStack(spacing: 5) {
                heartCluster
                    // Reserve room for the heart at its peak scale
                    // so the row's count baseline doesn't jiggle as
                    // the icon overshoots.
                    .frame(width: 22, height: 22)
                    // Lift the cluster above neighbouring rows in
                    // the LazyVStack so confetti pieces that drift
                    // past the card's bottom edge aren't hidden
                    // behind the next row's card background.
                    .zIndex(10)
                if likeCount > 0 {
                    Text("\(likeCount)")
                        .font(.cucuMono(11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(chrome.theme.cardInkMuted)
                        .contentTransition(.numericText(value: Double(likeCount)))
                        .animation(
                            .spring(response: 0.34, dampingFraction: 0.72),
                            value: likeCount
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
    }

    /// The heart and its surrounding effects. The ZStack does not
    /// clip, so the halo ring and petal particles can extend well
    /// past the 20pt frame without being cut off.
    private var heartCluster: some View {
        ZStack {
            // Subviews are kept structurally stable across direction
            // flips — they used to live inside a `switch direction`,
            // which swapped the view tree on every toggle and
            // re-initialised each `keyframeAnimator` with the new tick
            // already set as its baseline. The animator interprets a
            // brand-new view's first trigger value as the *initial*
            // value (no transition), so animations only fired on the
            // very first like and never again. Branching by `flavour`
            // *inside* persistent subviews lets the animators see
            // tick actually change.
            HeartHaloRing(tick: tick, flavour: direction)
            HeartConfettiBurst(tick: tick, flavour: direction)

            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isLiked ? Color.cucuCherry : chrome.theme.cardInkFaded)
                .keyframeAnimator(
                    initialValue: HeartPopValues(),
                    trigger: tick
                ) { content, value in
                    content
                        .scaleEffect(value.scale)
                        .rotationEffect(.degrees(value.rotation))
                } keyframes: { _ in
                    // Cartoon animation principles: deep
                    // anticipation, exaggerated stretch overshoot,
                    // squash counter-bounce, secondary wobble,
                    // settle. Top-level tracks must be uniform, so
                    // the per-direction branching lives inside each
                    // track rather than wrapping the whole block.
                    KeyframeTrack(\.scale) {
                        if direction == .like {
                            // Big Duolingo pop: anticipation crush
                            // → stretch high → squash bounce →
                            // wobble → settle. The 1.75 peak is
                            // intentionally past what feels "safe"
                            // — that overshoot is what reads as
                            // joy rather than acknowledgement.
                            CubicKeyframe(0.55, duration: 0.07)
                            SpringKeyframe(1.75, duration: 0.20, spring: .bouncy)
                            SpringKeyframe(0.88, duration: 0.14, spring: .smooth)
                            SpringKeyframe(1.06, duration: 0.14, spring: .smooth)
                            SpringKeyframe(1.0,  duration: 0.16, spring: .smooth)
                        } else {
                            // Softer counterpart: a pinch, a smaller
                            // stretch, a quick squish, and out.
                            CubicKeyframe(0.65, duration: 0.08)
                            SpringKeyframe(1.18, duration: 0.16, spring: .bouncy)
                            SpringKeyframe(0.94, duration: 0.12, spring: .smooth)
                            SpringKeyframe(1.0,  duration: 0.16, spring: .smooth)
                        }
                    }
                    KeyframeTrack(\.rotation) {
                        if direction == .like {
                            // Heavy four-phase rocking — the heart
                            // is rooting for you. Big lead swing,
                            // bigger counter-swing, two damping
                            // returns.
                            CubicKeyframe(0,    duration: 0.04)
                            CubicKeyframe(-20,  duration: 0.10)
                            CubicKeyframe(14,   duration: 0.12)
                            CubicKeyframe(-5,   duration: 0.10)
                            CubicKeyframe(2,    duration: 0.08)
                            CubicKeyframe(0,    duration: 0.10)
                        } else {
                            CubicKeyframe(-8, duration: 0.06)
                            CubicKeyframe(5,  duration: 0.07)
                            CubicKeyframe(-2, duration: 0.06)
                            CubicKeyframe(0,  duration: 0.10)
                        }
                    }
                }
        }
    }
}

/// Tween targets for the heart icon's pop. Kept as a tiny value
/// type so the keyframe tracks can address scale and rotation
/// independently with their own timing curves.
private struct HeartPopValues {
    var scale: CGFloat = 1.0
    var rotation: Double = 0
}

// MARK: - Effect views

/// Cherry halo that radiates outward from the heart on a like; an
/// inward-contracting ink-tinted dust ring on unlike. Always
/// rendered (rather than conditionally swapped in/out) so its
/// `keyframeAnimator` retains structural identity across direction
/// flips and reliably observes each `tick` change.
private struct HeartHaloRing: View {
    let tick: Int
    let flavour: HeartTapFlavour

    var body: some View {
        Circle()
            .strokeBorder(strokeColor, lineWidth: strokeWidth)
            .keyframeAnimator(
                initialValue: HaloValues(),
                trigger: tick
            ) { content, value in
                content
                    .frame(width: value.size, height: value.size)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.size) {
                    if flavour == .like {
                        LinearKeyframe(6,  duration: 0.0)
                        CubicKeyframe(44, duration: 0.46)
                    } else {
                        LinearKeyframe(26, duration: 0.0)
                        CubicKeyframe(8,   duration: 0.30)
                    }
                }
                KeyframeTrack(\.opacity) {
                    if flavour == .like {
                        LinearKeyframe(0.0,  duration: 0.0)
                        LinearKeyframe(0.85, duration: 0.06)
                        CubicKeyframe(0.0,   duration: 0.40)
                    } else {
                        LinearKeyframe(0.0, duration: 0.0)
                        LinearKeyframe(0.5, duration: 0.05)
                        CubicKeyframe(0.0,  duration: 0.26)
                    }
                }
            }
            .allowsHitTesting(false)
    }

    private var strokeColor: Color {
        flavour == .like
            ? Color.cucuCherry.opacity(0.55)
            : Color.cucuInkFaded.opacity(0.45)
    }

    private var strokeWidth: CGFloat {
        flavour == .like ? 1.4 : 0.9
    }
}

private struct HaloValues {
    var size: CGFloat = 8
    var opacity: Double = 0
}

// MARK: - Confetti

/// Mixed-shape confetti shower in the Duolingo style. Each piece
/// has its own pre-baked polar trajectory, peak height, gravity
/// drop, tumble spin, shape, colour, and size — all derived
/// deterministically from the piece index so the layout stays
/// stable across runs but feels chaotically scattered. The
/// per-piece path animates as a parabolic arc: pieces shoot
/// outward + slightly upward to a peak, then continue past their
/// peak as gravity pulls them down, while spinning through up to
/// 540° of tumble.
///
/// The `.like` flavour throws 12 pieces in saturated cherry /
/// cobalt / matcha / shell / accent colours with strong gravity
/// drops; the `.unlike` flavour throws 7 in muted rose / ink /
/// paper-deep tones with shorter throws and barely-there
/// gravity, so it reads as a soft puff rather than a celebration.
private struct HeartConfettiBurst: View {
    let tick: Int
    let flavour: HeartTapFlavour

    /// Both flavours render the same number of pieces (12) so the
    /// ForEach's identity stays stable across flavour flips. That
    /// stability is load-bearing: each piece's `keyframeAnimator`
    /// only fires when its `trigger` changes, and a child view
    /// that gets destroyed-and-recreated on flavour swap would
    /// initialise with the new tick already in place and skip the
    /// transition entirely.
    private static let pieceCount: Int = 12

    var body: some View {
        ZStack {
            ForEach(0..<Self.pieceCount, id: \.self) { index in
                ConfettiParticleView(
                    piece: Self.piece(at: index, flavour: flavour),
                    tick: tick
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Returns the piece config for a given slot under the current
    /// flavour. Like/unlike share the same piece count; the unlike
    /// flavour just dampens radius, gravity, spin, and saturation
    /// so the same 12-piece structure can read either as a
    /// celebration or a soft puff without remounting the views.
    static func piece(at index: Int, flavour: HeartTapFlavour) -> ConfettiPiece {
        switch flavour {
        case .like:   return likePieces[index]
        case .unlike: return unlikePieces[index]
        }
    }

    /// Like burst: 12 mixed-shape pieces in a fan that arcs from
    /// the left flank up over the top to the right flank — all
    /// angles in [-180°, 0°] so every piece flies upward or
    /// horizontally. Pieces flying straight down would dive past
    /// the card's bottom padding into the next row in the
    /// LazyVStack, where the neighbour's card background draws
    /// on top and hides them. Confining the burst to the upper
    /// hemisphere keeps every piece visible against the card.
    /// Saturated five-colour palette: cherry / cobalt / matcha /
    /// shell / accent.
    private static let likePieces: [ConfettiPiece] = [
        // angle, radius, peakRise, gravityDrop, totalSpin, size, shape, color
        ConfettiPiece(angle: -175, radius: 36, peakRise:  6, gravityDrop: 4, totalSpin:  420, size: 10, shape: .rect,     color: .cucuCherry),
        ConfettiPiece(angle: -160, radius: 42, peakRise: 10, gravityDrop: 4, totalSpin: -360, size:  9, shape: .circle,   color: .cucuCobalt),
        ConfettiPiece(angle: -140, radius: 48, peakRise: 14, gravityDrop: 4, totalSpin:  540, size: 12, shape: .triangle, color: .cucuMatcha),
        ConfettiPiece(angle: -120, radius: 50, peakRise: 16, gravityDrop: 4, totalSpin: -300, size: 11, shape: .rect,     color: .cucuShell),
        ConfettiPiece(angle: -100, radius: 52, peakRise: 18, gravityDrop: 4, totalSpin:  390, size: 10, shape: .star,     color: .cucuCherry),
        ConfettiPiece(angle:  -85, radius: 50, peakRise: 18, gravityDrop: 4, totalSpin: -450, size: 12, shape: .circle,   color: .cucuAccentSoft),
        ConfettiPiece(angle:  -70, radius: 50, peakRise: 18, gravityDrop: 4, totalSpin:  330, size: 11, shape: .rect,     color: .cucuMatcha),
        ConfettiPiece(angle:  -55, radius: 52, peakRise: 18, gravityDrop: 4, totalSpin: -420, size: 10, shape: .triangle, color: .cucuCobalt),
        ConfettiPiece(angle:  -40, radius: 50, peakRise: 16, gravityDrop: 4, totalSpin:  360, size:  9, shape: .star,     color: .cucuCherry),
        ConfettiPiece(angle:  -25, radius: 48, peakRise: 14, gravityDrop: 4, totalSpin: -390, size: 12, shape: .triangle, color: .cucuShell),
        ConfettiPiece(angle:  -10, radius: 42, peakRise: 10, gravityDrop: 4, totalSpin:  300, size:  9, shape: .circle,   color: .cucuCobalt),
        ConfettiPiece(angle:    0, radius: 36, peakRise:  6, gravityDrop: 4, totalSpin: -330, size: 10, shape: .rect,     color: .cucuMatcha)
    ]

    /// Unlike puff: same 12-slot fan, every trajectory dimension
    /// dialed down. All angles still in [-180°, 0°] so pieces
    /// drift up and out rather than down. Half the throw
    /// distance, smaller pieces, muted rose / ink / paper-deep
    /// palette — reads as confetti drifting off rather than
    /// launching.
    private static let unlikePieces: [ConfettiPiece] = [
        ConfettiPiece(angle: -175, radius: 18, peakRise: 3, gravityDrop: 2, totalSpin:  180, size: 5, shape: .rect,     color: .cucuRoseStroke),
        ConfettiPiece(angle: -160, radius: 20, peakRise: 4, gravityDrop: 2, totalSpin: -160, size: 5, shape: .circle,   color: .cucuInkFaded),
        ConfettiPiece(angle: -140, radius: 22, peakRise: 5, gravityDrop: 2, totalSpin:  200, size: 6, shape: .triangle, color: .cucuShell),
        ConfettiPiece(angle: -120, radius: 24, peakRise: 7, gravityDrop: 2, totalSpin: -160, size: 5, shape: .rect,     color: .cucuPaperDeep),
        ConfettiPiece(angle: -100, radius: 26, peakRise: 8, gravityDrop: 2, totalSpin:  150, size: 5, shape: .star,     color: .cucuRoseStroke),
        ConfettiPiece(angle:  -85, radius: 26, peakRise: 8, gravityDrop: 2, totalSpin: -200, size: 6, shape: .circle,   color: .cucuShell),
        ConfettiPiece(angle:  -70, radius: 26, peakRise: 8, gravityDrop: 2, totalSpin:  150, size: 5, shape: .rect,     color: .cucuInkFaded),
        ConfettiPiece(angle:  -55, radius: 24, peakRise: 7, gravityDrop: 2, totalSpin: -180, size: 6, shape: .triangle, color: .cucuRoseStroke),
        ConfettiPiece(angle:  -40, radius: 22, peakRise: 5, gravityDrop: 2, totalSpin:  160, size: 5, shape: .star,     color: .cucuPaperDeep),
        ConfettiPiece(angle:  -25, radius: 20, peakRise: 4, gravityDrop: 2, totalSpin: -170, size: 5, shape: .triangle, color: .cucuShell),
        ConfettiPiece(angle:  -10, radius: 20, peakRise: 4, gravityDrop: 2, totalSpin:  140, size: 5, shape: .circle,   color: .cucuInkFaded),
        ConfettiPiece(angle:    0, radius: 18, peakRise: 3, gravityDrop: 2, totalSpin: -150, size: 5, shape: .rect,     color: .cucuRoseStroke)
    ]
}

/// Static config for one piece of confetti. Pre-computing this
/// per index keeps each particle's behaviour stable but distinct
/// — angles, radii, gravity, spin, size, shape, and colour all
/// vary across the set so the overall burst reads as scattered
/// rather than radial.
private struct ConfettiPiece {
    let angle: Double          // launch direction, degrees
    let radius: CGFloat        // horizontal/vertical reach to peak
    let peakRise: CGFloat      // extra upward bias at the apex
    let gravityDrop: CGFloat   // how far past the peak it falls
    let totalSpin: Double      // total rotation, signed
    let size: CGFloat
    let shape: Shape
    let color: Color

    enum Shape { case rect, circle, triangle, star }
}

private struct ConfettiValues {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 0
    var opacity: Double = 0
    var spin: Double = 0
}

/// Single confetti piece with its own keyframe-driven trajectory.
/// The x track is a straight ease-out to the launch radius; the y
/// track is a parabolic arc — first up to the peak (radius * sin
/// minus a peakRise lift), then continuing past the peak as
/// gravity pulls it down. The opacity holds longer than the scale
/// so pieces fade out at the bottom of their fall rather than
/// vanishing mid-air.
private struct ConfettiParticleView: View {
    let piece: ConfettiPiece
    let tick: Int

    var body: some View {
        let radians = piece.angle * .pi / 180
        let dirX = CGFloat(cos(radians))
        let dirY = CGFloat(sin(radians))
        let peakX = dirX * piece.radius
        let peakY = dirY * piece.radius - piece.peakRise
        let endX  = dirX * piece.radius
        let endY  = dirY * piece.radius + piece.gravityDrop

        confettiShape
            .frame(width: piece.size, height: piece.size * shapeAspect)
            .keyframeAnimator(
                initialValue: ConfettiValues(),
                trigger: tick
            ) { content, value in
                content
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
                    .rotationEffect(.degrees(value.spin))
                    .offset(x: value.x, y: value.y)
            } keyframes: { _ in
                // Total duration ~1.1s — slow enough that each
                // piece's pop, arc, and fade are individually
                // perceivable rather than blurring into a single
                // flash. Non-zero first-segment durations avoid
                // edge cases where 0-duration keyframes can
                // occasionally be skipped by the animator.
                KeyframeTrack(\.x) {
                    LinearKeyframe(0,     duration: 0.04)
                    CubicKeyframe(peakX,  duration: 0.40)
                    CubicKeyframe(endX,   duration: 0.66)
                }
                // Parabola: rise to peak then fall past it. The
                // hang time at the apex sells the cartoon arc.
                KeyframeTrack(\.y) {
                    LinearKeyframe(0,     duration: 0.04)
                    CubicKeyframe(peakY,  duration: 0.36)
                    CubicKeyframe(endY,   duration: 0.70)
                }
                // Pop in big, hold at full size for a long beat,
                // then taper as it drifts.
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0,    duration: 0.04)
                    SpringKeyframe(1.2,  duration: 0.16, spring: .bouncy)
                    LinearKeyframe(1.0,  duration: 0.55)
                    CubicKeyframe(0.55,  duration: 0.35)
                }
                // Opacity holds at full visibility through almost
                // the entire trajectory, only fading in the last
                // ~25% so the burst stays visually loud.
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0,    duration: 0.04)
                    LinearKeyframe(1.0,  duration: 0.06)
                    LinearKeyframe(1.0,  duration: 0.70)
                    CubicKeyframe(0.0,   duration: 0.30)
                }
                // Tumble — multi-rotation spin so the pieces
                // visibly flip end-over-end on their way out.
                KeyframeTrack(\.spin) {
                    LinearKeyframe(0,                duration: 0.04)
                    CubicKeyframe(piece.totalSpin,   duration: 1.06)
                }
            }
    }

    /// Rectangles are taller than they are wide (streamer feel);
    /// every other shape is square.
    private var shapeAspect: CGFloat {
        switch piece.shape {
        case .rect: return 1.8
        default:    return 1.0
        }
    }

    @ViewBuilder
    private var confettiShape: some View {
        switch piece.shape {
        case .rect:
            RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                .fill(piece.color)
        case .circle:
            Circle()
                .fill(piece.color)
        case .triangle:
            ConfettiTriangle()
                .fill(piece.color)
        case .star:
            Image(systemName: "sparkle")
                .font(.system(size: piece.size + 1, weight: .heavy))
                .foregroundStyle(piece.color)
        }
    }
}

/// Equilateral confetti triangle — drawn directly so it scales
/// with the piece's frame instead of relying on a system glyph.
private struct ConfettiTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
