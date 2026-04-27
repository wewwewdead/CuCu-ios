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
    @State private var state: ViewState = .loading
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
    @State private var loadedPageCount: Int = 1
    @State private var visiblePageIndex: Int = 0

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
        }
        .animation(.easeOut(duration: 0.22), value: lightboxState)
        .animation(.spring(response: 0.46, dampingFraction: 0.78), value: journalContent)
        .animation(.spring(response: 0.46, dampingFraction: 0.78), value: fullGalleryState)
        .navigationTitle("@\(username)")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the nav bar while the lightbox is up so the photo
        // really fills the screen — restored automatically when the
        // overlay dismisses.
        .toolbar(lightboxState == nil ? .visible : .hidden, for: .navigationBar)
        // Status bar follows the same hide/reveal cadence so the
        // lightbox feels like a true fullscreen.
        .statusBarHidden(lightboxState != nil)
        #endif
        .task(id: username) {
            await fetch()
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
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Profile not found")
                .font(.headline)
            Text("@\(username) hasn't published a profile yet, or it's no longer available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
        }
    }

    private func singlePageCanvas(profile: PublishedProfile,
                                  pageIndex: Int,
                                  availableWidth: CGFloat) -> some View {
        let page = profile.document.pages[pageIndex]
        let documentWidth = max(1, CGFloat(profile.document.pageWidth))
        let pageHeight = max(1, CGFloat(page.height))
        let scale = min(1.0, max(1, availableWidth) / documentWidth)
        let scaledWidth = documentWidth * scale
        let scaledHeight = pageHeight * scale

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
            viewerPageIndex: pageIndex
        )
        .frame(width: documentWidth, height: pageHeight)
        .scaleEffect(scale, anchor: .top)
        .frame(width: scaledWidth, height: scaledHeight)
        .frame(maxWidth: .infinity, alignment: .top)
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
            state = .loaded(profile)
        } catch let err as PublishedProfileError {
            switch err {
            case .notFound: state = .notFound
            default: state = .error(err.errorDescription ?? "Something went wrong.")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
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
