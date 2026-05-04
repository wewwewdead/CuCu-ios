import SwiftUI

/// Per-user posts surface — wraps `PostFeedView` with a
/// `.byAuthor` feed source, an `@username` title, and a
/// compose-button gate that only fires for the current user.
///
/// Pushed from the Posts section under
/// `PublishedProfileView` ("View all"). The reused `PostFeedView`
/// brings pagination, like state hydration, optimistic delete, and
/// thread-tap navigation along for the ride — this file just
/// configures the inputs.
struct UserPostsListView: View {
    let authorId: String
    /// Username to render in the nav title. Optional because the
    /// fetch path (`PublishedProfileView`) already has it; keeping
    /// it loose so a future deep link by `authorId` alone can still
    /// land here without a pre-fetch.
    let displayUsername: String?

    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        let isCurrentUser = auth.currentUser?.id.lowercased() == authorId.lowercased()
        PostFeedView(
            feedSource: .byAuthor(authorId),
            title: navigationTitle(isCurrentUser: isCurrentUser),
            showsCompose: isCurrentUser
        )
    }

    private func navigationTitle(isCurrentUser: Bool) -> String {
        if isCurrentUser { return "Your posts" }
        if let displayUsername, !displayUsername.isEmpty {
            return "@\(displayUsername)"
        }
        return "Posts"
    }
}
