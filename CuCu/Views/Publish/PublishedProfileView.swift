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
        adaptiveCanvas(profile: profile)
    }

    /// The published canvas, scaled-to-fit the viewer's screen width.
    ///
    /// Why this matters: the author chose `document.pageWidth` on
    /// their device (e.g. 430pt on a Pro Max). Without scaling, a
    /// viewer on a smaller phone (e.g. 374pt iPhone 15 plain) sees
    /// the page horizontally clipped or scrollable. We want the
    /// whole page to fit edge-to-edge regardless of which device is
    /// viewing it.
    ///
    /// Implementation — three nested frames:
    ///   1. **Inner frame** (`documentWidth × availableHeight/scale`)
    ///      gives the canvas its full authored width internally so
    ///      every node frame, gesture coord, and child layout
    ///      computation runs at the exact pixel grid the author
    ///      saw. The height is divided by `scale` so the visual
    ///      result fills the available vertical space after scaling.
    ///   2. **`.scaleEffect`** with `.top` anchor renders that
    ///      full-size canvas at `scale`, visually shrinking it to
    ///      `availableWidth × availableHeight`.
    ///   3. **Outer frame** (`scaledWidth × availableHeight`) claims
    ///      the post-scale bounding box in the parent layout so
    ///      Auto Layout / VStack spacing works correctly.
    ///
    /// The cap at `1.0` means we **shrink to fit but never enlarge**
    /// — viewing a 390pt-wide page on an iPad just centers it at
    /// authored size rather than upscaling (which would soften
    /// images and look pixelated).
    @ViewBuilder
    private func adaptiveCanvas(profile: PublishedProfile) -> some View {
        GeometryReader { geo in
            let documentWidth = max(1, CGFloat(profile.document.pageWidth))
            let availableWidth = max(1, geo.size.width)
            let scale = min(1.0, availableWidth / documentWidth)
            let scaledWidth = documentWidth * scale
            let scaledHeight = geo.size.height

            CanvasEditorContainer(
                document: documentBinding(for: profile),
                selectedID: $sinkSelectedID,
                onCommit: { _ in
                    // View-only: ignore commits. The viewer never
                    // attaches editing gestures, so this is belt-and-
                    // braces — nothing should ever fire.
                },
                isInteractive: false,
                onOpenURL: { url in
                    // Route the URL through SwiftUI's `openURL` so the
                    // user's default browser / URL handler picks it up.
                    openURL(url)
                },
                onOpenImage: { urls, index in
                    // Tap-on-tile from a gallery in viewer mode →
                    // present the paginated fullscreen lightbox.
                    withAnimation(.easeOut(duration: 0.22)) {
                        lightboxState = LightboxState(
                            id: UUID(),
                            urls: urls,
                            initialIndex: index
                        )
                    }
                },
                onOpenJournal: { nodeID in
                    // Tap-on-Journal-Card → extract title/body from
                    // the container's text descendants and present
                    // the journal modal. The spring on the wrapping
                    // ZStack drives the entry animation.
                    guard let extracted = profile.document.journalContent(for: nodeID) else { return }
                    journalContent = extracted
                },
                onOpenFullGallery: { urls in
                    // Tap on the gallery's "View Gallery" chip →
                    // present the lazy-grid full gallery. New
                    // identifier on every open so SwiftUI
                    // re-presents cleanly if the user taps a
                    // different gallery while the modal is up.
                    fullGalleryState = FullGalleryState(id: UUID(), urls: urls)
                }
            )
            .frame(width: documentWidth, height: scaledHeight / max(scale, 0.001))
            .scaleEffect(scale, anchor: .top)
            .frame(width: scaledWidth, height: scaledHeight)
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
