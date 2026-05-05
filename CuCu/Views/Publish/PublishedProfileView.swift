import SwiftUI

/// Public, read-only viewer for a published CuCu profile. Fetches the
/// `profiles` row by username, decodes its `design_json` into a
/// `ProfileDocument`, and hands the document to the v2 canvas in a
/// view-only mode.
///
/// Three states drive the screen:
///   - **loading**   — initial fetch in flight; show a centered spinner
///   - **notFound**  — server returned 0 rows (or RLS hid an unpublished
///                     profile); show a friendly empty state
///   - **error**     — anything else (network, decode, config); show
///                     the error text + Retry
///   - **loaded**    — the document renders inside `CanvasEditorContainer`
///                     with a non-binding selectedID and a no-op commit
///                     (the viewer has no editor)
///
/// Image paths inside the loaded document are remote URLs (rewritten by
/// `PublishedDocumentTransformer` at publish time). The four canvas
/// renderers branch on `CanvasImageLoader.isRemote(...)` and route those
/// to `RemoteImageCache`, so the viewer needs no special-casing — it
/// just hands the document to the canvas.
struct PublishedProfileView: View {
    let username: String

    @Environment(\.openURL) private var openURL
    @Environment(\.cucuWidthClass) private var widthClass
    @Environment(AuthViewModel.self) private var auth
    /// Bound to the same `cucu.selected_tab` key `RootView` writes to,
    /// so the "Switch to Build" CTA on the self-not-found state can
    /// flip the user back to the editor without us plumbing a
    /// closure all the way down. SwiftUI keeps the two `@AppStorage`
    /// reads in lock-step.
    @AppStorage("cucu.selected_tab") private var selectedTabRaw: String = "build"
    @State private var state: ViewState = .loading
    /// Process-wide chrome theme. Drives the toolbar colour and the
    /// Posts-section surface so the visitor's room flows through the
    /// page chrome — the user's *canvas* stays as their published
    /// design (the visitor came to see that, untouched).
    @State private var chrome = AppChromeStore.shared
    /// A binding sink the canvas container needs but the viewer doesn't
    /// use — selection has no meaning in view-only mode.
    @State private var sinkSelectedID: UUID? = nil
    /// When non-nil, the fullscreen image lightbox is presented with
    /// the gallery's URL list + the index of the tapped image. Driven
    /// by gallery-tile taps coming back from the canvas via
    /// `onOpenImage`.
    @State private var lightboxState: LightboxState?
    /// When non-nil, the journal modal is presented with the
    /// extracted title + body of the tapped Journal Card.
    @State private var journalContent: JournalContent?
    /// When non-nil, the full-gallery grid is presented with the
    /// gallery's URL list. Stacks underneath `lightboxState` so a
    /// tap on a tile inside the grid opens the lightbox without
    /// dismissing the grid first.
    @State private var fullGalleryState: FullGalleryState?
    /// When non-nil, the note expand modal is presented with the
    /// extracted title / timestamp / body of the tapped note. Mirrors
    /// `journalContent` for journal cards.
    @State private var noteContent: NoteContent?
    @State private var loadedPageCount: Int = 1
    @State private var visiblePageIndex: Int = 0
    @State private var voteState: ProfileVoteState?
    @State private var isVoting = false
    @State private var voteMessage: String?
    @State private var showShareSheet = false
    /// Last 10 top-level posts authored by the profile owner. Hydrated
    /// by `loadUserPostsIfNeeded` once the visitor scrolls past the
    /// last canvas page; an empty array (the default) hides the
    /// section so a user with nothing posted yet doesn't see an
    /// empty stub under their canvas.
    @State private var userPosts: [Post] = []
    /// Set of `Post.id` that the current viewer has liked. Best-effort
    /// — failures fall back to "not liked" rather than blocking the
    /// section from rendering.
    @State private var viewerLikedPostIds: Set<String> = []
    /// Lazy-load gate for the Posts section. Set the first time the
    /// canvas finishes paginating so the 10-row fetch only fires for
    /// visitors who actually scrolled past the canvas. Reset on each
    /// `.task(id: username)` so a fresh profile open starts cold.
    @State private var userPostsRequested: Bool = false
    /// Drives the navigation push into a thread when the visitor taps
    /// a row in the Posts section.
    @State private var threadDestination: Post?
    /// Drives the "View all" push. The ID + username of the owner are
    /// captured at push-time so the destination view doesn't depend on
    /// the in-flight fetch state.
    @State private var allPostsDestination: AllPostsDestination?

