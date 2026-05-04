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

    var onTap: () -> Void = {}
    var onLike: () -> Void = {}
    var onReply: () -> Void = {}
    var onDelete: () -> Void = {}
    /// Phase 7 — bubbles up to the parent so it can present the
    /// shared `ReportPostSheet`. The row stays dumb; the sheet
    /// owns auth-gating + service calls + the "already reported"
    /// path.
    var onReport: () -> Void = {}
    /// Phase 7 — bubbles up so the parent can present a
    /// destructive confirmation dialog and, on confirm, call
    /// `UserBlockService.block` plus scrub the loaded view via
    /// `removeAllByAuthor(authorId:)`. The row doesn't talk to
    /// the service directly because the post-block UI mutation
    /// lives on the parent VM.
    var onBlock: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                if style == .full {
                    avatar
                }
                VStack(alignment: .leading, spacing: 6) {
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
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Self.avatarColor(for: post.authorUsername))
                .frame(width: 36, height: 36)
            Text(Self.avatarInitial(for: post.authorUsername))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("@\(post.authorUsername)")
                .font(.subheadline.weight(.semibold))
            Text("·")
                .foregroundStyle(.secondary)
            Text(Self.relativeTimestamp(for: post.createdAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if post.editedAt != nil {
                Text("· edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if style == .full {
                overflowMenu
            }
        }
    }

    private var bodyText: some View {
        // `.body` matches platform reading size; selectable so a
        // long-press can pull text out of a post the same way the
        // system Mail app does.
        Text(post.body)
            .font(.body)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(style == .compact ? 4 : nil)
            .truncationMode(.tail)
    }

    private var actionRow: some View {
        HStack(spacing: 24) {
            // Heart / like — fills + tints red when the viewer has
            // liked this post. `Button` rather than tap-gesture so
            // VoiceOver picks up the action.
            Button {
                onLike()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewerHasLiked ? "heart.fill" : "heart")
                        .foregroundStyle(viewerHasLiked ? Color.red : Color.secondary)
                    if post.likeCount > 0 {
                        Text("\(post.likeCount)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewerHasLiked ? "Unlike" : "Like")

            // Reply
            Button {
                onReply()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.right")
                        .foregroundStyle(.secondary)
                    if post.replyCount > 0 {
                        Text("\(post.replyCount)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reply")

            Spacer()
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                onReport()
            } label: {
                Label("Report", systemImage: "flag")
            }
            // Block is destructive — blocking a stranger from a
            // single post is a strong action; the role color
            // signals that, and the parent's confirmation dialog
            // adds the second-step guard.
            Button(role: .destructive) {
                onBlock()
            } label: {
                Label("Block @\(post.authorUsername)", systemImage: "hand.raised")
            }
            if isOwnPost {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        // Stop a Menu tap from also firing the row's outer
        // Button — without this the user opens the menu *and*
        // pushes the thread view in one tap.
        .buttonStyle(.plain)
    }

    // MARK: - Layout helpers

    private var paddingForStyle: EdgeInsets {
        switch style {
        case .full:
            return EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        case .compact:
            return EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        }
    }

    // MARK: - Static formatting helpers

    /// Relative timestamp tuned for social text:
    ///   - <1m → "just now"
    ///   - <1h → "Xm"
    ///   - <24h → "Xh"
    ///   - <7d → "Xd"
    ///   - else → absolute date (medium style)
    static func relativeTimestamp(for date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 {
            return "\(Int(interval / 60))m"
        }
        if interval < 86_400 {
            return "\(Int(interval / 3600))h"
        }
        if interval < 7 * 86_400 {
            return "\(Int(interval / 86_400))d"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// Deterministic palette pick. Hashing the username (rather
    /// than `id`) means the same author always gets the same
    /// colour across every row — a tiny visual signal of identity
    /// before the eye reaches the `@handle`.
    static func avatarColor(for username: String) -> Color {
        // Stable across runs: sum the unicode scalars rather than
        // using `String.hashValue`, which is randomized per
        // process for hash-flooding defense.
        let lower = username.lowercased()
        let sum = lower.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    private static let palette: [Color] = [
        Color(red: 0.93, green: 0.42, blue: 0.45),
        Color(red: 0.95, green: 0.66, blue: 0.27),
        Color(red: 0.42, green: 0.71, blue: 0.46),
        Color(red: 0.34, green: 0.62, blue: 0.85),
        Color(red: 0.62, green: 0.45, blue: 0.85),
        Color(red: 0.85, green: 0.45, blue: 0.72),
        Color(red: 0.30, green: 0.65, blue: 0.69),
        Color(red: 0.55, green: 0.55, blue: 0.55)
    ]

    static func avatarInitial(for username: String) -> String {
        guard let first = username.first else { return "?" }
        return String(first).uppercased()
    }
}
