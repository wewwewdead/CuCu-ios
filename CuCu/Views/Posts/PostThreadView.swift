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
    /// Author-username → hero-avatar URL map. Filled lazily as
    /// rows scroll into view: each row's `.onAppear` registers
    /// its author's handle through `requestAvatarLazy`, which
    /// debounces into a batched PostgREST lookup. Authors who
    /// haven't published a profile (or published without a hero
    /// avatar) are simply absent from the dictionary; the row
    /// keeps its letter monogram fallback and the puck shows
    /// the rose person glyph. Keyed lowercased to match the SQL
    /// normalization.
    @State private var avatarOverrides: [String: String] = [:]
    /// Usernames that have appeared on screen since the last
    /// debounce tick fired, minus those already cached. Drains
    /// into a single batch fetch; see `requestAvatarLazy`.
    @State private var pendingAvatarUsernames: Set<String> = []
    /// Leading-edge gate so a stream of `.onAppear`s during
    /// scroll only spawns one debounce task at a time. The task
    /// flips this back off after the batch fetch resolves.
    @State private var avatarBatchInFlight: Bool = false

    /// 12pt indent step per visual depth. Both posts and the
    /// affordance buttons run through this so a "View N replies"
    /// row visually nests under its parent post.
    private let indentStep: CGFloat = 12

    var body: some View {
        ZStack {
            Color.cucuPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                content
            }
        }
        .cucuSheetTitle("Thread")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.cucuPaper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
            loadingScrollContent
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

    /// First-load surface — the editorial masthead with placeholder
    /// spec/subtitle copy, the 1pt hairline rule, then a stack of
    /// pulsing skeleton cards in the same indented geometry the
    /// real thread will paint into. Reflows are minimal because
    /// the structure is already rendered when the data lands.
    private var loadingScrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                masthead
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
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
        let items = thread.flattenForRender()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                masthead
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                ForEach(items) { item in
                    renderItem(item, in: thread)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                    if shouldDrawDivider(after: item) {
                        Rectangle()
                            .fill(Color.cucuInkRule)
                            .frame(height: 1)
                            .padding(.leading, dividerLeading(for: item))
                    }
                }
                endOfThread
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: items.map(\.id))
            .padding(.vertical, 4)
            .padding(.bottom, 16)
        }
    }

    /// Skip the row-divider after the root post — the root sits in
    /// a lifted card already, so a flat hairline below it would
    /// double-rule the surface. Every other row keeps the spec's
    /// 1pt ink-rule break.
    private func shouldDrawDivider(after item: PostThread.RenderItem) -> Bool {
        if case .post(let post, _, _) = item, post.id == vm.thread?.root.id {
            return false
        }
        return true
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
            avatarURL: avatarOverrides[post.authorUsername.lowercased()],
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
        .environment(\.cucuPostRowSuppressCard, true)

        return Group {
            if isRoot {
                row
                    .cucuCard(corner: 16, innerRule: true, elevation: .lifted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                row
                    .padding(.leading, CGFloat(depth) * indentStep)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.cucuInkRule)
                            .frame(width: 1)
                            .padding(.leading, CGFloat(depth) * indentStep + 8)
                    }
            }
        }
        .onAppear { requestAvatarLazy(for: post.authorUsername) }
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
                .tint(Color.cucuInkSoft)
            Text("Loading replies…")
                .font(.cucuEditorial(12, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
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

    /// "Phantom input" bottom bar — the tappable area is shaped
    /// and painted exactly like the editor inside the compose
    /// sheet (bone fill, ink stroke, 22pt corner) so the bar
    /// reads as the start of writing rather than a generic CTA.
    /// Italic Fraunces placeholder borrows the editor's voice;
    /// the moss-painted send glyph on the trailing edge marks
    /// the affirmative action without committing to a real
    /// submit button at the page edge.
    private func replyToThreadBar(root: Post) -> some View {
        Button {
            CucuHaptics.soft()
            replyTarget = root
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cucuInkFaded)
                Text("Reply to @\(root.authorUsername)…")
                    .font(.cucuEditorial(15, italic: true))
                    .foregroundStyle(Color.cucuInkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.cucuMoss)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.cucuBone)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.28), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(
                ZStack(alignment: .top) {
                    Color.cucuPaper
                    Rectangle()
                        .fill(Color.cucuInkRule)
                        .frame(height: 1)
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply to @\(root.authorUsername)")
    }

    // MARK: - Error state

    /// Editorial error treatment — matches the feed's fleuron-led
    /// surface (❦ marker, serif headline, italic detail, retry
    /// chip) instead of the SF Symbols warning glyph. Reads as a
    /// printed correction notice rather than a system alert.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            Text("❦")
                .font(.cucuSerif(36, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
            Text("Couldn't load this thread")
                .font(.cucuSerif(22, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(message)
                .font(.cucuEditorial(13, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            CucuChip("Try again", systemImage: "arrow.clockwise") {
                Task { await vm.load(rootId: rootId) }
            }
            .padding(.top, 4)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    // MARK: - Masthead
    //
    // Borrows the feed's title-row idiom: 34pt serif display title
    // on the leading edge, a 38pt avatar puck on the trailing
    // edge that surfaces the thread starter's hero avatar (rather
    // than the viewer's, which is what the feed's puck shows).
    // Underneath, a tracked mono spec line — the root author's
    // handle — and a Fraunces-italic subtitle, closed off with a
    // 1pt ink hairline. The whole block scrolls with the content
    // so it reads as the thread's opening spread.

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            Text(specLine)
                .font(.cucuMono(10, weight: .medium))
                .tracking(2.4)
                .foregroundStyle(Color.cucuInkFaded)
                .padding(.top, 2)
            Text(mastheadSubtitle)
                .font(.cucuEditorial(14, italic: true))
                .foregroundStyle(Color.cucuInkSoft)
                .padding(.bottom, 12)
            Rectangle()
                .fill(Color.cucuInkRule)
                .frame(height: 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Thread")
                .font(.cucuSerif(34, weight: .bold))
                .foregroundStyle(Color.cucuInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            mastheadAvatarPuck
        }
    }

    @ViewBuilder
    private var mastheadAvatarPuck: some View {
        let rootUsername = vm.thread?.root.authorUsername.lowercased() ?? ""
        if !rootUsername.isEmpty,
           let urlString = avatarOverrides[rootUsername],
           !urlString.isEmpty,
           let url = URL(string: urlString) {
            CachedRemoteImage(url: url, contentMode: .fill) {
                avatarPuckFallback
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
            )
        } else {
            avatarPuckFallback
        }
    }

    private var avatarPuckFallback: some View {
        Circle()
            .fill(Color.cucuRose)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.cucuBurgundy)
            )
            .frame(width: 38, height: 38)
            .overlay(
                Circle().strokeBorder(Color.cucuInk.opacity(0.18), lineWidth: 1)
            )
    }

    private var specLine: String {
        if let root = vm.thread?.root {
            return "@\(root.authorUsername)".uppercased()
        }
        return "LOADING THE CONVERSATION"
    }

    private var mastheadSubtitle: String {
        if vm.thread != nil {
            return "A conversation, root to leaves."
        }
        return "Just a moment — fetching replies."
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

    /// Closing flourish at the bottom of every fully-loaded
    /// thread — same fleuron-bracketed marker the feed uses, just
    /// reading "thread" instead of "feed". Reads as a printed
    /// colophon rather than a hard stop.
    private var endOfThread: some View {
        Text("✦  end of the thread  ✦")
            .font(.cucuSerif(12, weight: .regular))
            .foregroundStyle(Color.cucuInkFaded)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    // MARK: - Lazy avatar enrichment

    /// Per-row entry point. Each post row calls this from its
    /// `.onAppear`; we accumulate misses for a 200ms window then
    /// drain the set in a single batched PostgREST call. Cache
    /// hits short-circuit at the top so a row that's been seen
    /// before (or scrolled past and back) costs nothing.
    ///
    /// The leading-edge gate (`avatarBatchInFlight`) ensures a
    /// scroll burst that fires dozens of `.onAppear`s only
    /// spawns one debounce task — every later request just adds
    /// to the pending set. After the fetch resolves, the gate
    /// drops and any *new* requests start a fresh window.
    private func requestAvatarLazy(for username: String) {
        let key = username.lowercased()
        guard !key.isEmpty, avatarOverrides[key] == nil else { return }
        pendingAvatarUsernames.insert(key)
        guard !avatarBatchInFlight else { return }
        avatarBatchInFlight = true
        Task {
            // Debounce window — collect more usernames during
            // this sleep so a momentum scroll batches into one
            // round-trip.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let snapshot = pendingAvatarUsernames.subtracting(Set(avatarOverrides.keys))
            pendingAvatarUsernames.removeAll()
            avatarBatchInFlight = false
            guard !snapshot.isEmpty else { return }
            do {
                let map = try await PublishedProfileService()
                    .fetchAvatars(forUsernames: Array(snapshot))
                avatarOverrides.merge(map) { _, new in new }
            } catch {
                // Silent — letter monogram / rose puck cover it.
            }
        }
    }
}
