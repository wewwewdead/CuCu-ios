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
    @Environment(\.dismiss) private var dismiss
    let rootId: String
    /// Optional callback fired when the user deletes the *root*
    /// of this thread. The host (typically `PostFeedView`) handles
    /// the server-side delete + feed scrub there so the
    /// rollback snapshot lives next to the column it'd be
    /// re-inserted into. When nil, the view falls back to a
    /// fire-and-forget service call before dismissing.
    let onRootDeleted: ((Post) -> Void)?

    @State private var vm = PostThreadViewModel()
    /// Process-wide app-chrome theme. Reading `chrome.theme` re-renders
    /// the page on every `setTheme` because `AppChromeStore` is
    /// `@Observable`. The thread inherits whatever stock the user
    /// picked from the feed/explore picker — there is no per-page
    /// override, by design (the choice is "what is the room painted
    /// in," not "what is *this* page").
    @State private var chrome = AppChromeStore.shared
    @State private var replyTarget: Post? = nil
    /// Phase 7 — report sheet target.
    @State private var reportTarget: Post? = nil
    /// Phase 7 — block confirmation dialog target.
    @State private var blockTarget: Post? = nil
    @State private var toastMessage: String? = nil
    /// Process-wide avatar dictionary shared with `PostFeedView` —
    /// jumping into a thread for an author the feed already resolved
    /// reads from the same cache instead of re-fetching. The store
    /// owns the debounce + completed-set bookkeeping; views read
    /// `overrides` and call `requestLazy`.
    private var avatarStore: AvatarOverrideStore { AvatarOverrideStore.shared }
    /// Drives the anticipation scale-up on the row about to be
    /// deleted. The thread view animates one row at a time, so a
    /// single optional id is enough.
    @State private var poppingPostId: String? = nil
    /// Set when the root-delete sequence wants the root card to
    /// vanish from the rendered list while `vm.thread` is still
    /// non-nil. Lets the squish-fade transition fire inside the
    /// LazyVStack instead of being shortcut by the `.unavailable`
    /// branch when the VM clears `thread` itself.
    @State private var hiddenRootId: String? = nil
    /// Drives the page-closing flourish on root delete: a brief
    /// scale-down + fade applied to the whole scroller right
    /// before `dismiss()` so the thread reads as visually
    /// "closing" before the navigation slide reveals the feed.
    @State private var threadRetreating: Bool = false
    /// Push target for the "tap a post's avatar / @handle"
    /// intent. Lets visitors jump from a reply row directly to
    /// that author's published profile without having to
    /// backtrack to a feed first. Wrapped in an Identifiable
    /// struct so `.navigationDestination(item:)` can drive the
    /// push — see `AuthorRoute` at the bottom of this file.
    @State private var profileDestination: AuthorRoute? = nil

    init(rootId: String, onRootDeleted: ((Post) -> Void)? = nil) {
        self.rootId = rootId
        self.onRootDeleted = onRootDeleted
    }

    /// 12pt indent step per visual depth. Both posts and the
    /// affordance buttons run through this so a "View N replies"
    /// row visually nests under its parent post.
    private let indentStep: CGFloat = 12

    var body: some View {
        ZStack {
            CucuRefinedPageBackdrop()
            VStack(spacing: 0) {
                content
            }
        }
        .cucuRefinedNav("Thread")
        .safeAreaInset(edge: .bottom) {
            // Bottom bar always targets the root post — per the
            // spec, this is the "Reply to thread" affordance,
            // not "reply to whatever's deepest visible". Hidden
            // once the user starts the root-delete sequence so
            // the closing flourish reads cleanly without a stray
            // input pinned to the bottom.
            if let root = vm.thread?.root, hiddenRootId == nil {
                replyToThreadBar(root: root)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .sheet(item: $replyTarget) { parent in
            ReplyComposer(parentPost: parent) { newReply in
                vm.replyPosted(newReply)
                // Newly-inserted reply will fire its own
                // `.onAppear` and pull its author's avatar
                // through the lazy path; nothing eager to do.
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
                CucuHaptics.delete()
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
        .navigationDestination(item: $profileDestination) { route in
            PublishedProfileView(username: route.username)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .cucuProfileAvatarDidChange)
        ) { notification in
            guard let username = CucuProfileEvents.avatarUsername(from: notification) else {
                return
            }
            Task { await avatarStore.refresh(username: username) }
        }
        .task(
            id: PostThreadLoadKey(
                rootId: rootId,
                viewerId: auth.currentUser?.id.lowercased()
            )
        ) {
            // Don't reset the shared avatar store on viewer change
            // here — the feed underneath this thread is mounted on
            // the same store and its own viewer-change task already
            // owns the wipe. Resetting again would erase entries the
            // feed just paid for.
            await vm.reloadForViewerChange(rootId: rootId)
        }
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
            loadingScrollContent
        case .error(let message):
            errorState(message)
        case .loading, .loaded:
            if let thread = vm.thread {
                threadColumn(thread)
            } else {
                unavailableState
            }
        }
    }

    /// First-load surface — pulsing skeleton cards in the same
    /// indented geometry the real thread will paint into. Reflows
    /// are minimal because the structure is already rendered when
    /// the data lands.
    private var loadingScrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                skeletonColumn
                    .padding(.top, 14)
            }
            .padding(.bottom, 32)
        }
    }

    private func threadColumn(_ thread: PostThread) -> some View {
        // `flattenForRender` is the single source of truth for
        // row order — every affordance the view needs to draw is
        // already interleaved between the posts. The view's job
        // is to map each `RenderItem` to a SwiftUI view; it
        // doesn't reason about indent rules or which subtree is
        // closing where.
        //
        // The editorial masthead sits at the top of the same
        // scroller (rather than pinning to the nav bar) so the
        // page reads as a magazine spread that gives the thread
        // its own opening real estate — same idiom the feed uses.
        //
        // The `hiddenRootId` filter is what lets the root-delete
        // sequence run the squish-fade transition: we drop the
        // root from the rendered items while keeping `vm.thread`
        // intact, so the LazyVStack registers a removal (firing
        // `.cucuPostPop`) instead of the whole branch flipping to
        // `unavailableState`.
        let items = thread.flattenForRender().filter { item in
            if let hidden = hiddenRootId,
               case .post(let post, _, _) = item,
               post.id == hidden {
                return false
            }
            return true
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                threadMasthead(thread)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(items) { item in
                    renderItem(item, in: thread)
                        .transition(.cucuPostPop)
                        .zIndex(isPopping(item) ? 1 : 0)
                    if shouldDrawDivider(after: item) {
                        Rectangle()
                            .fill(chrome.theme.rule)
                            .frame(height: 1)
                            .padding(.leading, dividerLeading(for: item))
                    }
                }
                endOfThread
            }
            .animation(.spring(response: 0.46, dampingFraction: 0.7), value: items.map(\.id))
            .padding(.vertical, 4)
            .padding(.bottom, 16)
        }
        .scaleEffect(threadRetreating ? 0.985 : 1.0, anchor: .top)
        .opacity(threadRetreating ? 0 : 1)
    }

    // MARK: - Editorial masthead
    //
    // Premium pass: the thread opens with an editorial masthead in
    // the same vocabulary the feed uses — tracked-mono "REPLY THREAD"
    // spec line on the leading edge, a printer's-folio reply count
    // on the trailing edge, a Fraunces-italic display title carrying
    // the root author's handle, an editorial subtitle in the same
    // italic, and a fleuron rule that hands off to the journal-entry
    // caption above the root card. Scrolls with the content rather
    // than pinning, so the thread reads as a magazine spread that
    // gives the conversation its own opening real estate.

    /// Tracked editorial masthead. Theme-aware via `chrome.theme.*`
    /// so the spec line + display title repaint cleanly when the
    /// viewer flips paper stock from the feed underneath. Bails to
    /// an empty view if the root post hasn't materialised yet —
    /// the masthead's whole identity is the root's @handle, so
    /// painting it without a root would just be a blank title.
    @ViewBuilder
    private func threadMasthead(_ thread: PostThread) -> some View {
        if let root = thread.root {
            let stamp = PostRowView.relativeTimestamp(for: root.createdAt)
            let directReplies = root.replyCount
            let folio = directReplies == 0
                ? "№ ROOT"
                : "№ \(String(format: "%03d", directReplies)) REPL\(directReplies == 1 ? "Y" : "IES")"
            mastheadBody(authorHandle: root.authorUsername, stamp: stamp, folio: folio)
        }
    }

    /// Concrete masthead layout. Pulled out of `threadMasthead` so
    /// the `@ViewBuilder` branch above stays a clean if-let without
    /// a giant inline body.
    private func mastheadBody(authorHandle: String, stamp: String, folio: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.cucuCherry)
                        .frame(width: 5, height: 5)
                    Text("REPLY THREAD")
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(2.4)
                        .foregroundStyle(chrome.theme.inkMuted)
                    Text("·")
                        .font(.cucuMono(10, weight: .medium))
                        .foregroundStyle(chrome.theme.inkFaded)
                    Text(stamp)
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(2.0)
                        .foregroundStyle(chrome.theme.inkFaded)
                }
                Spacer(minLength: 8)
                Text(folio)
                    .font(.cucuMono(10, weight: .medium))
                    .tracking(2.4)
                    .foregroundStyle(chrome.theme.inkFaded)
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(authorHandle)
                    .font(.custom("Caprasimo-Regular", size: 32))
                    .foregroundStyle(chrome.theme.inkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 6)
            }
        }
    }

    /// Skip the heavy hairline rule between rows when the row above
    /// is the thread root — the root already gets its own emphasized
    /// stripe + bottom rule treatment, so a stacked hairline below
    /// would double-rule the surface. Every non-root row keeps the
    /// per-row break that separates entries in the thread.
    private func shouldDrawDivider(after item: PostThread.RenderItem) -> Bool {
        if case .post(let post, _, _) = item, post.id == vm.thread?.rootId {
            return false
        }
        return true
    }

    @ViewBuilder
    private func renderItem(_ item: PostThread.RenderItem, in thread: PostThread) -> some View {
        switch item {
        case .post(let post, let depth, _):
            postRow(post, depth: depth, isRoot: post.id == thread.rootId)
        case .viewReplies(let parentId, let count, let depth):
            viewRepliesButton(parentId: parentId, count: count, depth: depth)
        case .loadingChildren(_, let depth):
            inlineLoading(depth: depth)
        case .showMoreSiblings(let parentId, let depth):
            showMoreButton(parentId: parentId, depth: depth)
        case .hideReplies(let parentId, let depth):
            hideRepliesButton(parentId: parentId, depth: depth)
        }
    }

    // MARK: - Rows

    private func postRow(_ post: Post, depth: Int, isRoot: Bool) -> some View {
        let row = PostRowView(
            post: post,
            style: .full,
            viewerHasLiked: vm.viewerLikedIds.contains(post.id),
            isOwnPost: post.authorId == auth.currentUser?.id.lowercased(),
            avatarURL: avatarStore.avatarURL(for: post.authorUsername),
            onTap: {},
            onLike: { vm.toggleLike(postId: post.id) },
            onReply: { replyTarget = post },
            onDelete: { handleDelete(post) },
            onReport: { reportTarget = post },
            onBlock: { blockTarget = post },
            onAuthorTap: {
                profileDestination = AuthorRoute(
                    username: post.authorUsername
                )
            }
        )

        return Group {
            if isRoot {
                // Root entry sits at the top of the thread without
                // a lifted card — the flat row vocabulary now does
                // the visual work, and a tracked-mono "ROOT ENTRY"
                // caption above the row gives it just enough
                // ceremony to read as the conversation's anchor.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.cucuCherry)
                            .frame(width: 4, height: 4)
                        Text("ROOT ENTRY")
                            .font(.cucuMono(10, weight: .medium))
                            .tracking(2.4)
                            .foregroundStyle(chrome.theme.inkFaded)
                        Spacer(minLength: 8)
                        Text(PostRowView.shortTimestamp(for: post.createdAt))
                            .font(.cucuMono(10, weight: .medium))
                            .tracking(1.8)
                            .foregroundStyle(chrome.theme.inkFaded)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    row
                    Rectangle()
                        .fill(chrome.theme.inkFaded.opacity(0.35))
                        .frame(height: 1)
                        .padding(.horizontal, 18)
                        .padding(.top, 2)
                }
            } else {
                // Reply rows inherit the same flat row geometry,
                // with a thin indent spine on the leading edge that
                // reads as the parent → child relationship without
                // the heavy left-margin shift the previous design
                // used. The spine sits inside the row's own
                // horizontal padding so the rainbow stripe still
                // anchors the row's identity at depth 0.
                row
                    .padding(.leading, CGFloat(depth) * indentStep)
                    .overlay(alignment: .leading) {
                        if depth > 0 {
                            Rectangle()
                                .fill(chrome.theme.rule)
                                .frame(width: 1)
                                .padding(.leading, CGFloat(depth) * indentStep + 6)
                                .padding(.vertical, 6)
                        }
                    }
            }
        }
        .scaleEffect(poppingPostId == post.id ? 1.06 : 1.0, anchor: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: poppingPostId)
        .onAppear { avatarStore.requestLazy(for: post.authorUsername) }
    }

    /// True when this render item corresponds to the row currently
    /// in its anticipation-pop phase — used to lift it above its
    /// neighbours while it scales so the swell isn't clipped.
    private func isPopping(_ item: PostThread.RenderItem) -> Bool {
        if case .post(let post, _, _) = item, post.id == poppingPostId {
            return true
        }
        return false
    }

    /// Two paths depending on what's being deleted:
    ///
    /// **Reply** — anticipation pop on the row, then the squish-fade
    /// removal runs inside a bouncy spring so the surrounding rows
    /// snap up to close the gap. `vm.delete` owns the server call
    /// and the rollback snapshot for this path.
    ///
    /// **Root** — the whole thread is about to evaporate. We hold
    /// the same anticipation pop, then *visually* remove the root
    /// (via `hiddenRootId`, leaving `vm.thread` intact so the
    /// LazyVStack fires the squish transition rather than swapping
    /// to `unavailableState`). After the squish, a brief retreat
    /// flourish — a small scale-down + fade applied to the whole
    /// scroller — reads as the journal entry being closed. We then
    /// delegate the server delete + feed scrub to the host via
    /// `onRootDeleted` (so the rollback snapshot lives where the
    /// re-insert would land), and `dismiss()` triggers the standard
    /// navigation pop back to the feed.
    private func handleDelete(_ post: Post) {
        CucuHaptics.delete()
        let isRoot = post.id == vm.thread?.rootId

        if isRoot {
            poppingPostId = post.id
            Task { @MainActor in
                // Anticipation hold — the row's `.scaleEffect`
                // swells before we pull it from the list.
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.spring(response: 0.40, dampingFraction: 0.62)) {
                    hiddenRootId = post.id
                }
                // Wait for the squish to mostly settle before
                // closing the page — the eye reads ~80% as
                // complete and a dragged-out tail muddies the
                // hand-off into the nav pop.
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.easeOut(duration: 0.22)) {
                    threadRetreating = true
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
                poppingPostId = nil
                if let onRootDeleted {
                    onRootDeleted(post)
                } else {
                    // No host to delegate to (deep-link entry,
                    // moderation queue, etc.): fire the delete
                    // ourselves and accept that we can't
                    // surface a rollback — the view is leaving.
                    // The broadcast still goes out so any list
                    // surface holding this id locally scrubs it.
                    let target = post
                    CucuPostEvents.broadcastDeletion(postId: target.id)
                    Task.detached {
                        try? await PostService().deletePost(
                            postId: target.id,
                            authorId: target.authorId
                        )
                    }
                }
                dismiss()
            }
        } else {
            poppingPostId = post.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 130_000_000)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                    vm.delete(postId: post.id)
                }
                poppingPostId = nil
                // Replies don't appear in the global feed, but a
                // per-user "Posts" surface or a profile column
                // might be holding this id — broadcast so they
                // can scrub without a refetch.
                CucuPostEvents.broadcastDeletion(postId: post.id)
            }
        }
    }

    private func viewRepliesButton(parentId: String, count: Int, depth: Int) -> some View {
        Button {
            CucuHaptics.soft()
            // Replies revealed by `expandReplies` paint into the
            // LazyVStack and each new row's `.onAppear` pulls its
            // author's avatar through the lazy path — no eager
            // bulk fetch needed here.
            Task { await vm.expandReplies(for: parentId) }
        } label: {
            HStack(spacing: 0) {
                Text("VIEW \(count) \(count == 1 ? "REPLY" : "REPLIES")")
                    .font(.cucuMono(11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.cucuBurgundy)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.cucuRose))
                    .overlay(Capsule().strokeBorder(Color.cucuRoseStroke, lineWidth: 1))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CucuPressableButtonStyle())
        .padding(.leading, CGFloat(depth) * indentStep + 16)
        .padding(.vertical, 6)
    }

    private func showMoreButton(parentId: String, depth: Int) -> some View {
        Button {
            // Same lazy path as `viewRepliesButton`: paginated
            // siblings will pull their own avatars via
            // `.onAppear` on each row.
            Task { await vm.loadMoreSiblings(under: parentId) }
        } label: {
            HStack(spacing: 0) {
                Text("SHOW MORE REPLIES")
                    .font(.cucuMono(11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.cucuInkSoft)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.cucuCardSoft))
                    .overlay(Capsule().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CucuPressableButtonStyle())
        .padding(.leading, CGFloat(depth) * indentStep + 16)
        .padding(.vertical, 6)
    }

    /// Closing-bracket affordance for an expanded subtree.
    /// Mirrors `showMoreButton`'s muted pill (cucuCardSoft fill,
    /// cucuInkSoft text) since collapsing is bookkeeping, not a
    /// primary call-to-action — a chevron-up glyph distinguishes
    /// it from the pagination affordance. Tap drops the parent
    /// from `expandedIds`; the children flatten back behind a
    /// fresh "View N replies" pill on the next render pass.
    private func hideRepliesButton(parentId: String, depth: Int) -> some View {
        Button {
            CucuHaptics.soft()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                vm.collapse(parentId: parentId)
            }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                    Text("HIDE REPLIES")
                        .font(.cucuMono(11, weight: .semibold))
                        .tracking(1.4)
                }
                .foregroundStyle(Color.cucuInkSoft)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.cucuCardSoft))
                .overlay(Capsule().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CucuPressableButtonStyle())
        .padding(.leading, CGFloat(depth) * indentStep + 16)
        .padding(.vertical, 6)
        .accessibilityLabel("Hide replies")
    }

    private func inlineLoading(depth: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(chrome.theme.inkMuted)
            Text("Loading replies")
                .font(.cucuSans(13, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
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
             .showMoreSiblings(_, let depth),
             .hideReplies(_, let depth):
            return CGFloat(depth) * indentStep + 16
        }
    }

    // MARK: - Bottom bar

    /// Refined "phantom input" bottom bar. Drops the bone-and-moss
    /// editor mimicry in favour of a quiet ink-against-page recess
    /// that matches the Explore search field — same surface family
    /// as every other input on the social chrome. The send glyph
    /// inverts polarity by theme so it stays legible on coal.
    private func replyToThreadBar(root: Post) -> some View {
        Button {
            CucuHaptics.soft()
            replyTarget = root
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(chrome.theme.inkFaded)
                Text("Reply to @\(root.authorUsername)")
                    .font(.cucuSans(15, weight: .regular))
                    .foregroundStyle(chrome.theme.inkFaded)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(chrome.theme.inkPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                Capsule().fill(replyBarFill)
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(
                ZStack(alignment: .top) {
                    chrome.theme.pageColor
                    Rectangle()
                        .fill(chrome.theme.rule)
                        .frame(height: 1)
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to @\(root.authorUsername)")
    }

    /// Subtle ink-against-page recess used by the reply input
    /// pill. Mirrors the search field on Explore so the two
    /// inputs read as the same surface family across surfaces.
    private var replyBarFill: Color {
        chrome.theme.isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }

    // MARK: - Error state

    private var unavailableState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 60)
            Text("Post unavailable")
                .font(.cucuSans(18, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text("This thread is no longer available.")
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Text("Couldn't load this thread")
                .font(.cucuSans(18, weight: .bold))
                .foregroundStyle(chrome.theme.inkPrimary)
            Text(message)
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(chrome.theme.inkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            CucuRefinedPillButton("Try again") {
                Task { await vm.load(rootId: rootId) }
            }
            .padding(.top, 6)
            .padding(.horizontal, 32)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    // MARK: - Skeleton

    /// Loading-state column — borrows the feed's `FeedSkeletonCard`
    /// and steps three of them through the indent ladder so the
    /// shape previews "root + nested replies" before the data
    /// lands. Pulsing opacity (inherited from the card itself)
    /// keeps the energy refined rather than shimmery.
    private var skeletonColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedSkeletonCard()
                .padding(.horizontal, 12)
                .padding(.top, 4)
            FeedSkeletonCard()
                .padding(.leading, indentStep)
                .padding(.horizontal, 12)
            FeedSkeletonCard()
                .padding(.leading, indentStep * 2)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - End-of-thread colophon

    /// Notebook-style end-of-thread sign-off. Single fleuron between
    /// hairline rules and a handwritten note below — same closing
    /// idiom the feed uses, keeping the two surfaces in one voice.
    private var endOfThread: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(chrome.theme.rule)
                    .frame(height: 1)
                Text("❦")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cucuCherry)
                Rectangle()
                    .fill(chrome.theme.rule)
                    .frame(height: 1)
            }
            Text("end of thread — reply to keep it going")
                .font(.custom("Caveat-Regular", size: 18))
                .foregroundStyle(chrome.theme.inkFaded)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
    }

}

// MARK: - Author route

private struct PostThreadLoadKey: Hashable {
    let rootId: String
    let viewerId: String?
}

/// Push target for the "tap a row's profile" intent. Mirrors the
/// type used in `PostFeedView` — kept fileprivate per surface so
/// each navigation stack owns its own destination type instead of
/// sharing a global definition that would invite drift.
private struct AuthorRoute: Identifiable, Hashable {
    let username: String
    var id: String { username }
}
