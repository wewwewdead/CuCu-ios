import SwiftUI

/// Single-post card. Two style variants:
///
///   - **`.full`** for feed + thread: rainbow leading stripe, round
///     avatar, decorative per-user display font for the handle, body
///     text, and an inline action row (heart / reply / star). Tappable
///     as a whole row to push the thread view, with the inner controls
///     escaping that gesture.
///   - **`.compact`** for the profile-page surface: drop the avatar,
///     tighten padding, cap the body at 4 lines so a column of recent
///     posts stays scannable.
///
/// The view itself is dumb — it doesn't fetch, mutate, or know which
/// feed it's part of. Tap intents flow up through closures the parent
/// feeds it (`onTap`, `onReply`, `onLike`, `onDelete`).
struct PostRowView: View {
    enum Style {
        case full
        case compact
    }

    let post: Post
    let style: Style
    let viewerHasLiked: Bool
    /// True when the current viewer authored this post — drives
    /// whether the overflow menu shows the destructive Delete item.
    let isOwnPost: Bool

    /// Optional override that paints the author's actual hero
    /// avatar in place of the deterministic letter avatar. Nil
    /// when the author hasn't published a profile or hasn't set a
    /// hero avatar — the letter fallback covers that case so every
    /// row stays renderable offline / pre-fetch.
    var avatarURL: String? = nil

    var onTap: () -> Void = {}
    var onLike: () -> Void = {}
    var onReply: () -> Void = {}
    var onDelete: () -> Void = {}
    var onReport: () -> Void = {}
    var onBlock: () -> Void = {}
    /// Fired when the viewer taps the avatar tile or the `@handle`
    /// text. Hosts hand a closure that pushes the author's
    /// `PublishedProfileView`.
    var onAuthorTap: () -> Void = {}

    /// Thread descendants want their own indent treatment. Reserved
    /// from the previous design — `.full` rows now render flat by
    /// default and ignore this flag. The compact-style branch still
    /// honours it for callers that wrap rows themselves.
    @Environment(\.cucuPostRowSuppressCard) private var suppressCard

