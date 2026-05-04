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

    /// Drives the heart-pulse pop on tap. Set true at the action
    /// site, cleared after a short delay so the spring releases.
    @State private var heartPulse: Bool = false

    /// Thread descendants want their own card-less treatment so the
    /// indent spine reads as the visual structure. PostThreadView
    /// flips this on; every other surface (feed, profile list)
    /// leaves it at the default and gets the standard floating card.
    @Environment(\.cucuPostRowSuppressCard) private var suppressCard

    var body: some View {
        Group {
            if style == .full && !suppressCard {
                Button(action: onTap) {
                    rowBody
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cucuCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.cucuInkRule, lineWidth: 1)
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
        Group {
            if let urlString = avatarURL,
               !urlString.isEmpty,
               let url = URL(string: urlString) {
                CachedRemoteImage(url: url, contentMode: .fill) {
                    letterAvatar
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.cucuInk.opacity(0.35), lineWidth: 0.8)
                )
            } else {
                letterAvatar
            }
        }
        .accessibilityHidden(true)
    }

    private var letterAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.avatarColor(for: post.authorUsername))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.cucuInk.opacity(0.35), lineWidth: 0.8)
                )
            Text(Self.avatarInitial(for: post.authorUsername))
                .font(.cucuEditorial(20, italic: true))
                .foregroundStyle(Color.cucuInk)
        }
    }

    /// Two-line header — username on top in serif semibold,
    /// timestamp on its own line in tracked uppercased mono. The
    /// vertical split frees the body from a single long inline run
    /// of metadata and gives the row a printed-spec rhythm.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("@\(post.authorUsername)")
                    .font(.cucuSerif(15, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                if post.editedAt != nil {
                    Text("· edited")
                        .font(.cucuEditorial(11, italic: true))
                        .foregroundStyle(Color.cucuInkFaded)
                }
                Spacer(minLength: 0)
                if style == .full {
                    overflowMenu
                }
            }
            Text(Self.relativeTimestamp(for: post.createdAt))
                .font(.cucuMono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(Color.cucuInkFaded)
        }
    }

    private var bodyText: some View {
        Text(post.body)
            .font(.cucuSans(15))
            .foregroundStyle(Color.cucuInk)
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
                        .foregroundStyle(Color.cucuInkFaded)
                    if post.replyCount > 0 {
                        Text("\(post.replyCount)")
                            .font(.cucuMono(11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.cucuInkSoft)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply")

            // Heart / like — fills + tints cherry when liked. Pop
            // animation fires on each tap.
            Button {
                if viewerHasLiked {
                    CucuHaptics.selection()
                } else {
                    CucuHaptics.soft()
                }
                heartPulse = true
                Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    heartPulse = false
                }
                onLike()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewerHasLiked ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(viewerHasLiked ? Color.cucuCherry : Color.cucuInkFaded)
                        .scaleEffect(heartPulse ? 1.18 : 1.0)
                        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: heartPulse)
                    if post.likeCount > 0 {
                        Text("\(post.likeCount)")
                            .font(.cucuMono(11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.cucuInkSoft)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewerHasLiked ? "Unlike" : "Like")
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
                .foregroundStyle(Color.cucuInkFaded)
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
