import UIKit

/// Cheap value-type fingerprint used to decide whether to re-call
/// `NodeRenderView.apply(node:)`. Captures only the fields that affect
/// what `apply(node:)` reads — frame, style, content, opacity, and
/// the user-supplied name — plus the on-disk modification dates of
/// any images referenced by the node so a file-replace forces a redraw.
///
/// Drops `childrenIDs`, `id`, `type`, and `zIndex` from the previous
/// "store the whole CanvasNode" form:
/// - `childrenIDs` does not affect this view's render — z-order is
///   reapplied separately via `applyZOrder`, and child subviews are
///   managed by the `applyNode` recursion.
/// - `id` and `type` are immutable for a live node (a type change
///   triggers a fresh `NodeRenderView` via `expectedType(for:)` and
///   sidesteps the signature comparison entirely).
/// - `zIndex` is not consumed by `apply(node:)`.
///
/// Removing those fields drops `Hashable`/`Equatable` cost on a hot
/// path that runs once per node per `applyDocumentToCanvas`.
private struct NodeRenderSignature: Equatable {
    var frame: NodeFrame
    var style: NodeStyle
    var content: NodeContent
    var name: String?
    /// Included so an opacity change repaints — `apply(node:)` writes
    /// `alpha = CGFloat(node.opacity)`, which would otherwise stick
    /// at the previous value when nothing else in the node changed.
    var opacity: Double
    var localImageModificationDate: Date?
    var backgroundImageModificationDate: Date?
    var galleryImageModificationDates: [Date?]
}

#if DEBUG
/// Debug counter incremented every time `NodeRenderView.apply(node:)`
/// fires from the canvas editor's render path. Used to verify that
/// idle `applyDocumentToCanvas` passes (no model change) produce zero
/// hits — see the "cheaper signature" perf step.
enum CanvasEditorRenderStats {
    nonisolated(unsafe) static var applyCount: Int = 0
    static func resetApplyCount() { applyCount = 0 }
}
#endif

/// Three-entry LRU for original (pre-filter) background bitmaps,
/// keyed by `(path, mtime)`. The most-recently-touched entry sits at
/// index 0; lookup moves a hit to the front, insert prepends and
/// trims to capacity. Inserting a new entry for an existing `path`
/// (any mtime) evicts the older same-path entry — preserves the
/// "replace busts the cache" semantics the previous single-entry
/// tuple relied on.
private struct BackgroundImageLRUCache {
    private struct Entry {
        let path: String
        let mtime: Date?
        let image: UIImage
    }
    private var entries: [Entry] = []
    private let capacity = 3

    mutating func image(for path: String, mtime: Date?) -> UIImage? {
        guard let idx = entries.firstIndex(where: { $0.path == path && $0.mtime == mtime }) else {
            return nil
        }
        if idx > 0 {
            let entry = entries.remove(at: idx)
            entries.insert(entry, at: 0)
        }
        return entries[0].image
    }

    mutating func insert(path: String, mtime: Date?, image: UIImage) {
        // Evict any prior entry for the same path (regardless of
        // mtime). That keeps "replace at the same path" from leaving
        // a stale-bytes shadow in the cache.
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, mtime: mtime, image: image), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

/// The UIKit canvas. Owns:
///   - a flat `[UUID: NodeRenderView]` cache keyed by node ID
///   - the page-background view (the canvas root's background fill)
///   - one `SelectionOverlayView` always last in the subview stack
///   - per-node pan recognizers for moving nodes within their parent
///   - a single tap recognizer for select / deselect
///
/// Hit-testing is custom (not via `UIView.hitTest`) so we can implement the
/// "tap on container's empty area selects the container" rule correctly:
/// depth-first traversal, reverse `childrenIDs` order so the highest-z
/// sibling wins.
///
/// **Coordinate-space invariants** (Phase 1, no canvas zoom/pan/rotation):
/// - Each node's `frame` is in its parent's coordinate space.
/// - The container view *is* the parent in the UIView hierarchy, so UIKit's
///   own frame system matches the model.
/// - Pan translation vectors are the same in canvas-root coords and any
///   descendant's coord system because there is no scale/rotation in
///   ancestors. The selection overlay therefore reports translation in
///   canvas-root coords and we apply it directly to the selected node's
///   parent-space frame. If we ever add zoom, replace direct addition with
///   `convert(_:to:)` of the translation vector.
final class CanvasEditorView: UIView {

    // MARK: - State

    /// Source-of-truth document. Mutations during a gesture happen here in
    /// memory; persistence is reported on gesture end.
    private(set) var document: ProfileDocument = .blank
    private(set) var selectedID: UUID?

    /// ID of the text node currently in editing mode (keyboard up).
    /// Tracked so we can dismiss the keyboard cleanly when the
    /// selection moves elsewhere via path chip / canvas tap / drag.
    private var editingTextNodeID: UUID?

    private var renderViews: [UUID: NodeRenderView] = [:]
    private var appliedNodeSignatures: [UUID: NodeRenderSignature] = [:]
    private var nodePanGestures: [UUID: UIPanGestureRecognizer] = [:]
    /// Per-node long-press recognizer paired with the pan above. Long
    /// press is the "open the inspector" shortcut: hold ~0.4s without
    /// moving the finger and the recognizer fires once. Held in a
    /// dictionary keyed by node ID so the prune step in `apply(...)`
    /// can drop the recognizer for a deleted node alongside its
    /// render view.
    private var nodeLongPressGestures: [UUID: UILongPressGestureRecognizer] = [:]
    /// Single-shot haptic generator. Re-prepared on every recognized
    /// long press so the impact stays crisp; the OS otherwise lets
    /// haptic engines wind down between uses.
    private let editHapticGenerator = UIImpactFeedbackGenerator(style: .medium)

    private let overlay = SelectionOverlayView()

    /// Vertical scrolling host. Pinned to the canvas root's bounds and
    /// kept transparent so the page background image (which sits
    /// behind it on `self`) stays visible. Page content (node render
    /// views + selection overlay) lives inside `contentView` below.
    /// Scrolling activates only when the bottommost root child
    /// exceeds the viewport height.
    private let scrollView: UIScrollView = {
        let s = UIScrollView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.backgroundColor = .clear
        s.showsVerticalScrollIndicator = true
        s.showsHorizontalScrollIndicator = false
        s.alwaysBounceVertical = false
        s.alwaysBounceHorizontal = false
        s.contentInsetAdjustmentBehavior = .never
        return s
    }()

    /// Holds the centered page surface plus the selection overlay. Its size
    /// is driven by mutable constraints so the scroll view can be wider/taller
    /// than the viewport when the page dimensions require it.
    private let contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()

    /// Shadow/border wrapper for the actual profile page. Root canvas nodes
    /// live inside `pageView`; this outer wrapper supplies the visual page
    /// object without clipping the shadow.
    private let pageShadowView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.12
        v.layer.shadowRadius = 14
        v.layer.shadowOffset = CGSize(width: 0, height: 5)
        return v
    }()