    /// Process-wide app-chrome theme. Drives the in-card text colour
    /// so the row repaints cleanly as the viewer flips paper stock.
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        switch style {
        case .full:
            // Whole row is tappable to push the thread; inner buttons
            // (avatar, handle, heart, reply, overflow) escape this
            // outer button via their own `.buttonStyle(.plain)`.
            Button(action: onTap) {
                fullRowBody
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        case .compact:
            Button(action: onTap) {
                compactRowBody
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Full row (feed + thread)

    /// Notebook-page row: 4pt rainbow stripe on the leading edge, a
    /// round avatar, the author's handle in a deterministic playful
    /// display font with a decorative glyph, body copy, and an
    /// inline-left action cluster.
    private var fullRowBody: some View {
        HStack(alignment: .top, spacing: 0) {
            rainbowStripe
                .padding(.trailing, 14)
            avatarRound
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                fullHeader
                bodyText
                fullActionRow
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// Compact row stays card-friendly so existing callers (the
    /// profile posts list) keep their current visual register. We
    /// only redesigned the `.full` surface in this pass.
    private var compactRowBody: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                compactHeader
                bodyText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .contentShape(Rectangle())
    }

    // MARK: - Stripe

    /// 4pt-wide vertical rainbow stripe down the leading edge of the
    /// row, deterministic per author. Reads as the personal accent
    /// the reference image uses to mark each entry — the user picks
    /// a "stripe identity" by virtue of their handle. Capped at the
    /// top and bottom with a tiny rounding so it reads as a printed
    /// ribbon rather than a hard rectangle.
    private var rainbowStripe: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: Self.stripePalette(for: post.authorUsername),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 4)
            .frame(maxHeight: .infinity)
    }

    // MARK: - Avatar

    /// Round 40pt avatar. Falls back to a coloured monogram tile when
    /// no hero avatar is set on the author's published profile.
    private var avatarRound: some View {
        Button {
            CucuHaptics.selection()
            onAuthorTap()
        } label: {
            Group {
                if let urlString = avatarURL,
                   let url = CucuImageTransform.resized(urlString, square: 40) {
                    CachedRemoteImage(url: url, contentMode: .fill) {
                        roundLetterAvatar
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(chrome.theme.cardInkPrimary.opacity(0.18), lineWidth: 0.8)
                    )
                } else {
                    roundLetterAvatar
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View @\(post.authorUsername)'s profile")
    }

    private var roundLetterAvatar: some View {
        ZStack {
            Circle()
                .fill(Self.avatarColor(for: post.authorUsername))
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .strokeBorder(chrome.theme.cardInkPrimary.opacity(0.18), lineWidth: 0.8)
                )
            Text(Self.avatarInitial(for: post.authorUsername))
                .font(.custom("Caprasimo-Regular", size: 20))
                .foregroundStyle(chrome.theme.cardInkPrimary.opacity(0.85))
        }
    }

    // MARK: - Headers

    /// Reference-style header: handle in the app's default sans
    /// (Lexend) so every author reads in the same family. Trailing
    /// edge holds the relative timestamp and the overflow menu so
    /// the row's metadata reads in a single line.
    private var fullHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                CucuHaptics.selection()
                onAuthorTap()
            } label: {
                Text(post.authorUsername)
                    .font(.cucuSans(16, weight: .semibold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View @\(post.authorUsername)'s profile")

            if post.editedAt != nil {
                Text("· edited")
                    .font(.cucuSans(11, weight: .regular))
                    .foregroundStyle(chrome.theme.cardInkFaded)
            }
            Spacer(minLength: 6)
            Text(Self.shortTimestamp(for: post.createdAt))
                .font(.cucuSans(12, weight: .regular))
                .foregroundStyle(chrome.theme.cardInkFaded)
            overflowMenu
        }
    }

    /// Compact header keeps the editorial handle treatment so the
    /// profile posts column reads consistently with its surrounding
    /// chrome (which we didn't touch in this pass).
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("@\(post.authorUsername)")
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(chrome.theme.cardInkPrimary)
                if post.editedAt != nil {
                    Text("· edited")
                        .font(.cucuSans(11, weight: .regular))
                        .foregroundStyle(chrome.theme.cardInkFaded)
                }
                Spacer(minLength: 0)
            }
            Text(Self.relativeTimestamp(for: post.createdAt))
                .font(.cucuMono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(chrome.theme.cardInkFaded)
        }
    }

    // MARK: - Body

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

    // MARK: - Action row

    /// Inline-left cluster: heart + count, reply bubble + count,
    /// star + count. Reads as the reference image's bottom strip —
    /// every item carries its own count beside the glyph, so the
    /// row's social weight is legible at a glance.
    private var fullActionRow: some View {
        HStack(spacing: 22) {
            AnimatedHeartButton(
                isLiked: viewerHasLiked,
                likeCount: post.likeCount,
                onTap: onLike
            )

            Button {
                onReply()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(chrome.theme.cardInkMuted)
                    Text(Self.compactCount(post.replyCount))
                        .font(.cucuSans(13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(chrome.theme.cardInkMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply")

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var overflowMenu: some View {
        Menu {
            if isOwnPost {
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
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Static formatting helpers

    /// Long-form relative timestamp. Used by the compact style and
    /// the thread masthead. Uppercased units pair with the
    /// monospaced timestamp font so the row's metadata reads as a
    /// printer's spec line.
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

    /// Short-form relative timestamp ("1d", "6h", "32m") used inline
    /// in the new row header, matching the reference image's compact
    /// "1d ⋯" trailing edge.
    static func shortTimestamp(for date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 {
            return "\(Int(interval / 60))m"
        }
        if interval < 86_400 {
            return "\(Int(interval / 3600))h"
        }
        if interval < 7 * 86_400 {
            return "\(Int(interval / 86_400))d"
        }
        if interval < 30 * 86_400 {
            return "\(Int(interval / (7 * 86_400)))w"
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Compact like / reply counts ("1.2k", "23.4k", "1.1m") so the
    /// inline action row stays narrow even when a post catches fire.
    static func compactCount(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value < 10_000 {
            let k = Double(value) / 1000.0
            return String(format: "%.1fk", k)
        }
        if value < 1_000_000 {
            return "\(value / 1000)k"
        }
        let m = Double(value) / 1_000_000.0
        return String(format: "%.1fm", m)
    }

    /// Deterministic palette pick. Hashing the username (rather
    /// than `id`) means the same author always gets the same
    /// avatar tint across every row — a tiny visual signal of
    /// identity before the eye reaches the handle.
    static func avatarColor(for username: String) -> Color {
        palette[hash(username) % palette.count]
    }

    /// Avatar fill palette — paper-toned tiles tuned for the round
    /// monogram. Less saturated than the stripe palette so the
    /// avatar reads as a printed bookplate, not a brand swatch.
    private static let palette: [Color] = [
        .cucuRose, .cucuMossSoft, .cucuSky, .cucuBone,
        .cucuPaperDeep, .cucuAccentSoft, .cucuCardSoft, .cucuShell
    ]

    static func avatarInitial(for username: String) -> String {
        guard let first = username.first else { return "?" }
        return String(first).uppercased()
    }

    /// Vertical four-stop gradient palettes for the leading stripe.
    /// Each entry is a top→bottom colour stack; users land on one of
    /// these deterministically. Saturated picks intentionally — the
    /// stripe is the only spot of bold colour in the row.
    private static let stripePalettes: [[Color]] = [
        [.cucuCherry, .cucuShell, .cucuMatcha, .cucuCobalt],
        [.cucuCobalt, .cucuSky, .cucuMossSoft, .cucuMatcha],
        [.cucuMatcha, .cucuMossSoft, .cucuShell, .cucuCherry],
        [.cucuRoseStroke, .cucuShell, .cucuCherry, .cucuBurgundy],
        [.cucuBurgundy, .cucuCherry, .cucuRoseStroke, .cucuShell],
        [.cucuMidnight, .cucuCobalt, .cucuSky, .cucuMatcha],
        [.cucuMoss, .cucuMatcha, .cucuMossSoft, .cucuSky],
        [.cucuShell, .cucuRose, .cucuSky, .cucuCobalt]
    ]

    static func stripePalette(for username: String) -> [Color] {
        stripePalettes[hash(username) % stripePalettes.count]
    }

    /// Stable, well-spread username hash. `unicodeScalars.reduce`
    /// keeps the result deterministic across runs (Swift's
    /// `String.hashValue` is randomized per process).
    private static func hash(_ username: String) -> Int {
        let lower = username.lowercased()
        return lower.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    }
}

// MARK: - Card-suppression environment

/// Internal opt-out reserved for callers that need to wrap a row
/// in their own decoration. The `.full` row now renders flat by
/// default, so this only affects unusual hosts; left in place so
/// existing call sites compile.
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
// flavour of the celebration.

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
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Button {
            direction = isLiked ? .unlike : .like
            switch direction {
            case .like:   CucuHaptics.soft()
            case .unlike: CucuHaptics.selection()
            }
            tick &+= 1
            onTap()
        } label: {
            HStack(spacing: 6) {
                heartCluster
                    .frame(width: 22, height: 22)
                    .zIndex(10)
                if likeCount > 0 {
                    Text(PostRowView.compactCount(likeCount))
                        .font(.cucuSans(13, weight: .medium))
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

    private var heartCluster: some View {
        ZStack {
            HeartHaloRing(tick: tick, flavour: direction)
            HeartConfettiBurst(tick: tick, flavour: direction)

            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isLiked ? Color.cucuCherry : chrome.theme.cardInkMuted)
                .keyframeAnimator(
                    initialValue: HeartPopValues(),
                    trigger: tick
                ) { content, value in
                    content
                        .scaleEffect(value.scale)
                        .rotationEffect(.degrees(value.rotation))
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        if direction == .like {
                            CubicKeyframe(0.55, duration: 0.07)
                            SpringKeyframe(1.75, duration: 0.20, spring: .bouncy)
                            SpringKeyframe(0.88, duration: 0.14, spring: .smooth)
                            SpringKeyframe(1.06, duration: 0.14, spring: .smooth)
                            SpringKeyframe(1.0,  duration: 0.16, spring: .smooth)
                        } else {
                            CubicKeyframe(0.65, duration: 0.08)
                            SpringKeyframe(1.18, duration: 0.16, spring: .bouncy)
                            SpringKeyframe(0.94, duration: 0.12, spring: .smooth)
                            SpringKeyframe(1.0,  duration: 0.16, spring: .smooth)
                        }
                    }
                    KeyframeTrack(\.rotation) {
                        if direction == .like {
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

private struct HeartPopValues {
    var scale: CGFloat = 1.0
    var rotation: Double = 0
}

// MARK: - Effect views

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

private struct HeartConfettiBurst: View {
    let tick: Int
    let flavour: HeartTapFlavour

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

    static func piece(at index: Int, flavour: HeartTapFlavour) -> ConfettiPiece {
        switch flavour {
        case .like:   return likePieces[index]
        case .unlike: return unlikePieces[index]
        }
    }

    private static let likePieces: [ConfettiPiece] = [
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

private struct ConfettiPiece {
    let angle: Double
    let radius: CGFloat
    let peakRise: CGFloat
    let gravityDrop: CGFloat
    let totalSpin: Double
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
                KeyframeTrack(\.x) {
                    LinearKeyframe(0,     duration: 0.04)
                    CubicKeyframe(peakX,  duration: 0.40)
                    CubicKeyframe(endX,   duration: 0.66)
                }
                KeyframeTrack(\.y) {
                    LinearKeyframe(0,     duration: 0.04)
                    CubicKeyframe(peakY,  duration: 0.36)
                    CubicKeyframe(endY,   duration: 0.70)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0,    duration: 0.04)
                    SpringKeyframe(1.2,  duration: 0.16, spring: .bouncy)
                    LinearKeyframe(1.0,  duration: 0.55)
                    CubicKeyframe(0.55,  duration: 0.35)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0,    duration: 0.04)
                    LinearKeyframe(1.0,  duration: 0.06)
                    LinearKeyframe(1.0,  duration: 0.70)
                    CubicKeyframe(0.0,   duration: 0.30)
                }
                KeyframeTrack(\.spin) {
                    LinearKeyframe(0,                duration: 0.04)
                    CubicKeyframe(piece.totalSpin,   duration: 1.06)
                }
            }
    }

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
