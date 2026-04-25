import UIKit

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
    private var nodePanGestures: [UUID: UIPanGestureRecognizer] = [:]

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

    /// Holds every page node + the selection overlay. Width matches
    /// `scrollView.frameLayoutGuide`; height is driven by
    /// `contentHeightConstraint`, which expands as nodes move below
    /// the visible viewport.
    private let contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }()

    /// Drives `contentView.height`. Updated by `updateContentHeight()`
    /// based on the bottommost root node so the scrollable area
    /// always fits the page contents (and never shrinks below the
    /// viewport).
    private var contentHeightConstraint: NSLayoutConstraint?

    /// Page-level background image. Sits at the very back of the subview
    /// stack so node views render on top. Hidden when the document has
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

    /// Cache for the original (non-filtered) background bitmap. Keyed
    /// by the relative path *and* the file's modification date so a
    /// **replace** (which keeps the deterministic filename) cleanly
    /// busts the cache. Without `mtime` in the key the canvas would
    /// keep showing the old bytes after a replace.
    private var cachedBackgroundOriginal: (path: String, mtime: Date?, image: UIImage)?

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

    // MARK: - SwiftUI bridges

    /// Called when the user taps a node (or empty canvas to deselect).
    var onSelectionChanged: ((UUID?) -> Void)?

    /// Called whenever the model is mutated by a user gesture and the
    /// gesture has ended (drag-end, resize-end). The caller persists.
    var onCommit: ((ProfileDocument) -> Void)?


    // MARK: - Init

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = uiColor(hex: ProfileDocument.blank.pageBackgroundHex)

        // Background image — fixed, viewport-aligned, behind the
        // scrollable content. Doesn't scroll with the page.
        addSubview(backgroundImageView)
        NSLayoutConstraint.activate([
            backgroundImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundImageView.topAnchor.constraint(equalTo: topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Scrollable content stack: scrollView → contentView → nodes.
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
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        let h = contentView.heightAnchor.constraint(equalToConstant: 0)
        h.priority = .required
        h.isActive = true
        contentHeightConstraint = h

        // Tap recognizer on `contentView` so `gesture.location(in:)`
        // is already in content coordinates (not viewport).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        contentView.addGestureRecognizer(tap)

        // Selection overlay lives inside `contentView` so it scrolls
        // along with the selected node.
        contentView.addSubview(overlay)
        overlay.isHidden = true
        overlay.frame = .zero

        for handle in [overlay.topLeft, overlay.topRight, overlay.bottomLeft, overlay.bottomRight] {
            handle.referenceView = contentView
            handle.onPan = { [weak self] state, translation in
                self?.handleResize(corner: handle.corner, state: state, translation: translation)
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

        backgroundColor = uiColor(hex: document.pageBackgroundHex)

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
                cachedBackgroundOriginal = nil
                backgroundImageView.image = nil
                backgroundImageView.isHidden = true
            }
            lastBackgroundSignature = (path, mtime, blur, vignette)
        }
        sendSubviewToBack(backgroundImageView)

        // Walk the live tree, ensuring each node has a render view in the
        // right superview, then prune any cached views whose IDs are gone.
        // Root children now live inside `contentView` (the scroll view's
        // content) so the page can grow vertically and the user can
        // scroll down to nodes positioned past the viewport.
        var liveIDs: Set<UUID> = []

        for childID in document.rootChildrenIDs {
            applyNode(id: childID, parent: contentView, liveIDs: &liveIDs)
        }

        // Prune orphans (deleted nodes).
        for (id, view) in renderViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            renderViews.removeValue(forKey: id)
            nodePanGestures.removeValue(forKey: id)
        }

        // Apply z-order: subviews must be ordered to match `childrenIDs`.
        applyZOrder(parentID: nil, in: contentView)
        for (id, view) in renderViews where document.nodes[id]?.type == .container {
            applyZOrder(parentID: id, in: view)
        }

        // Selection overlay tracks the selected node, regardless of nesting.
        contentView.bringSubviewToFront(overlay)
        if let selectedID, let node = renderViews[selectedID] {
            overlay.isHidden = false
            overlay.frame = contentView.convert(node.bounds, from: node)
        } else {
            overlay.isHidden = true
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
            let fresh = makeRenderView(for: node)
            renderViews[id] = fresh
            view = fresh
            attachPanGesture(to: view)
        }

        if view.superview !== parent {
            view.removeFromSuperview()
            parent.addSubview(view)
        }
        view.apply(node: node)

        // Recurse for containers.
        if node.type == .container {
            for childID in node.childrenIDs {
                applyNode(id: childID, parent: view, liveIDs: &liveIDs)
            }
        }
    }

    private func expectedType(for node: CanvasNode) -> NodeRenderView.Type {
        switch node.type {
        case .container: return ContainerNodeView.self
        case .text: return TextNodeView.self
        case .image: return ImageNodeView.self
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
        }
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
        if container === contentView {
            contentView.bringSubviewToFront(overlay)
        }
    }

    // MARK: - Gestures: select / deselect

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
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
        return hitTestNode(at: point, in: contentView, parent: nil)
    }

    private func hitTestNode(at point: CGPoint, in superview: UIView, parent: UUID?) -> UUID? {
        let order = document.children(of: parent)
        for id in order.reversed() {
            guard let view = renderViews[id] else { continue }
            let local = superview.convert(point, to: view)
            if view.bounds.contains(local) {
                if document.nodes[id]?.type == .container,
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
            if view.superview === contentView {
                growContentHeightIfNeeded(toContain: newFrame.maxY)
            }
            applyOverlayForCurrentSelection()

        case .ended, .cancelled:
            // Commit the new frame to the document and notify the host.
            if var node = document.nodes[id] {
                node.frame = NodeFrame(view.frame)
                document.nodes[id] = node
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
            if view.superview === contentView {
                growContentHeightIfNeeded(toContain: newFrame.maxY)
            }
            applyOverlayForCurrentSelection()

        case .ended, .cancelled:
            if var node = document.nodes[id] {
                node.frame = NodeFrame(view.frame)
                document.nodes[id] = node
                onCommit?(document)
            }

        default:
            break
        }
    }

    // MARK: - Background image cache + async filter

    /// Returns the original (pre-filter) `UIImage` for `path`, decoding
    /// from disk only on a path-or-mtime change. Subsequent calls for
    /// the same path *and* unchanged mtime hit the cache, which is the
    /// difference between butter-smooth slider scrubbing and stuttering.
    /// Including `mtime` lets a same-path replace bust the cache.
    private func cachedOrLoadBackgroundOriginal(path: String, mtime: Date?) -> UIImage? {
        if let cached = cachedBackgroundOriginal,
           cached.path == path,
           cached.mtime == mtime {
            return cached.image
        }
        guard let image = LocalCanvasAssetStore.loadUIImage(path) else {
            cachedBackgroundOriginal = nil
            return nil
        }
        cachedBackgroundOriginal = (path, mtime, image)
        return image
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
        // Re-pin the overlay to the selected node in case bounds changed
        // (e.g., rotation or window resize on iPad).
        applyOverlayForCurrentSelection()
        // Keep the scrollable content tall enough for both the page
        // contents and the (possibly new) viewport height.
        updateContentHeight()
    }

    /// Resize `contentView` to fit either the viewport or the
    /// bottommost root node + a small padding, whichever is taller.
    /// Called after every `apply(...)`, every layout pass, and every
    /// drag/resize that mutates a frame, so the scrollable area
    /// always tracks where the user has placed nodes.
    private func updateContentHeight() {
        let viewport = scrollView.bounds.height
        var maxY: CGFloat = 0
        for childID in document.rootChildrenIDs {
            if let node = document.nodes[childID] {
                maxY = max(maxY, CGFloat(node.frame.y + node.frame.height))
            }
        }
        let bottomPadding: CGFloat = 60
        let target = max(viewport, maxY + bottomPadding)
        if let constraint = contentHeightConstraint,
           abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
        }
    }

    /// Expand `contentView` *during* a drag / resize so the user can
    /// keep moving a node past the previous bottom of the page
    /// without it getting clipped. Used by `handleNodePan` and
    /// `handleResize` `.changed` paths to grow the scrollable area
    /// live.
    private func growContentHeightIfNeeded(toContain frameMaxY: CGFloat) {
        let needed = frameMaxY + 60
        if let constraint = contentHeightConstraint, constraint.constant < needed {
            constraint.constant = needed
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
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let view = pan.view as? NodeRenderView else {
            return true
        }
        let viewID = view.nodeID
        let touchPoint = pan.location(in: view)

        if let selID = selectedID {
            if selID == viewID {
                // Rule 1: this view IS the selected node — always allow.
                return true
            }
            if isAncestor(selID, of: viewID) {
                // Rule 2: the user explicitly selected an ancestor of
                // this view. The ancestor's own pan should win.
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