    /// The bounded profile page surface. Root nodes are positioned in this
    /// view's coordinate space. Clipping makes page bounds explicit while the
    /// selection overlay remains outside in `contentView`.
    private let pageView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = uiColor(hex: ProfileDocument.defaultPageBackgroundHex)
        v.clipsToBounds = true
        v.layer.borderColor = UIColor.separator.cgColor
        v.layer.borderWidth = 1
        return v
    }()

    private var contentWidthConstraint: NSLayoutConstraint?
    /// Drives `contentView.height`. Updated by `updateContentHeight()`
    /// based on page height and viewport height.
    private var contentHeightConstraint: NSLayoutConstraint?
    private var pageWidthConstraint: NSLayoutConstraint?
    private var pageHeightConstraint: NSLayoutConstraint?

    /// Page-level background image. Sits at the very back of the subview
    /// stack inside `pageView` so node views render on top. Hidden when the document has
    /// no `pageBackgroundImagePath`. `isUserInteractionEnabled = false`
    /// so it never claims taps — empty-canvas touches still reach the
    /// `CanvasEditorView`'s tap recognizer for deselect.
    private let backgroundImageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// LRU cache for original (non-filtered) background bitmaps. Keyed
    /// by the relative path *and* the file's modification date so a
    /// **replace** (which keeps the deterministic filename) cleanly
    /// busts the cache. Without `mtime` in the key the canvas would
    /// keep showing the old bytes after a replace.
    ///
    /// Capacity 3 — enough for the user to bounce between two
    /// backgrounds (current + previous) without re-decoding either,
    /// with one slot of headroom for "tried a third, going back". The
    /// previous single-entry tuple forced a re-decode on every
    /// switch.
    private var backgroundImageCache = BackgroundImageLRUCache()

    /// Async render coordination. CoreImage on the main thread blocks
    /// SwiftUI re-renders, which makes the blur / vignette slider stutter
    /// visibly. We dispatch the filter pass to a background queue and
    /// coalesce in-flight requests: if a tick arrives while a render is
    /// already running, we stash only its parameters and the running
    /// task picks them up the moment it finishes. Latest-wins, so the
    /// user's final slider position always lands in the visible result.
    private var isRenderingBackground = false
    private var pendingBackgroundEffects: (image: UIImage, blur: Double, vignette: Double)?

    /// Signature of the last document state we actually applied. Lets us
    /// skip whole `apply(...)` passes when nothing background-relevant
    /// changed (e.g., a node mutation that doesn't touch the page).
    /// Includes `mtime` so an in-place file replace counts as a change.
    private var lastBackgroundSignature: (path: String?, mtime: Date?, blur: Double, vignette: Double) = (nil, nil, 0, 0)

    /// Snapshot taken at the start of a drag/resize, so each `.changed` event
    /// can compute an absolute-from-translation frame instead of accumulating
    /// translation deltas (UIPanGestureRecognizer reports cumulative
    /// translation since `.began` by default).
    private var dragStartFrame: CGRect = .zero
    /// Snapshot of every descendant's frame at the start of a resize.
    /// Used to scale children proportionally as the resized node's
    /// bounds change — without this, resizing a container leaves its
    /// children at fixed local positions and they get clipped /
    /// stranded as the parent grows or shrinks. Cleared on gesture
    /// end. Empty for resizes on leaf nodes (text, image, etc.).
    private var dragStartDescendantFrames: [UUID: CGRect] = [:]
    private let pageTopPadding: CGFloat = 24
    private let pageBottomPadding: CGFloat = 48

    // MARK: - SwiftUI bridges

    /// Called when the user taps a node (or empty canvas to deselect).
    var onSelectionChanged: ((UUID?) -> Void)?

    /// Called whenever the model is mutated by a user gesture and the
    /// gesture has ended (drag-end, resize-end). The caller persists.
    var onCommit: ((ProfileDocument) -> Void)?

    /// Called when the user long-presses a node — a "fast path to the
    /// inspector". The canvas has already updated its own selection
    /// and fired a haptic before this fires; the host's job is to
    /// surface the property inspector for the same node.
    var onRequestEditNode: ((UUID) -> Void)?

    /// When `false`, the canvas runs as a **read-only viewer**:
    /// - No pan / long-press recognizers are attached to nodes.
    /// - The empty-canvas tap recognizer is a no-op (no select/deselect).
    /// - The selection overlay never shows.
    /// - Tapping a `.link` node fires `onOpenURL` so the host can
    ///   route the destination to Safari (or whichever URL handler).
    /// Defaults to `true` so existing editor uses are unchanged.
    /// Set this once at construction (`CanvasEditorContainer` does that
    /// based on the SwiftUI parameter); flipping it at runtime would
    /// require also re-attaching gestures, which we don't need today.
    var isInteractive: Bool = true {
        didSet {
            // If a host flips this on a live view, hide the overlay
            // immediately. New gestures will only attach the next time
            // a render view is created — acceptable because both the
            // editor and the viewer set this value once at init.
            if !isInteractive {
                overlay.isHidden = true
            }
        }
    }

    /// Called when the user taps a `.link` node while `isInteractive`
    /// is `false`. The argument is the resolved URL — link bodies that
    /// don't parse as a URL are filtered before this fires.
    var onOpenURL: ((URL) -> Void)?

    /// Called when the user taps a tile inside a `.gallery` node while
    /// `isInteractive` is `false`. Receives the **full ordered list** of
    /// remote URLs in the gallery plus the index of the tapped image so
    /// the host can present a paginated lightbox. Galleries with a
    /// mix of local and remote paths surface only the remote ones; the
    /// index is rebased to point at the user's tap inside the filtered
    /// list. Galleries with zero remote images fall through silently.
    var onOpenImage: (([URL], Int) -> Void)?

    /// Called when the user taps a `.container` node whose `name`
    /// reads as a Journal Card while `isInteractive` is `false`. The
    /// host pulls the title + body off the container's text
    /// descendants and presents a journal-page modal. Match is
    /// case-insensitive against `"journal card"` so user-renamed
    /// cards (e.g. "Journal card") still trigger.
    var onOpenJournal: ((UUID) -> Void)?

    /// Called when the user taps the "View Gallery" chip on a
    /// `.gallery` node while `isInteractive` is `false`. Receives
    /// the gallery's full URL list so the host can present the
    /// paginated grid (`FullGalleryView`).
    var onOpenFullGallery: (([URL]) -> Void)?


    // MARK: - Init

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .secondarySystemGroupedBackground

        // Scrollable content stack: scrollView → contentView → page → nodes.
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
        ])
        let w = contentView.widthAnchor.constraint(equalToConstant: ProfileDocument.defaultPageWidth)
        w.priority = .required
        w.isActive = true
        contentWidthConstraint = w
        let h = contentView.heightAnchor.constraint(equalToConstant: 0)
        h.priority = .required
        h.isActive = true
        contentHeightConstraint = h

        contentView.addSubview(pageShadowView)
        pageShadowView.addSubview(pageView)
        pageView.addSubview(backgroundImageView)

        let pageW = pageShadowView.widthAnchor.constraint(equalToConstant: ProfileDocument.defaultPageWidth)
        let pageH = pageShadowView.heightAnchor.constraint(equalToConstant: ProfileDocument.defaultPageHeight)
        pageW.isActive = true
        pageH.isActive = true
        pageWidthConstraint = pageW
        pageHeightConstraint = pageH

        NSLayoutConstraint.activate([
            pageShadowView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pageTopPadding),
            pageShadowView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            pageView.leadingAnchor.constraint(equalTo: pageShadowView.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: pageShadowView.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: pageShadowView.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: pageShadowView.bottomAnchor),

            backgroundImageView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            backgroundImageView.topAnchor.constraint(equalTo: pageView.topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
        ])

        // Tap recognizer on `contentView` so `gesture.location(in:)`
        // is already in content coordinates (not viewport).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        contentView.addGestureRecognizer(tap)

        // Selection overlay lives inside `contentView` so it scrolls
        // along with the selected node while drawing above the page's clipping.
        contentView.addSubview(overlay)
        overlay.isHidden = true
        overlay.frame = .zero

        for handle in [overlay.topLeft, overlay.topRight, overlay.bottomLeft, overlay.bottomRight] {
            handle.referenceView = contentView
            let corner = handle.corner
            handle.onPan = { [weak self] state, translation in
                self?.handleResize(corner: corner, state: state, translation: translation)
            }
        }



        // Lift only the *editing text node* (not the whole canvas)
        // above the keyboard so the user always sees what they're
        // typing. A single change-frame notification covers show /
        // hide / predictive-bar toggle in one handler.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Reconciliation

    /// Apply a fresh document and selection state to the canvas. Reuses
    /// existing render views where IDs match; creates them where new; tears
    /// down where missing.
    func apply(document: ProfileDocument, selectedID: UUID?) {
        // Selection move → dismiss any active in-place text editor so
        // the keyboard goes down (no orphaned focus on a node the user
        // already navigated away from).
        if let editingID = editingTextNodeID, editingID != selectedID {
            (renderViews[editingID] as? TextNodeView)?.endEditing()
            editingTextNodeID = nil
        }

        self.document = document
        self.selectedID = selectedID

        backgroundColor = .secondarySystemGroupedBackground
        pageView.backgroundColor = uiColor(hex: document.pageBackgroundHex)
        applyPageSizing(for: document)

        // Page background image + effects. Three optimizations vs. the
        // straightforward sync path:
        //   1. Skip the work entirely when nothing background-relevant
        //      changed (so an unrelated apply pass is free).
        //   2. Cache the loaded `UIImage` by path so a slider drag
        //      doesn't re-decode the JPEG on every tick.
        //   3. Filter rendering runs off the main thread with
        //      coalescing — see `scheduleBackgroundFilterRender`.
        // The on-disk file is never modified; effects are recomputed
        // from the original bitmap each time, so sliding back to 0
        // restores pixel-perfect quality.
        let path = document.pageBackgroundImagePath
        let blur = document.pageBackgroundBlur ?? 0
        let vignette = document.pageBackgroundVignette ?? 0
        let mtime = LocalCanvasAssetStore.modificationDate(path)

        let signatureChanged =
            lastBackgroundSignature.path != path ||
            lastBackgroundSignature.mtime != mtime ||
            lastBackgroundSignature.blur != blur ||
            lastBackgroundSignature.vignette != vignette

        if signatureChanged {
            if let path, !path.isEmpty,
               let original = cachedOrLoadBackgroundOriginal(path: path, mtime: mtime) {
                backgroundImageView.isHidden = false
                if blur <= 0.01 && vignette <= 0.01 {
                    // No filter — instant assignment, no GPU work.
                    backgroundImageView.image = original
                } else {
                    scheduleBackgroundFilterRender(image: original, blur: blur, vignette: vignette)
                }
            } else {
                // Path went away (clear) or load failed. Don't wipe
                // the LRU here — keeping prior entries warm is the
                // whole point. Just hide the view; the next show
                // will pull from cache if the same key returns.
                backgroundImageView.image = nil
                backgroundImageView.isHidden = true
            }
            lastBackgroundSignature = (path, mtime, blur, vignette)
        }
        pageView.sendSubviewToBack(backgroundImageView)

        // Walk the live tree, ensuring each node has a render view in the
        // right superview, then prune any cached views whose IDs are gone.
        // Root children live inside `pageView`, which is the bounded profile
        // page surface. Nested children live inside container node views.
        var liveIDs: Set<UUID> = []

        for childID in document.rootChildrenIDs {
            applyNode(id: childID, parent: pageView, liveIDs: &liveIDs)
        }

        // Prune orphans (deleted nodes).
        for (id, view) in renderViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            renderViews.removeValue(forKey: id)
            appliedNodeSignatures.removeValue(forKey: id)
            nodePanGestures.removeValue(forKey: id)
            nodeLongPressGestures.removeValue(forKey: id)
        }

        // Apply z-order: subviews must be ordered to match `childrenIDs`.
        // Wrapped in a CATransaction with implicit actions disabled so
        // every `bringSubviewToFront` / `sendSubviewToBack` inside this
        // block coalesces into a single layout pass — on dense canvases
        // each individual call would otherwise schedule its own
        // `setNeedsLayout` and the layout invalidation count exploded.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyZOrder(parentID: nil, in: pageView)
        for (id, view) in renderViews {
            if document.nodes[id]?.type == .container {
                applyZOrder(parentID: id, in: view)
            } else if document.nodes[id]?.type == .carousel,
                      let carousel = view as? CarouselNodeView {
                applyZOrder(parentID: id, in: carousel.itemHostView)
                carousel.updateContentSizeToFitItems()
            }
        }
        pageView.sendSubviewToBack(backgroundImageView)

        // Selection overlay tracks the selected node, regardless of nesting.
        contentView.bringSubviewToFront(overlay)
        CATransaction.commit()
        if let selectedID, let node = renderViews[selectedID] {
            overlay.isHidden = false
            overlay.frame = contentView.convert(node.bounds, from: node)
        } else {
            overlay.isHidden = true
        }

        // Suppress horizontal scrolling only while the active selection
        // is inside that carousel. That lets a selected child node own
        // drag-to-move, while keeping normal x-axis scrolling available
        // when the carousel itself is selected.
        for (id, view) in renderViews {
            if let carousel = view as? CarouselNodeView {
                let selectedInsideCarousel = selectedID.map { isAncestor(id, of: $0) } ?? false
                carousel.setScrollingSuppressed(selectedInsideCarousel)
            }
        }

        // Resize the scrollable content to fit the bottommost root
        // node — the canvas grows downward as the user adds /
        // positions content past the viewport.
        updateContentHeight()
    }

    private func applyNode(id: UUID, parent: UIView, liveIDs: inout Set<UUID>) {
        guard let node = document.nodes[id] else { return }
        liveIDs.insert(id)

        let view: NodeRenderView
        if let existing = renderViews[id], type(of: existing) == expectedType(for: node) {
            view = existing
        } else {
            // Create or recreate (rare — only if the node type changed, which
            // we don't allow yet).
            renderViews[id]?.removeFromSuperview()
            appliedNodeSignatures.removeValue(forKey: id)
            let fresh = makeRenderView(for: node)
            renderViews[id] = fresh
            view = fresh
            attachPanGesture(to: view)
        }
        if isInteractive, nodePanGestures[id] == nil {
            attachPanGesture(to: view)
        }

        let movedSuperview = view.superview !== parent
        if movedSuperview {
            view.removeFromSuperview()
            parent.addSubview(view)
        }
        let signature = renderSignature(for: node)
        if movedSuperview || appliedNodeSignatures[id] != signature {
            view.apply(node: node)
            appliedNodeSignatures[id] = signature
            #if DEBUG
            CanvasEditorRenderStats.applyCount &+= 1
            #endif
        }

        // Recurse for containers.
        if node.type == .container {
            for childID in node.childrenIDs {
                applyNode(id: childID, parent: view, liveIDs: &liveIDs)
            }
        } else if node.type == .carousel, let carousel = view as? CarouselNodeView {
            // Carousel children mount directly into the strip's scroll
            // content. Their frames are in content coordinates, so
            // horizontal scrolling only changes what part of that child
            // coordinate space is visible.
            for childID in node.childrenIDs {
                applyNode(id: childID, parent: carousel.itemHostView, liveIDs: &liveIDs)
            }
            carousel.updateContentSizeToFitItems()
        }
    }

    private func expectedType(for node: CanvasNode) -> NodeRenderView.Type {
        switch node.type {
        case .container: return ContainerNodeView.self
        case .text:      return TextNodeView.self
        case .image:     return ImageNodeView.self
        case .icon:      return IconNodeView.self
        case .divider:   return DividerNodeView.self
        case .link:      return LinkNodeView.self
        case .gallery:   return GalleryNodeView.self
        case .carousel:  return CarouselNodeView.self
        }
    }

    private func makeRenderView(for node: CanvasNode) -> NodeRenderView {
        switch node.type {
        case .container:
            return ContainerNodeView(nodeID: node.id)
        case .text:
            let view = TextNodeView(nodeID: node.id)
            // Mirror keystrokes into the in-memory document. We do NOT
            // call `onCommit` here — committing on every keypress would
            // hammer SwiftData. Persistence happens once when editing
            // finishes (`onEditingEnded`).
            view.onTextChanged = { [weak self, weak view] newText in
                guard let self, let view else { return }
                if var node = self.document.nodes[view.nodeID] {
                    node.content.text = newText
                    self.document.nodes[view.nodeID] = node
                }
            }
            view.onEditingEnded = { [weak self, weak view] in
                guard let self else { return }
                // Animate the text node back to its original position
                // and restore parent clipping that was relaxed for the
                // edit. Match the system keyboard's hide animation so
                // the node and the keyboard slide down together.
                if let view {
                    UIView.animate(withDuration: 0.25,
                                   delay: 0,
                                   options: [.curveEaseInOut, .beginFromCurrentState]) {
                        view.transform = .identity
                    }
                }
                self.restoreEditingNodeChain()
                self.editingTextNodeID = nil
                self.applyOverlayForCurrentSelection()
                self.onCommit?(self.document)
            }
            return view
        case .image:
            return ImageNodeView(nodeID: node.id)
        case .icon:
            return IconNodeView(nodeID: node.id)
        case .divider:
            return DividerNodeView(nodeID: node.id)
        case .link:
            return LinkNodeView(nodeID: node.id)
        case .carousel:
            return CarouselNodeView(nodeID: node.id)
        case .gallery:
            let view = GalleryNodeView(nodeID: node.id)
            // Wire per-tile + view-all callbacks only in viewer
            // mode. Editor mode leaves both nil so the gallery's
            // chrome looks identical to what the author drew (no
            // chip, no tile-tap interception).
            if !isInteractive {
                view.onTileTapped = { [weak self] index in
                    self?.openGalleryTile(nodeID: node.id, tappedIndex: index)
                }
                view.onViewAll = { [weak self] in
                    self?.openFullGallery(nodeID: node.id)
                }
            }
            return view
        }
    }

    /// Build the gallery's URL list and forward to the host's
    /// `onOpenFullGallery` callback. Mirrors `openGalleryTile`'s
    /// remote-only filter so the grid never tries to load a path
    /// that points at a local-only file the viewer can't see.
    private func openFullGallery(nodeID: UUID) {
        guard let node = document.nodes[nodeID],
              node.type == .gallery,
              let paths = node.content.imagePaths,
              !paths.isEmpty else { return }
        let urls: [URL] = paths.compactMap { raw in
            guard CanvasImageLoader.isRemote(raw) else { return nil }
            return URL(string: raw)
        }
        guard !urls.isEmpty else { return }
        onOpenFullGallery?(urls)
    }

    /// Resolve a tapped gallery tile to its public URL list + initial
    /// index, then forward up to the SwiftUI host. The list is
    /// filtered to remote URLs only (the publish flow rewrites every
    /// path to a Supabase public URL, so for a published profile this
    /// matches the gallery 1:1; defensive nonetheless). The tapped
    /// index is rebased so it points at the same image inside the
    /// filtered list.
    private func openGalleryTile(nodeID: UUID, tappedIndex: Int) {
        guard let node = document.nodes[nodeID],
              node.type == .gallery,
              let paths = node.content.imagePaths,
              tappedIndex >= 0, tappedIndex < paths.count else { return }

        var urls: [URL] = []
        var rebasedIndex: Int = -1
        for (i, raw) in paths.enumerated() {
            guard CanvasImageLoader.isRemote(raw),
                  let url = URL(string: raw) else { continue }
            if i == tappedIndex { rebasedIndex = urls.count }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        // If the tapped index pointed at a non-remote slot, fall back
        // to the first remote image so the lightbox still opens at a
        // sensible page.
        let initial = rebasedIndex >= 0 ? rebasedIndex : 0
        onOpenImage?(urls, initial)
    }

    private func renderSignature(for node: CanvasNode) -> NodeRenderSignature {
        NodeRenderSignature(
            frame: node.frame,
            style: node.style,
            content: node.content,
            name: node.name,
            opacity: node.opacity,
            localImageModificationDate: LocalCanvasAssetStore.modificationDate(node.content.localImagePath),
            backgroundImageModificationDate: LocalCanvasAssetStore.modificationDate(node.style.backgroundImagePath),
            galleryImageModificationDates: (node.content.imagePaths ?? []).map {
                LocalCanvasAssetStore.modificationDate($0)
            }
        )
    }

    private func applyZOrder(parentID: UUID?, in container: UIView) {
        let order = document.children(of: parentID)
        for id in order {
            if let v = renderViews[id], v.superview === container {
                container.bringSubviewToFront(v)
            }
        }
        // After ordering children, push the container's own effect
        // overlays (frosted blur + vignette) back to the very front
        // so they layer on top of every child instead of being buried
        // by the latest `addSubview` for a child.
        if let containerView = container as? ContainerNodeView {
            containerView.bringEffectOverlaysToFront()
        }
        // Ensure the selection overlay is in front of root content.
        if container === pageView {
            contentView.bringSubviewToFront(overlay)
        }
    }

    // MARK: - Gestures: select / deselect

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Viewer mode: nothing to select. The recognizer stays
        // attached because it lives on `contentView` (we don't need
        // to tear it down per render-view), but it short-circuits
        // here so empty taps don't push spurious `selectedID` updates
        // through to SwiftUI.
        guard isInteractive else { return }

        // Tap recognizer is on `contentView`, so the location is
        // already in content coordinates — same space the node frames
        // and `applyZOrder` use, so the hit-test recursion just works.
        let point = gesture.location(in: contentView)
        let hit = hitTestNode(at: point)

        // Tapping the already-selected text node a second time enters
        // direct in-place editing — keyboard up, cursor in the box.
        if let hit, hit == selectedID,
           document.nodes[hit]?.type == .text,
           let textView = renderViews[hit] as? TextNodeView,
           !textView.isEditing {
            editingTextNodeID = hit
            // Bring the editing node to the front of its parent so the
            // upcoming lift transform can extend visually above sibling
            // nodes without being clipped by them. Also bring the whole
            // chain of ancestors to the front so the lifted text isn't
            // covered by anything.
            bringEditingNodeChainToFront(view: textView)
            textView.beginEditing()
            return
        }

        if hit != selectedID {
            // Selection moved — dismiss any active text editor first so
            // the keyboard goes down cleanly.
            endActiveTextEditingIfNeeded(except: hit)
            selectedID = hit
            applyOverlayForCurrentSelection()
            onSelectionChanged?(hit)
        }
    }

    /// Resign first responder on whichever text node is editing —
    /// unless that node IS the new selection (rare, but possible if
    /// the same node is re-selected).
    private func endActiveTextEditingIfNeeded(except keepEditingID: UUID?) {
        guard let editingID = editingTextNodeID, editingID != keepEditingID else { return }
        if let view = renderViews[editingID] as? TextNodeView {
            view.endEditing()
        }
        editingTextNodeID = nil
    }

    /// Custom hit-test. Recursive depth-first, reverse children order, so the
    /// highest-z sibling wins. A point inside a container that doesn't hit
    /// any child returns the container itself.
    private func hitTestNode(at point: CGPoint) -> UUID? {
        let pagePoint = contentView.convert(point, to: pageView)
        guard pageView.bounds.contains(pagePoint) else { return nil }
        return hitTestNode(at: pagePoint, in: pageView, parent: nil)
    }

    private func hitTestNode(at point: CGPoint, in superview: UIView, parent: UUID?) -> UUID? {
        let order = document.children(of: parent)
        for id in order.reversed() {
            guard let view = renderViews[id] else { continue }
            let local = superview.convert(point, to: view)
            if view.bounds.contains(local) {
                if document.nodes[id]?.type == .carousel {
                    if let inner = hitTestNode(at: local, in: view, parent: id) {
                        return inner
                    }
                    return id
                } else if document.nodes[id]?.type == .container,
                          let inner = hitTestNode(at: local, in: view, parent: id) {
                    return inner
                }
                return id
            }
        }
        return nil
    }

    private func applyOverlayForCurrentSelection() {
        if let selectedID, let node = renderViews[selectedID] {
            overlay.isHidden = false
            overlay.frame = contentView.convert(node.bounds, from: node)
            contentView.bringSubviewToFront(overlay)
        } else {
            overlay.isHidden = true
        }
    }

    // MARK: - Gestures: drag-to-move

    private func attachPanGesture(to view: NodeRenderView) {
        // Read-only viewer: skip every editor gesture. Only two
        // node-type-specific tap recognizers ride along:
        //   - `.link` → opens the destination URL via `onOpenURL`
        //   - `.container` named "journal card" (case-insensitive)
        //     → opens the journal modal via `onOpenJournal`
        // Every other node type stays inert in viewer mode, which
        // is what "view only" should feel like.
        guard isInteractive else {
            guard let node = document.nodes[view.nodeID] else { return }
            switch node.type {
            case .link:
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
                tap.numberOfTapsRequired = 1
                view.addGestureRecognizer(tap)
                view.isUserInteractionEnabled = true
            case .container:
                let trimmedName = node.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmedName == "journal card" {
                    let tap = UITapGestureRecognizer(
                        target: self,
                        action: #selector(handleJournalCardTap(_:))
                    )
                    tap.numberOfTapsRequired = 1
                    view.addGestureRecognizer(tap)
                    view.isUserInteractionEnabled = true
                }
            default:
                break
            }
            return
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleNodePan(_:)))
        pan.maximumNumberOfTouches = 1
        // Set ourselves as the delegate so we can refuse to start an
        // ancestor's pan when the touch actually lives inside one of its
        // descendants (see `gestureRecognizerShouldBegin`). Without this,
        // touching a deeply-nested node would race the ancestor's pan and
        // sometimes drag the wrong layer.
        pan.delegate = self
        view.addGestureRecognizer(pan)
        nodePanGestures[view.nodeID] = pan

        // Carousels host an internal horizontal UIScrollView whose pan
        // recognizer would otherwise win every touch (it sits deeper
        // in the hit-test chain than this outer pan). Tell the
        // scrollview's pan to wait until the outer pan has had its
        // chance — `gestureRecognizerShouldBegin` refuses the outer
        // pan immediately when the carousel isn't selected, which
        // unblocks strip scrolling. When the carousel is selected,
        // the delegate chooses between scrolling the strip and moving
        // the carousel.
        if let carousel = view as? CarouselNodeView {
            carousel.requireScrollPanToFail(pan)
        }

        // Long-press recognizer: opens the inspector for the pressed
        // node. Defaults of `minimumPressDuration = 0.4s` and
        // `allowableMovement = 10pt` give the user a quick "hold to
        // edit" gesture without stealing drags — once the finger
        // moves more than 10pt before the duration elapses, the long
        // press fails and the pan above takes over the touch.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleNodeLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = 10
        longPress.numberOfTouchesRequired = 1
        // Same delegate as pan so nested nodes follow the same
        // "selection wins over depth, otherwise deepest wins" rule.
        longPress.delegate = self
        view.addGestureRecognizer(longPress)
        nodeLongPressGestures[view.nodeID] = longPress
    }

    /// Viewer-mode handler for tap-on-journal-card. The card's
    /// container node ID is forwarded to the SwiftUI host, which
    /// extracts the title + body from text descendants and presents
    /// `JournalModalView`. The canvas itself doesn't peek into
    /// children — keeping the data extraction in the SwiftUI layer
    /// lets `JournalContent` evolve without rebuilding the canvas.
    @objc private func handleJournalCardTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? NodeRenderView else { return }
        onOpenJournal?(view.nodeID)
    }

    /// Viewer-mode handler for tap-on-link. Pulls the URL out of the
    /// node's content, normalises it (adds `https://` when scheme is
    /// missing — users typing "example.com" expect the tap to work),
    /// and hands it to the host via `onOpenURL`. No haptic here: the
    /// host's URL opener triggers system feedback on its own.
    @objc private func handleLinkTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? NodeRenderView,
              let node = document.nodes[view.nodeID],
              node.type == .link,
              let raw = node.content.url else { return }
        guard let url = Self.resolveLinkURL(raw) else { return }
        onOpenURL?(url)
    }

    /// Best-effort URL resolution for a free-form `node.content.url`
    /// string. Returns nil for empty / clearly-malformed input. A
    /// missing scheme is filled in with `https://` so the iOS user's
    /// muscle memory of typing "tiktok.com/@me" still routes somewhere.
    static func resolveLinkURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        // Reject obviously-non-URL strings to avoid opening Safari to
        // garbage (no dot, single token, etc.). A real URL will have
        // at least one period in the host portion.
        guard trimmed.contains(".") else { return nil }
        return URL(string: "https://" + trimmed)
    }

    @objc private func handleNodeLongPress(_ gesture: UILongPressGestureRecognizer) {
        // We only act on the single `.began` transition — long-press
        // recognizers continue to fire `.changed` events while the
        // finger is held, which would re-open the inspector and pulse
        // the haptic over and over.
        guard gesture.state == .began,
              let view = gesture.view as? NodeRenderView else { return }
        let id = view.nodeID

        // If the pressed node isn't yet selected, end any active
        // text-edit on a different node so the keyboard goes down
        // before the inspector takes over.
        if selectedID != id {
            endActiveTextEditingIfNeeded(except: id)
            selectedID = id
            applyOverlayForCurrentSelection()
            onSelectionChanged?(id)
        }

        // Single haptic per recognized press.
        editHapticGenerator.prepare()
        editHapticGenerator.impactOccurred()

        // Hand off to the host so it can present the inspector. The
        // canvas owns selection and the haptic; presenting modals is
        // a SwiftUI concern.
        onRequestEditNode?(id)
    }

    @objc private func handleNodePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view as? NodeRenderView else { return }
        let id = view.nodeID

        switch gesture.state {
        case .began:
            // Tapping a node implicitly selects it before drag begins. This
            // also handles the case where a deeply nested node is dragged
            // without the user explicitly tapping first.
            if selectedID != id {
                // End any active text editor first so the keyboard goes
                // down before the drag starts.
                endActiveTextEditingIfNeeded(except: id)
                selectedID = id
                onSelectionChanged?(id)
            }
            dragStartFrame = view.frame

        case .changed:
            // Move the dragged view by mutating its `frame` directly.
            // Nested children follow automatically because they are real
            // UIKit subviews of this view, and their frames are in this
            // view's coordinate space — moving the parent moves the
            // entire subtree visually, with no manual translation needed.
            // The document is not touched until `.ended` so SwiftUI does
            // not re-render mid-drag and stomp the in-flight frame.
            let translation = gesture.translation(in: view.superview)
            var newFrame = dragStartFrame
            newFrame.origin.x += translation.x
            newFrame.origin.y += translation.y
            view.frame = newFrame
            // For root-level nodes, grow the scrollable canvas live so
            // the user can drag past the previous bottom without
            // clipping. (Children of containers are bounded by their
            // container's clipping, which is the desired behavior.)
              if view.superview === pageView {
                  growPageHeightIfNeeded(toContain: newFrame.maxY)
              }
              nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
              applyOverlayForCurrentSelection()

        case .ended, .cancelled:
            // Commit the new frame to the document and notify the host.
            if var node = document.nodes[id] {
                node.frame = NodeFrame(view.frame)
                document.nodes[id] = node
                  if view.superview === pageView {
                      commitPageHeightIfNeeded(toContain: view.frame.maxY)
                  }
                  nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
                  onCommit?(document)
              }

        default:
            break
        }
    }

    // MARK: - Gestures: resize

    private func handleResize(corner: ResizeHandleView.Corner,
                              state: UIPanGestureRecognizer.State,
                              translation: CGPoint) {
        guard let id = selectedID,
              let view = renderViews[id] else { return }

        switch state {
        case .began:
            dragStartFrame = view.frame
            // Snapshot every descendant's current frame so `.changed`
            // can compute scaled frames from the original layout
            // each tick. Without an absolute snapshot we'd compound
            // floating-point error as the user drags back and forth.
            // Frames live in each descendant's own parent coord space
            // — every frame in the subtree scales by the same factor
            // because every parent's bounds scale by the same factor,
            // so a single multiplier preserves relative positions
            // throughout.
            dragStartDescendantFrames.removeAll()
            for descendantID in document.subtree(rootedAt: id) where descendantID != id {
                if let descendantView = renderViews[descendantID] {
                    dragStartDescendantFrames[descendantID] = descendantView.frame
                }
            }

        case .changed:
            // Translation arrives in canvas-root coords. With no transforms
            // in ancestors (Phase 1 invariant), this vector equals the
            // translation in the node's parent space.
            var newFrame = dragStartFrame
            switch corner {
            case .topLeft:
                newFrame.origin.x += translation.x
                newFrame.origin.y += translation.y
                newFrame.size.width -= translation.x
                newFrame.size.height -= translation.y
            case .topRight:
                newFrame.origin.y += translation.y
                newFrame.size.width += translation.x
                newFrame.size.height -= translation.y
            case .bottomLeft:
                newFrame.origin.x += translation.x
                newFrame.size.width -= translation.x
                newFrame.size.height += translation.y
            case .bottomRight:
                newFrame.size.width += translation.x
                newFrame.size.height += translation.y
            }

            // Aspect-lock when the node is in Circle mode so dragging a corner
            // keeps the shape a true circle (not a capsule). Pivot around the
            // corner opposite the one being dragged so the user feels the
            // resize anchor as fixed. Use the larger of the two requested
            // sizes — that matches Shift-resize behavior in Figma/Sketch and
            // avoids surprise shrink-to-zero when the user pulls outward.
            if document.nodes[id]?.style.clipShape == .circle {
                let side = max(newFrame.size.width, newFrame.size.height)
                switch corner {
                case .topLeft:
                    newFrame.origin.x = dragStartFrame.maxX - side
                    newFrame.origin.y = dragStartFrame.maxY - side
                case .topRight:
                    newFrame.origin.x = dragStartFrame.minX
                    newFrame.origin.y = dragStartFrame.maxY - side
                case .bottomLeft:
                    newFrame.origin.x = dragStartFrame.maxX - side
                    newFrame.origin.y = dragStartFrame.minY
                case .bottomRight:
                    newFrame.origin.x = dragStartFrame.minX
                    newFrame.origin.y = dragStartFrame.minY
                }
                newFrame.size.width = side
                newFrame.size.height = side
            }

            // Min size clamp: don't allow the frame to collapse past 24x24.
            if newFrame.size.width < 24 {
                if corner == .topLeft || corner == .bottomLeft {
                    newFrame.origin.x = dragStartFrame.maxX - 24
                }
                newFrame.size.width = 24
            }
            if newFrame.size.height < 24 {
                if corner == .topLeft || corner == .topRight {
                    newFrame.origin.y = dragStartFrame.maxY - 24
                }
                newFrame.size.height = 24
            }
            view.frame = newFrame

            // Scale every descendant's UIView frame by the same
            // ratio as the resize. Pure visual update during the
            // gesture — the document is not mutated until `.ended`
            // so SwiftUI doesn't re-render mid-drag and stomp on
            // the in-flight frames.
            applyDescendantScale(
                in: dragStartDescendantFrames,
                scaleX: dragStartFrame.width > 0 ? newFrame.width / dragStartFrame.width : 1,
                scaleY: dragStartFrame.height > 0 ? newFrame.height / dragStartFrame.height : 1
            )

              if view.superview === pageView {
                  growPageHeightIfNeeded(toContain: newFrame.maxY)
              }
              nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
              applyOverlayForCurrentSelection()

        case .ended, .cancelled:
            // Commit the resized frame plus every scaled descendant
            // frame. Doing both before `onCommit` so SwiftUI sees a
            // single coherent document update — partial commits would
            // trigger an apply pass that snaps the children back to
            // their pre-resize positions.
            let finalScaleX = dragStartFrame.width > 0
                ? view.frame.width / dragStartFrame.width
                : 1
            let finalScaleY = dragStartFrame.height > 0
                ? view.frame.height / dragStartFrame.height
                : 1

            if var node = document.nodes[id] {
                node.frame = NodeFrame(view.frame)
                document.nodes[id] = node
            }
            for (descendantID, originalFrame) in dragStartDescendantFrames {
                guard var descendant = document.nodes[descendantID] else { continue }
                descendant.frame = NodeFrame(CGRect(
                    x: originalFrame.origin.x * finalScaleX,
                    y: originalFrame.origin.y * finalScaleY,
                    width: originalFrame.width * finalScaleX,
                    height: originalFrame.height * finalScaleY
                ))
                document.nodes[descendantID] = descendant
            }
            dragStartDescendantFrames.removeAll()

            if document.nodes[id] != nil {
                  if view.superview === pageView {
                      commitPageHeightIfNeeded(toContain: view.frame.maxY)
                  }
                  nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
                  onCommit?(document)
              }

        default:
            break
        }
    }

    /// Apply uniform `(scaleX, scaleY)` to every descendant render
    /// view's frame, anchored on the descendant's *original* frame
    /// captured at gesture-begin. Uniform scaling across the whole
    /// subtree works because each descendant's frame lives in its
    /// own parent's local space, and every parent in the chain
    /// scales by the same factor.
    private func applyDescendantScale(in originalFrames: [UUID: CGRect],
                                      scaleX: CGFloat,
                                      scaleY: CGFloat) {
        guard !originalFrames.isEmpty else { return }
        for (descendantID, originalFrame) in originalFrames {
            guard let descendantView = renderViews[descendantID] else { continue }
            descendantView.frame = CGRect(
                x: originalFrame.origin.x * scaleX,
                y: originalFrame.origin.y * scaleY,
                width: originalFrame.width * scaleX,
                height: originalFrame.height * scaleY
              )
          }
      }

      private func nearestCarouselAncestor(of view: UIView) -> CarouselNodeView? {
          var current = view.superview
          while let candidate = current {
              if let carousel = candidate as? CarouselNodeView {
                  return carousel
              }
              current = candidate.superview
          }
          return nil
      }

      // MARK: - Background image cache + async filter

    /// Returns the original (pre-filter) `UIImage` for `path`, decoding
    /// from disk only on a path-or-mtime change. Subsequent calls for
    /// the same path *and* unchanged mtime hit the cache, which is the
    /// difference between butter-smooth slider scrubbing and stuttering.
    /// Including `mtime` lets a same-path replace bust the cache.
    private func cachedOrLoadBackgroundOriginal(path: String, mtime: Date?) -> UIImage? {
        if let cached = backgroundImageCache.image(for: path, mtime: mtime) {
            return cached
        }
        // Local + remote dispatch via the shared canvas image loader.
        // Sync path returns the bytes for local files and remote cache
        // hits; a remote miss returns nil here. We kick off an async
        // fetch and apply the bytes **directly** when they arrive
        // (mirroring `ImageNodeView` / `GalleryNodeView`). The earlier
        // version only nudged `setNeedsLayout()` and reset the
        // signature, expecting the next `apply(document:)` pass to
        // pick up the warm cache — but no such pass fires on its own,
        // so the page background stayed blank until SwiftUI happened
        // to re-emit `updateUIView` (e.g. on navigation back).
        guard let image = CanvasImageLoader.loadSync(path) else {
            if CanvasImageLoader.isRemote(path) {
                CanvasImageLoader.loadAsync(path) { [weak self] fetched in
                    guard let self, let fetched else { return }
                    // Race-guard: the document might have changed
                    // (page bg cleared, swapped) while bytes were in
                    // flight. Drop the result if the path no longer
                    // matches the live document.
                    guard self.document.pageBackgroundImagePath == path else { return }
                    self.applyFetchedPageBackground(image: fetched, path: path, mtime: mtime)
                }
            }
            return nil
        }
        backgroundImageCache.insert(path: path, mtime: mtime, image: image)
        return image
    }

    /// Hook used by the async-fetch path in `cachedOrLoadBackgroundOriginal`.
    /// Applies a freshly-fetched bitmap directly to the page-background
    /// image view (skipping the filter pipeline when blur + vignette
    /// are off), updates the cache, and writes the signature so the
    /// next `apply(document:)` pass short-circuits the work entirely.
    private func applyFetchedPageBackground(image: UIImage, path: String, mtime: Date?) {
        backgroundImageCache.insert(path: path, mtime: mtime, image: image)

        let blur = document.pageBackgroundBlur ?? 0
        let vignette = document.pageBackgroundVignette ?? 0
        backgroundImageView.isHidden = false
        if blur <= 0.01 && vignette <= 0.01 {
            backgroundImageView.image = image
        } else {
            scheduleBackgroundFilterRender(image: image, blur: blur, vignette: vignette)
        }
        // Background sits behind every node view; keep that layering
        // intact since `apply(document:)` is the path that normally
        // calls `sendSubviewToBack` for us.
        pageView.sendSubviewToBack(backgroundImageView)
        lastBackgroundSignature = (path, mtime, blur, vignette)
    }

    /// Run `PageBackgroundEffects.apply(...)` on a background queue and
    /// hand the resulting bitmap back to the main thread. Coalesces
    /// in-flight requests: while a render is running, additional ticks
    /// only update `pendingBackgroundEffects` and the running task
    /// picks up the latest values when it finishes. Net effect: at most
    /// one render is in flight, the user always sees their final slider
    /// position, and the main thread stays free for SwiftUI to redraw.
    private func scheduleBackgroundFilterRender(image: UIImage, blur: Double, vignette: Double) {
        if isRenderingBackground {
            pendingBackgroundEffects = (image, blur, vignette)
            return
        }
        isRenderingBackground = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = PageBackgroundEffects.apply(to: image, blur: blur, vignette: vignette)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.backgroundImageView.image = result
                self.isRenderingBackground = false
                if let pending = self.pendingBackgroundEffects {
                    self.pendingBackgroundEffects = nil
                    self.scheduleBackgroundFilterRender(
                        image: pending.image,
                        blur: pending.blur,
                        vignette: pending.vignette
                    )
                }
            }
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        applyPageSizing(for: document)
        // Re-pin the overlay to the selected node in case bounds changed
        // (e.g., rotation or window resize on iPad).
        applyOverlayForCurrentSelection()
    }

    /// Apply document-level page dimensions to the visible page frame
    /// and keep the scroll content wide/tall enough to show it.
    private func applyPageSizing(for document: ProfileDocument) {
        let pageWidth = effectivePageWidth(for: document)
        let pageHeight = effectivePageHeight(for: document)
        let viewportWidth = scrollView.bounds.width > 0 ? scrollView.bounds.width : bounds.width

        if let constraint = pageWidthConstraint,
           abs(constraint.constant - pageWidth) > 0.5 {
            constraint.constant = pageWidth
        }
        if let constraint = pageHeightConstraint,
           abs(constraint.constant - pageHeight) > 0.5 {
            constraint.constant = pageHeight
        }

        let contentWidth = max(viewportWidth, pageWidth)
        if let constraint = contentWidthConstraint,
           abs(constraint.constant - contentWidth) > 0.5 {
            constraint.constant = contentWidth
        }

        pageShadowView.layer.shadowPath = UIBezierPath(
            rect: CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight))
        ).cgPath
        updateContentHeight()
    }

    private func effectivePageWidth(for document: ProfileDocument) -> CGFloat {
        max(240, CGFloat(document.pageWidth))
    }

    private func effectivePageHeight(for document: ProfileDocument) -> CGFloat {
        let explicitHeight = max(400, CGFloat(document.pageHeight))
        return max(explicitHeight, bottommostRootNodeY(in: document) + 60)
    }

    private func bottommostRootNodeY(in document: ProfileDocument) -> CGFloat {
        var maxY: CGFloat = 0
        for childID in document.rootChildrenIDs {
            guard let node = document.nodes[childID] else { continue }
            maxY = max(maxY, CGFloat(node.frame.y + node.frame.height))
        }
        return maxY
    }

    /// Resize `contentView` to fit either the viewport or the page frame,
    /// whichever is taller. The page itself owns the visible design bounds;
    /// `contentView` is just scroll-space around that page.
    private func updateContentHeight() {
        let viewport = scrollView.bounds.height
        let pageHeight = max(pageHeightConstraint?.constant ?? 0, effectivePageHeight(for: document))
        let target = max(viewport, pageTopPadding + pageHeight + pageBottomPadding)
        if let constraint = contentHeightConstraint,
           abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
        }
    }

    /// Expand the visible page *during* a root drag / resize so the
    /// user can keep moving a node past the previous bottom without
    /// losing it under clipping.
    private func growPageHeightIfNeeded(toContain frameMaxY: CGFloat) {
        let needed = frameMaxY + 60
        if let constraint = pageHeightConstraint, constraint.constant < needed {
            constraint.constant = needed
            updateContentHeight()
        }
    }

    /// Persist auto-grown page height when a root node is committed
    /// beyond the current document height. Old drafts still decode to
    /// the default height, and future edits keep the user-created
    /// bottom space after relaunch.
    private func commitPageHeightIfNeeded(toContain frameMaxY: CGFloat) {
        let needed = Double(frameMaxY + 60)
        if document.pageHeight < needed {
            document.pageHeight = needed
        }
    }

    // MARK: - Keyboard avoidance for in-place text editing

    /// Bring the editing text node and its entire ancestor chain to
    /// the front of their respective superviews, plus disable
    /// `clipsToBounds`/`masksToBounds` on the ancestor containers
    /// only for the duration of the edit, so when we apply a lift
    /// transform to the text node it isn't clipped by a tightly-
    /// fitted parent container. Restored by
    /// `restoreEditingNodeChain()` when editing ends.
    private var modifiedAncestorClipping: [(view: UIView, originalClipsToBounds: Bool, originalMasksToBounds: Bool)] = []

    private func bringEditingNodeChainToFront(view: UIView) {
        var node: UIView? = view
        while let current = node, current !== self {
            current.superview?.bringSubviewToFront(current)
            if let parent = current.superview, parent !== self {
                modifiedAncestorClipping.append((parent, parent.clipsToBounds, parent.layer.masksToBounds))
                parent.clipsToBounds = false
                parent.layer.masksToBounds = false
            }
            node = current.superview
        }
    }

    private func restoreEditingNodeChain() {
        for record in modifiedAncestorClipping {
            record.view.clipsToBounds = record.originalClipsToBounds
            record.view.layer.masksToBounds = record.originalMasksToBounds
        }
        modifiedAncestorClipping.removeAll()
    }

    /// Lift just the editing text node above the keyboard via a
    /// translation transform on that one view. The canvas and every
    /// other node stay put. Layout / hit-testing / selection overlay
    /// all respect the transform, so the user can keep editing as if
    /// the node were always at its original location.
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let editingID = editingTextNodeID,
              let textView = renderViews[editingID],
              let userInfo = note.userInfo,
              let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = window
        else { return }

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

        let screenHeight = window.bounds.height
        let keyboardIsHiding = endFrame.origin.y >= screenHeight - 1

        // Current vertical lift already applied to the text node, so
        // we can compute the unlifted base position and avoid
        // compounding successive frame changes.
        let currentLift = -textView.transform.ty
        let baseTextBottom = window.convert(textView.bounds, from: textView).maxY + currentLift
        let keyboardTop = endFrame.origin.y
        let margin: CGFloat = 16

        let targetLift: CGFloat
        if keyboardIsHiding {
            targetLift = 0
        } else {
            targetLift = max(0, baseTextBottom - (keyboardTop - margin))
        }

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            textView.transform = targetLift > 0 ? CGAffineTransform(translationX: 0, y: -targetLift) : .identity
            self.applyOverlayForCurrentSelection()
        }
    }
}