    private struct AllPostsDestination: Hashable, Identifiable {
        let authorId: String
        let username: String
        var id: String { authorId }
    }

    /// Phase 7 — report sheet target for a row in the Posts
    /// section. Held alongside the canvas state so dismissal
    /// doesn't fight with the lightbox / journal modals.
    @State private var postReportTarget: Post? = nil
    @State private var postBlockTarget: Post? = nil
    @State private var moderationToast: String? = nil

    private let nextPageLoadThreshold: CGFloat = 520

    /// Identifiable wrapper so SwiftUI animates re-presentations
    /// cleanly when a viewer taps "View Gallery" on a different
    /// gallery node mid-session.
    private struct FullGalleryState: Equatable, Identifiable {
        let id: UUID
        let urls: [URL]
    }

    /// Hashable so SwiftUI's `.animation(_:value:)` can diff transitions
    /// across re-renders when the user opens / paginates / closes the
    /// lightbox without flickering.
    private struct LightboxState: Equatable {
        let id: UUID
        let urls: [URL]
        let initialIndex: Int
    }

    private enum ViewState {
        case loading
        case loaded(PublishedProfile)
        case notFound
        case error(String)
    }

    var body: some View {
        ZStack {
            Group {
                switch state {
                case .loading:
                    loadingState
                case .loaded(let profile):
                    loadedContent(profile: profile)
                case .notFound:
                    notFoundState
                case .error(let message):
                    errorState(message)
                }
            }

            // Fullscreen image lightbox. The conditional + transition
            // pair gives us a smooth fade + slight scale on enter/exit
            // without dragging in `.fullScreenCover` (which insists on
            // its own slide animation).
            //
            // **`zIndex(2)`** specifically: the lightbox can be opened
            // *from inside* the full-gallery grid (which sits at
            // `zIndex(1)`), so it must paint above the grid. Earlier
            // both modals shared `zIndex(1)` and SwiftUI broke the
            // tie by declaration order, hiding the lightbox behind
            // the grid — that was the visible bug.
            if let state = lightboxState {
                ImageLightboxView(
                    urls: state.urls,
                    initialIndex: state.initialIndex,
                    onClose: { closeLightbox() }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity.combined(with: .scale(scale: 1.04))
                ))
                .zIndex(2)
            }

            // Full-gallery grid. Sits **below** the lightbox so a
            // tap on a tile inside the grid pushes the lightbox on
            // top — closing the lightbox returns the user to the
            // grid, which is the right mental model for "browsing
            // photos". Same fluid spring transition as the journal
            // modal for a unified delight feel.
            if let state = fullGalleryState {
                FullGalleryView(
                    urls: state.urls,
                    onSelectTile: { index in
                        // Open the existing lightbox over the grid.
                        // Animation chains naturally because both
                        // overlays are SwiftUI children of the same
                        // ZStack with their own transitions.
                        withAnimation(.easeOut(duration: 0.22)) {
                            lightboxState = LightboxState(
                                id: UUID(),
                                urls: state.urls,
                                initialIndex: index
                            )
                        }
                    },
                    onClose: { closeFullGallery() }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92)),
                    removal: .opacity.combined(with: .scale(scale: 0.94))
                ))
                .zIndex(1)
            }

            // Journal modal. Spring-driven scale-up entry with a
            // mild overshoot so it lands with character; ease-out
            // shrink + fade on exit. The drag-to-dismiss gesture
            // inside the modal pairs with the same animation curve
            // so the user can flick it away and have it feel
            // continuous.
            //
            // `zIndex(3)` so it sits above every other overlay if
            // the user somehow opens it while a gallery / lightbox
            // is already up (they're mutually-exclusive in current
            // UX, but explicit ordering is cheap insurance).
            if let journal = journalContent {
                JournalModalView(
                    content: journal,
                    onClose: { closeJournal() }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.88)),
                    removal: .opacity.combined(with: .scale(scale: 0.94))
                ))
                .zIndex(3)
            }

            if let note = noteContent {
                NoteModalView(
                    content: note,
                    onClose: { closeNote() }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.88)),
                    removal: .opacity.combined(with: .scale(scale: 0.94))
                ))
                .zIndex(3)
            }
        }
        .animation(.easeOut(duration: 0.22), value: lightboxState)
        .animation(.spring(response: 0.46, dampingFraction: 0.78), value: journalContent)
        .animation(.spring(response: 0.46, dampingFraction: 0.78), value: fullGalleryState)
        .animation(.spring(response: 0.46, dampingFraction: 0.78), value: noteContent)
        .navigationTitle("@\(username)")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                shareToolbarButton
                voteToolbarButton
            }
        }
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the nav bar while the lightbox is up so the photo
        // really fills the screen — restored automatically when the
        // overlay dismisses.
        .toolbar(lightboxState == nil ? .visible : .hidden, for: .navigationBar)
        // Toolbar follows the visitor's chrome theme rather than the
        // owner's canvas: the canvas is what the visitor came to
        // see (we don't repaint it), but the toolbar above it is
        // the visitor's app chrome and should match Feed/Explore.
        .toolbarBackground(chrome.theme.pageColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(chrome.theme.preferredColorScheme, for: .navigationBar)
        .tint(chrome.theme.inkPrimary)
        // Status bar follows the same hide/reveal cadence so the
        // lightbox feels like a true fullscreen.
        .statusBarHidden(lightboxState != nil)
        #endif
        .task(id: username) {
            await fetch()
        }
        .onChange(of: auth.currentUser?.id) { _, _ in
            if case .loaded(let profile) = state {
                Task { await loadVoteState(profileId: profile.id) }
            }
        }
        .navigationDestination(item: $threadDestination) { post in
            PostThreadView(rootId: post.rootId ?? post.id)
        }
        .navigationDestination(item: $allPostsDestination) { destination in
            UserPostsListView(
                authorId: destination.authorId,
                displayUsername: destination.username
            )
        }
        .sheet(item: $postReportTarget) { post in
            ReportPostSheet(post: post) { outcome in
                switch outcome {
                case .submitted:
                    moderationToast = "Reported. Thanks — we review every report."
                case .alreadyReported:
                    moderationToast = "Already reported. We'll review it soon."
                case .cancelled:
                    break
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            postBlockTarget.map { "Block @\($0.authorUsername)?" } ?? "Block user?",
            isPresented: Binding(
                get: { postBlockTarget != nil },
                set: { if !$0 { postBlockTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: postBlockTarget
        ) { post in
            Button("Block", role: .destructive) {
                Task { await blockAuthorOfPost(post) }
            }
            Button("Cancel", role: .cancel) { postBlockTarget = nil }
        } message: { post in
            Text("You won't see @\(post.authorUsername)'s posts or replies.")
        }
        .cucuToast(message: $moderationToast)
        .alert(
            "Voting",
            isPresented: Binding(
                get: { voteMessage != nil },
                set: { if !$0 { voteMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { voteMessage = nil }
        } message: {
            Text(voteMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if case .loaded(let profile) = state {
                ProfileShareSheet(username: profile.username, document: profile.document)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func closeLightbox() {
        // Drive the dismissal through the same `withAnimation` the
        // appearance used so the transition is symmetric.
        withAnimation(.easeOut(duration: 0.22)) {
            lightboxState = nil
        }
    }

    private func closeJournal() {
        withAnimation(.easeOut(duration: 0.26)) {
            journalContent = nil
        }
    }

    private func closeFullGallery() {
        withAnimation(.easeOut(duration: 0.26)) {
            fullGalleryState = nil
        }
    }

    private func closeNote() {
        withAnimation(.easeOut(duration: 0.26)) {
            noteContent = nil
        }
    }

    // MARK: - State views

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notFoundState: some View {
        // Diverge the copy when the username being looked up belongs
        // to the signed-in viewer themselves. The generic "Profile
        // not found" message reads like the navigation broke; the
        // self-targeted message tells them what to do next (go to
        // Build → Publish) so the puck-tap-before-publish path
        // doesn't end at a confusing dead end.
        let isSelf: Bool = {
            let me = auth.currentUser?.username?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return !me.isEmpty && username.lowercased() == me
        }()
        return VStack(spacing: 10) {
            Text(isSelf ? "You haven't published yet" : "Profile not found")
                .font(.cucuSans(18, weight: .bold))
                .foregroundStyle(Color.cucuInk)
            Text(isSelf
                 ? "Switch to the Build tab and tap Publish to claim your card on Explore."
                 : "@\(username) hasn't published a profile yet, or it's no longer available.")
                .font(.cucuSans(14, weight: .regular))
                .foregroundStyle(Color.cucuInkFaded)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if isSelf {
                CucuRefinedPillButton("Switch to Build") {
                    selectedTabRaw = "build"
                }
                .padding(.top, 12)
                .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load this profile")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                state = .loading
                Task { await fetch() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func loadedContent(profile: PublishedProfile) -> some View {
        // No header — display name + bio columns were removed from
        // the publish flow. Identity is whatever the author drew on
        // the canvas itself, so it gets the full screen.
        incrementalScrollCanvas(profile: profile)
    }

    @ViewBuilder
    private var shareToolbarButton: some View {
        if case .loaded = state {
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share profile")
        }
    }

    @ViewBuilder
    private var voteToolbarButton: some View {
        if case .loaded(let profile) = state {
            Button {
                Task { await toggleVote(for: profile) }
            } label: {
                Label(voteCountLabel, systemImage: voteState?.hasVoted == true ? "heart.fill" : "heart")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(isVoting)
            .accessibilityLabel(voteState?.hasVoted == true ? "Remove vote" : "Vote for profile")
        }
    }

    /// The published canvas, rendered as threshold-loaded infinite scroll.
    /// We mount page 1 immediately, then mount each next page only when the
    /// sentinel below the loaded content nears the viewport. That keeps remote
    /// image requests delayed until a visitor actually scrolls toward a page.
    @ViewBuilder
    private func incrementalScrollCanvas(profile: PublishedProfile) -> some View {
        GeometryReader { geo in
            let pageCount = profile.document.pages.count
            let renderedCount = min(max(1, loadedPageCount), pageCount)
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(0..<renderedCount, id: \.self) { pageIndex in
                        VStack(spacing: 8) {
                            if pageCount > 1 {
                                Text("Page \(pageIndex + 1) of \(pageCount)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            singlePageCanvas(
                                profile: profile,
                                pageIndex: pageIndex,
                                availableWidth: geo.size.width
                            )
                            .background(pageVisibilityProbe(pageIndex: pageIndex))
                        }
                    }

                    if renderedCount < pageCount {
                        loadingNextPageSentinel
                    }

                    // Posts section under the last loaded page. Held
                    // off until every page is mounted so it doesn't
                    // jump around mid-pagination — the canvas is the
                    // headline; posts are the footer.
                    if renderedCount >= pageCount, !userPosts.isEmpty {
                        postsSection(profile: profile)
                    }
                }
                .padding(.vertical, 16)
            }
            .coordinateSpace(name: "publishedProfileScroll")
            .overlay(alignment: .bottom) {
                if pageCount > 1 {
                    pageCountOverlay(current: visiblePageIndex, total: pageCount)
                }
            }
            .onPreferenceChange(NextPublishedPageSentinelPreferenceKey.self) { sentinelMinY in
                guard renderedCount < pageCount else { return }
                if sentinelMinY < geo.size.height + nextPageLoadThreshold {
                    loadedPageCount = min(pageCount, renderedCount + 1)
                }
            }
            .onPreferenceChange(PublishedPageTopPreferenceKey.self) { positions in
                guard let nearest = positions.min(by: { abs($0.value) < abs($1.value) }) else { return }
                visiblePageIndex = nearest.key
            }
            // Lazy posts-section trigger. Fires the first time the
            // visitor has scrolled past the last canvas page — visitors
            // who bounce earlier never pay the 10-row + like-state cost.
            .onChange(of: renderedCount) { _, newValue in
                if newValue >= pageCount, case .loaded(let profile) = state {
                    Task { await loadUserPostsIfNeeded(authorId: profile.userId) }
                }
            }
        }
    }

    private func singlePageCanvas(profile: PublishedProfile,
                                  pageIndex: Int,
                                  availableWidth: CGFloat) -> some View {
        let page = profile.document.pages[pageIndex]
        let pageHeight = max(1, CGFloat(page.height))
        // Responsive scale-to-fit, edge-to-edge. The published page
        // was authored at a fixed `pageWidth` (390pt by default, or
        // the actual content extent if the author placed nodes past
        // that). When a viewer opens the profile on a different-
        // sized phone, we don't want the content to look small with
        // empty margins (Pro Max viewing an SE author) or to overflow
        // off-screen (SE viewing a Pro Max author). Computing
        // `availableWidth / designWidth` and applying a uniform
        // `.scaleEffect` makes elements grow or shrink proportionally
        // so the published profile fills the viewer's full width.
        //
        // No paper-color outer margin: the editor canvas itself runs
        // edge-to-edge in the builder, and the seven default
        // templates already bake a ~15pt content inset into their
        // authored coordinates so individual nodes sit comfortably
        // inside the canvas without needing the viewer to add an
        // extra gutter on top. Adding one here too would compound
        // into a strip of whitespace the user has explicitly told
        // us not to show.
        //
        // `contentDesignWidth(forPageAt:)` is the design unit: the
        // larger of the canonical `pageWidth` and any node's right
        // edge (so authors who placed children past 390pt on a Pro
        // Max stay visible on narrower viewers).
        let designWidth = max(1, CGFloat(profile.document.contentDesignWidth(forPageAt: pageIndex)))
        let usableWidth = max(1, availableWidth)
        let scale = usableWidth / designWidth
        let renderedHeight = pageHeight * scale

        return CanvasEditorContainer(
            document: documentBinding(for: profile),
            selectedID: $sinkSelectedID,
            onCommit: { _ in
                // View-only: ignore commits. The viewer never attaches editing
                // gestures, so nothing should ever fire.
            },
            isInteractive: false,
            onOpenURL: { url in
                openURL(url)
            },
            onOpenImage: { urls, index in
                withAnimation(.easeOut(duration: 0.22)) {
                    lightboxState = LightboxState(
                        id: UUID(),
                        urls: urls,
                        initialIndex: index
                    )
                }
            },
            onOpenJournal: { nodeID in
                guard let extracted = profile.document.journalContent(for: nodeID) else { return }
                journalContent = extracted
            },
            onOpenFullGallery: { urls in
                fullGalleryState = FullGalleryState(id: UUID(), urls: urls)
            },
            onOpenNote: { nodeID in
                guard let extracted = profile.document.noteContent(for: nodeID) else { return }
                noteContent = extracted
            },
            viewerPageIndex: pageIndex
        )
        // Render the canvas at the author's authored design width so the
        // inner `max(viewportWidth, pageWidth)` rule resolves cleanly
        // (viewport == pageWidth → no double-stretch). The scale is
        // applied as a visual transform around the topLeading anchor;
        // the matching outer frame alignment keeps the scaled origin
        // pinned to the topLeading of the full viewport so content
        // fills from the leading edge without offset drift.
        .frame(width: designWidth, height: pageHeight)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: usableWidth, height: renderedHeight, alignment: .topLeading)
    }

    private var loadingNextPageSentinel: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NextPublishedPageSentinelPreferenceKey.self,
                        value: proxy.frame(in: .named("publishedProfileScroll")).minY
                    )
                }
            )
    }

    private func pageVisibilityProbe(pageIndex: Int) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PublishedPageTopPreferenceKey.self,
                value: [pageIndex: proxy.frame(in: .named("publishedProfileScroll")).minY]
            )
        }
    }

    /// Vertical stack of compact post rows under the canvas — the
    /// owner's last 10 top-level posts plus a "View all" link.
    /// Keys off `Color.cucuInk` / `Color.cucuPaper` so the section
    /// reads as part of the same paper-and-ink chrome the rest of
    /// the public viewer uses.
    @ViewBuilder
    private func postsSection(profile: PublishedProfile) -> some View {
        let viewerId = auth.currentUser?.id.lowercased()

        VStack(alignment: .leading, spacing: 0) {
            Text("Posts")
                .font(.title3.weight(.semibold))
                .foregroundStyle(chrome.theme.inkPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)

            Divider()
                .background(chrome.theme.rule)

            ForEach(userPosts) { post in
                PostRowView(
                    post: post,
                    style: .compact,
                    viewerHasLiked: viewerLikedPostIds.contains(post.id),
                    isOwnPost: post.authorId == viewerId,
                    onTap: { threadDestination = post },
                    onLike: {},
                    onReply: {},
                    onDelete: {},
                    onReport: { postReportTarget = post },
                    onBlock: { postBlockTarget = post }
                )
                Divider()
                    .padding(.leading, 16)
                    .background(chrome.theme.rule)
            }

            Button {
                allPostsDestination = AllPostsDestination(
                    authorId: profile.userId,
                    username: profile.username
                )
            } label: {
                HStack {
                    Text("View all")
                        .font(.callout.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(chrome.theme.inkPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(chrome.theme.pageColor)
    }

    private func pageCountOverlay(current: Int, total: Int) -> some View {
        Text("Page \(min(current + 1, total)) of \(total)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
    }

    // `profileHeader` was removed alongside the `display_name` / `bio`
    // columns — the canvas itself owns identity now.

    // MARK: - Document binding
    //
    // `CanvasEditorContainer` requires a `Binding<ProfileDocument>`. The
    // viewer is read-only, so the setter is a no-op — but SwiftUI still
    // needs the binding to render. Using a constant computed property
    // lets us mint the binding without any private @State for the
    // document itself.

    private func documentBinding(for profile: PublishedProfile) -> Binding<ProfileDocument> {
        Binding(
            get: { profile.document },
            set: { _ in /* read-only viewer */ }
        )
    }

    // MARK: - Fetch

    private func fetch() async {
        do {
            let profile = try await PublishedProfileService().fetch(username: username)
            loadedPageCount = 1
            visiblePageIndex = 0
            // Reset the posts section so re-fetching for a different
            // username doesn't briefly show the previous owner's posts
            // under the new canvas.
            userPosts = []
            viewerLikedPostIds = []
            userPostsRequested = false
            state = .loaded(profile)
            await loadVoteState(profileId: profile.id)
            // Posts section deliberately *not* loaded here — see
            // `loadUserPostsIfNeeded`. The 10-row + like-state pair
            // costs ~2.5KB per profile open, and the section only
            // appears once the visitor has scrolled past every
            // canvas page. Visitors who bounce after the first
            // page never trigger the load.
        } catch let err as PublishedProfileError {
            switch err {
            case .notFound: state = .notFound
            default: state = .error(err.errorDescription ?? "Something went wrong.")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private var voteCountLabel: String {
        let count = voteState?.voteCount ?? 0
        if count >= 1_000 {
            return "\(count / 1_000)k"
        }
        return "\(count)"
    }

    /// Block + scrub the loaded Posts section in place. The
    /// owner's canvas stays untouched (the visitor came here to
    /// see *that*) — only the per-author posts list is filtered.
    /// Service failure surfaces as a toast; the section
    /// otherwise stays as-is.
    private func blockAuthorOfPost(_ post: Post) async {
        postBlockTarget = nil
        do {
            try await UserBlockService().block(userId: post.authorId)
            let canonical = post.authorId.lowercased()
            userPosts.removeAll { $0.authorId.lowercased() == canonical }
            moderationToast = "Blocked @\(post.authorUsername)"
        } catch let err as UserBlockError {
            moderationToast = err.errorDescription ?? "Couldn't block right now."
        } catch {
            moderationToast = error.localizedDescription
        }
    }

    /// Best-effort fetch of the profile owner's last 10 top-level
    /// posts. Idempotent: the `userPostsRequested` gate prevents a
    /// re-fire on subsequent canvas-pagination ticks. Failures
    /// silently leave `userPosts` empty so the section stays hidden
    /// — the visitor came to see the canvas, and a network error
    /// banner under it would just be noise.
    private func loadUserPostsIfNeeded(authorId: String) async {
        guard !userPostsRequested else { return }
        userPostsRequested = true
        do {
            let posts = try await PostService().fetchUserPosts(
                authorId: authorId,
                before: nil,
                limit: 10
            )
            userPosts = posts
            // Hydrate like state for the visible posts. Tolerates
            // signed-out viewers (returns an empty set), which is
            // fine because the compact row doesn't render the heart
            // anyway.
            viewerLikedPostIds = await PostLikeService().fetchLikeState(
                postIds: posts.map(\.id)
            )
        } catch {
            userPosts = []
            viewerLikedPostIds = []
        }
    }

    private func loadVoteState(profileId: String) async {
        do {
            voteState = try await ProfileVoteService().fetchVoteState(
                profileId: profileId,
                user: auth.currentUser
            )
        } catch {
            // Keep the viewer usable even if voting stats are temporarily
            // unavailable. Tapping the button will surface a concrete error.
            voteState = ProfileVoteState(profileId: profileId, voteCount: 0, hasVoted: false)
        }
    }

    private func toggleVote(for profile: PublishedProfile) async {
        guard let user = auth.currentUser else {
            voteMessage = "Sign in from the Publish sheet to vote on profiles."
            return
        }

        let previous = voteState ?? ProfileVoteState(
            profileId: profile.id,
            voteCount: 0,
            hasVoted: false
        )
        let next = ProfileVoteState(
            profileId: profile.id,
            voteCount: max(0, previous.voteCount + (previous.hasVoted ? -1 : 1)),
            hasVoted: !previous.hasVoted
        )

        isVoting = true
        voteState = next
        do {
            if previous.hasVoted {
                try await ProfileVoteService().unvote(profileId: profile.id, user: user)
            } else {
                try await ProfileVoteService().vote(profileId: profile.id, user: user)
            }
            voteState = try await ProfileVoteService().fetchVoteState(
                profileId: profile.id,
                user: user
            )
        } catch let err as ProfileVoteError {
            voteState = previous
            voteMessage = err.errorDescription ?? "Couldn't update your vote."
        } catch {
            voteState = previous
            voteMessage = error.localizedDescription
        }
        isVoting = false
    }
}

private struct NextPublishedPageSentinelPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct PublishedPageTopPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Lightweight launcher screen — paste a username, jump to the viewer.
/// Surfaced from the v2 builder's overflow menu so QA / users can open
/// any published profile by username without needing a deep link.
struct OpenPublishedProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var typed: String = ""
    @State private var showViewer = false
    @State private var trimmedUsername: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 4) {
                        Text("@")
                            .foregroundStyle(.secondary)
                            .font(.body.monospaced())
                        TextField("yourname", text: $typed)
                            .font(.body.monospaced())
                            #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Username")
                } footer: {
                    Text("Opens any published profile in the native viewer.")
                }

                Section {
                    Button {
                        let normalized = typed
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        guard !normalized.isEmpty else { return }
                        trimmedUsername = normalized
                        showViewer = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Open").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Open Profile")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showViewer) {
                PublishedProfileView(username: trimmedUsername)
            }
        }
    }
}
