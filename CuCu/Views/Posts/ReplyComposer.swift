import SwiftUI

/// Thin wrapper over `ComposePostSheet` that presets the reply
/// context: `parentId` plus a small preview of the post being
/// replied to. Lives as its own view so call sites read as
/// `ReplyComposer(parentPost:)` instead of constructing a
/// `ComposePostSheet.ParentPreview` by hand each time.
struct ReplyComposer: View {
    let parentPost: Post
    var onPosted: (Post) -> Void = { _ in }

    var body: some View {
        ComposePostSheet(
            parentId: parentPost.id,
            parentPreview: ComposePostSheet.ParentPreview(
                authorUsername: parentPost.authorUsername,
                bodyPreview: Self.previewBody(parentPost.body)
            ),
            onPosted: onPosted
        )
    }

    /// First 80 characters of the parent body, single line, with a
    /// trailing ellipsis when truncated. Matches the spec for the
    /// reply preview header in the compose sheet.
    private static func previewBody(_ body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }
}