// MARK: - Gesture delegate (selection-aware arbitration)

extension CanvasEditorView: UIGestureRecognizerDelegate {
    /// Decide which node's pan recognizer wins a touch. The rule is
    /// "selection wins over depth":
    ///
    /// 1. The currently-selected node's pan is always allowed. Even when
    ///    a descendant visually covers it (an image filling its
    ///    container, etc.), dragging anywhere on the selected node's
    ///    bounds drags the selected node.
    /// 2. A descendant of the selected node refuses the touch — its
    ///    pan would otherwise steal the gesture from the ancestor the
    ///    user just selected (e.g. via a breadcrumb chip in the bottom
    ///    bar).
    /// 3. Otherwise, fall back to "deepest wins": an ancestor's pan
    ///    refuses to start if the touch actually lives inside one of
    ///    its descendants. This preserves the auto-select-and-drag
    ///    shortcut for nodes that aren't currently selected — touch a
    ///    deep node, drag, that node moves and becomes selected.
    ///
    /// Without these rules UIKit's default arbitration between competing
    /// pans on the same touch is non-deterministic, and either the
    /// ancestor or the descendant would win unpredictably.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Resolve the touched view and touch point uniformly for both
        // per-node recognizers (pan + long-press). Anything else
        // (e.g. the canvas's tap recognizer or UIScrollView's own
        // pan) falls through to the default `true`.
        let view: NodeRenderView?
        let touchPoint: CGPoint
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            view = pan.view as? NodeRenderView
            touchPoint = pan.location(in: pan.view ?? self)
        } else if let lp = gestureRecognizer as? UILongPressGestureRecognizer {
            view = lp.view as? NodeRenderView
            touchPoint = lp.location(in: lp.view ?? self)
        } else {
            return true
        }
        guard let view else { return true }
        let viewID = view.nodeID

        // ---------- PAN (drag-to-move) ----------
        //
        // Drag is gated by selection: we only let a node's pan
        // recognizer start when that node is the currently-selected
        // one. Why: the canvas page lives inside a `UIScrollView`,
        // and any pan on a node that wins the touch prevents the
        // scroll view from scrolling. Without this gate, *every*
        // attempt to scroll the canvas accidentally dragged whatever
        // node the finger happened to touch on the way down.
        //
        // The user's mental model is now the standard iOS one:
        //   1. Tap a node → it becomes selected (no drag).
        //   2. Press + drag the same node → it moves.
        //   3. Press + drag elsewhere on the canvas → page scrolls.
        //
        // Long press (the inspector shortcut) is intentionally NOT
        // gated by selection: the whole point is to open the editor
        // for whatever node the user is holding. Long-press
        // arbitration uses the existing depth + selection rules.
        if gestureRecognizer is UIPanGestureRecognizer {
            guard let selID = selectedID, selID == viewID else {
                return false
            }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer,
               let carousel = view as? CarouselNodeView,
               carousel.shouldPreferScrolling(forPanVelocity: pan.velocity(in: view)) {
                return false
            }
            return true
        }

        // ---------- LONG PRESS (open-inspector shortcut) ----------
        if let selID = selectedID {
            if selID == viewID {
                // Rule 1: this view IS the selected node — always allow.
                return true
            }
            if isAncestor(selID, of: viewID) {
                // Rule 2: the user explicitly selected an ancestor of
                // this view. The ancestor's own gesture should win.
                return false
            }
        }
        // Rule 3 (default): deepest wins. Refuse if the touch lives
        // inside any descendant of this view.
        return !touchHitsDescendant(of: viewID, in: view, at: touchPoint)
    }

    /// True if `candidateID` is an ancestor of `nodeID` in the document
    /// tree. Walks `parent(of:)` upward; returns false if `nodeID` is at
    /// the page root or `candidateID` isn't on the path.
    private func isAncestor(_ candidateID: UUID, of nodeID: UUID) -> Bool {
        var current: UUID? = document.parent(of: nodeID)
        while let cur = current {
            if cur == candidateID { return true }
            current = document.parent(of: cur)
        }
        return false
    }

    /// True if `point` (in `superview`'s coords) lands inside a descendant
    /// node of `parentID`. Recurses through containers so nesting depth
    /// doesn't matter.
    private func touchHitsDescendant(of parentID: UUID,
                                     in superview: UIView,
                                     at point: CGPoint) -> Bool {
        guard let parent = document.nodes[parentID] else { return false }
        for childID in parent.childrenIDs {
            guard let childView = renderViews[childID] else { continue }
            let childPoint = superview.convert(point, to: childView)
            if childView.bounds.contains(childPoint) {
                return true
            }
            if touchHitsDescendant(of: childID, in: childView, at: childPoint) {
                return true
            }
        }
        return false
    }
}
