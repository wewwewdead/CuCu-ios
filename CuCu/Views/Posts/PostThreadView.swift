import SwiftUI

/// Thread detail view, lazy-load era. Renders the root + the
/// first page of direct replies on push, then expands deeper
/// subtrees only when the user taps "View N replies" /
/// "Show more replies".
///
/// The view is a thin renderer over
/// `PostThread.flattenForRender()` — the model decides the row
/// stream (posts + affordances), the view dispatches on each
/// `RenderItem` case. No tree traversal lives in the view.
struct PostThreadView: View {
    @Environment(AuthViewModel.self) private var auth
    let rootId: String

    @State private var vm = PostThreadViewModel()
    @State private var replyTarget: Post? = nil
    /// Phase 7 — report sheet target.
    @State private var reportTarget: Post? = nil
    /// Phase 7 — block confirmation dialog target.
    @State private var blockTarget: Post? = nil
    @State private var toastMessage: String? = nil

    /// 12pt indent step per visual depth. Both posts and the
    /// affordance buttons run through this so a "View N replies"
    /// row visually nests under its parent post.
    private let indentStep: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .navigationTitle("Thread")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            // Bottom bar always targets the root post — per the
            // spec, this is the "Reply to thread" affordance,
            // not "reply to whatever's deepest visible".
            if let root = vm.thread?.root {
                replyToThreadBar(root: root)
            }
        }
        .sheet(item: $replyTarget) { parent in
            ReplyComposer(parentPost: parent) { newReply in
                vm.replyPosted(newReply)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $reportTarget) { post in
            ReportPostSheet(post: post) { outcome in
                handleReportOutcome(outcome)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            blockTarget.map { "Block @\($0.authorUsername)?" } ?? "Block user?",
            isPresented: Binding(
                get: { blockTarget != nil },
                set: { if !$0 { blockTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: blockTarget
        ) { post in
            Button("Block", role: .destructive) {
                Task { await handleBlock(post) }
            }
            Button("Cancel", role: .cancel) { blockTarget = nil }
        } message: { post in
            Text("You won't see @\(post.authorUsername)'s posts or replies.")
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { vm.lastDeleteError != nil },
                set: { if !$0 { vm.clearDeleteError() } }
            )
        ) {
            Button("OK", role: .cancel) { vm.clearDeleteError() }
        } message: {
            Text(vm.lastDeleteError ?? "")
        }
        .cucuToast(message: $toastMessage)
        .task { await vm.load(rootId: rootId) }
    }

    private func handleReportOutcome(_ outcome: ReportPostSheet.Outcome) {
        switch outcome {
        case .submitted:
            toastMessage = "Reported. Thanks — we review every report."
        case .alreadyReported:
            toastMessage = "Already reported. We'll review it soon."
        case .cancelled:
            break
        }
    }

    private func handleBlock(_ post: Post) async {
        blockTarget = nil
        do {
            try await UserBlockService().block(userId: post.authorId)
            vm.removeAllByAuthor(authorId: post.authorId)
            toastMessage = "Blocked @\(post.authorUsername)"
        } catch let err as UserBlockError {
            toastMessage = err.errorDescription ?? "Couldn't block right now."
        } catch {
            toastMessage = error.localizedDescription
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch vm.status {
        case .loading where vm.thread == nil:
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        case .error(let message):
            errorState(message)
        case .loading, .loaded:
            if let thread = vm.thread {
                threadColumn(thread)
            } else {
                Color.clear
            }
        }
    }

    private func threadColumn(_ thread: PostThread) -> some View {
        // `flattenForRender` is the single source of truth for
        // row order — every affordance the view needs to draw is
        // already interleaved between the posts. The view's job
        // is to map each `RenderItem` to a SwiftUI view; it
        // doesn't reason about indent rules or which subtree is
        // closing where.
        let items = thread.flattenForRender()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    renderItem(item, in: thread)
                    Divider()
                        .padding(.leading, dividerLeading(for: item))
                }
            }
        }
    }

    @ViewBuilder
    private func renderItem(_ item: PostThread.RenderItem, in thread: PostThread) -> some View {
        switch item {
        case .post(let post, let depth, _):
            postRow(post, depth: depth, isRoot: post.id == thread.root.id)
        case .viewReplies(let parentId, let count, let depth):
            viewRepliesButton(parentId: parentId, count: count, depth: depth)
        case .loadingChildren(_, let depth):
            inlineLoading(depth: depth)
        case .showMoreSiblings(let parentId, let depth):
            showMoreButton(parentId: parentId, depth: depth)
        }
    }

    // MARK: - Rows

    private func postRow(_ post: Post, depth: Int, isRoot: Bool) -> some View {
        // Root reads slightly more prominent — larger body font
        // and a touch more vertical padding — so the thread
        // visually opens with "this conversation started with…".
        PostRowView(
            post: post,
            style: .full,
            viewerHasLiked: vm.viewerLikedIds.contains(post.id),
            isOwnPost: post.authorId == auth.currentUser?.id.lowercased(),
            onTap: {},
            onLike: { vm.toggleLike(postId: post.id) },
            onReply: { replyTarget = post },
            // Root delete tears the thread; route only via the
            // feed for now. Descendant deletes go through the
            // VM's optimistic flow.
            onDelete: { if !isRoot { vm.delete(postId: post.id) } },
            onReport: { reportTarget = post },
            onBlock: { blockTarget = post }
        )
        .font(isRoot ? .title3 : .body)
        .padding(.vertical, isRoot ? 4 : 0)
        .padding(.leading, CGFloat(depth) * indentStep)
    }

    private func viewRepliesButton(parentId: String, count: Int, depth: Int) -> some View {
        Button {
            Task { await vm.expandReplies(for: parentId) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                Text("View \(count) \(count == 1 ? "reply" : "replies")")
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * indentStep)
    }

    private func showMoreButton(parentId: String, depth: Int) -> some View {
        Button {
            Task { await vm.loadMoreSiblings(under: parentId) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                Text("Show more replies")
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * indentStep)
    }

    private func inlineLoading(depth: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading replies…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .padding(.leading, CGFloat(depth) * indentStep)
    }

    /// Indent the dividers a touch beyond the row content so
    /// they read as "this row's bottom edge" rather than a
    /// full-width section break. Affordance rows skip the
    /// divider treatment by leading-padding the divider all the
    /// way past the affordance text.
    private func dividerLeading(for item: PostThread.RenderItem) -> CGFloat {
        switch item {
        case .post(_, let depth, _):
            return CGFloat(depth) * indentStep + 16
        case .viewReplies(_, _, let depth),
             .loadingChildren(_, let depth),
             .showMoreSiblings(_, let depth):
            return CGFloat(depth) * indentStep + 16
        }
    }

    // MARK: - Bottom bar

    private func replyToThreadBar(root: Post) -> some View {
        Button {
            replyTarget = root
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.right")
                Text("Reply to thread")
                    .font(.callout)
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to thread")
    }

    // MARK: - Error state

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load this thread")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await vm.load(rootId: rootId) }
            } label: {
                Text("Try again")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
        }
    }
}
