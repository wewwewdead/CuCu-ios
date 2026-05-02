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

private final class AddPageAffordanceView: UIControl {
    private let dashedBorder = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.8)
        layer.cornerRadius = 14
        layer.masksToBounds = true

        dashedBorder.strokeColor = UIColor.separator.cgColor
        dashedBorder.fillColor = UIColor.clear.cgColor
        dashedBorder.lineDashPattern = [6, 5]
        dashedBorder.lineWidth = 1
        layer.addSublayer(dashedBorder)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "+ Add page"
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .secondaryLabel
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedBorder.frame = bounds
        dashedBorder.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: 14
        ).cgPath
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
/// Host view for `CanvasEditorView`'s background pattern overlay.
/// Owns whatever `CAGradientLayer` is currently painting a wash and
/// keeps it sized to its bounds across page resizes — `CALayer.autoresizingMask`
/// is macOS-only, so the equivalent on iOS is a tiny layoutSubviews
/// override that walks the sublayers.
private final class BackgroundPatternHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers where sublayer is CAGradientLayer {
            // `actions = nil` (set on the layer when it's authored)
            // would be the cleaner suppression of implicit animation,
            // but the gradients we paint are static so a `disableActions`
            // transaction here keeps the resize from cross-fading.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sublayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Editorial page-identifier tag pinned to the top-left corner of
/// every page. Two-tier composition:
/// - mono uppercase "PAGE" caption (Lexend SemiBold, tracked)
/// - cherry hairline rule
/// - Fraunces italic numeral
///
/// Replaces the old systemMaterial blur bar — the blur read as iOS
/// settings chrome, not the editorial-scrapbook tone the rest of the
/// editor uses. Focus state flips fill/stroke to ink so the active
/// page reads with the same "selected" cue as the inspector
/// header's `Editing · n3` tile.
private final class PageIdentifierTagView: UIView {
    private let captionLabel = UILabel()
    private let numeralLabel = UILabel()
    private let ruleView = UIView()

    private(set) var isFocusedPage: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .cucuPaper
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.cucuInkRule.cgColor
        layer.shadowColor = UIColor.cucuInk.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.text = "PAGE"
        captionLabel.font = .monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        captionLabel.textColor = .cucuInkFaded
        captionLabel.textAlignment = .center
        captionLabel.attributedText = NSAttributedString(
            string: "PAGE",
            attributes: [.kern: 1.6,
                         .font: UIFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold),
                         .foregroundColor: UIColor.cucuInkFaded]
        )

        ruleView.translatesAutoresizingMaskIntoConstraints = false
        ruleView.backgroundColor = .cucuCherry

        numeralLabel.translatesAutoresizingMaskIntoConstraints = false
        // Fraunces italic — the editorial face introduced in Phase 1.
        // Falls back to system italic if registration somehow fails;
        // the page tag reading as "italic page number" is the load-
        // bearing visual, the specific face is the polish.
        numeralLabel.font = UIFont(name: "Fraunces-BoldItalic", size: 26)
            ?? .italicSystemFont(ofSize: 26)
        numeralLabel.textColor = .cucuInk
        numeralLabel.textAlignment = .center

        addSubview(captionLabel)
        addSubview(ruleView)
        addSubview(numeralLabel)

        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            ruleView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 4),
            ruleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            ruleView.widthAnchor.constraint(equalToConstant: 26),
            ruleView.heightAnchor.constraint(equalToConstant: 1.4),

            numeralLabel.topAnchor.constraint(equalTo: ruleView.bottomAnchor, constant: 1),
            numeralLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numeralLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func setNumber(_ number: Int) {
        numeralLabel.text = String(number)
    }

    /// Flips the tag between the "active page" and "background page"
    /// states. Active uses ink fill / paper text — the same inversion
    /// pattern the inspector header uses for the editing-target tile.
    /// Background uses paper fill / ink text. Cherry rule stays cherry
    /// in both — it's the constant accent of the editorial system.
    func setFocused(_ focused: Bool, animated: Bool) {
        guard focused != isFocusedPage else { return }
        isFocusedPage = focused
        let apply = { [self] in
            backgroundColor = focused ? .cucuInk : .cucuPaper
            layer.borderColor = (focused ? UIColor.cucuInk : UIColor.cucuInkRule).cgColor
            layer.shadowOpacity = focused ? 0.22 : 0.10
            numeralLabel.textColor = focused ? .cucuPaper : .cucuInk
            captionLabel.attributedText = NSAttributedString(
                string: "PAGE",
                attributes: [
                    .kern: 1.6,
                    .font: UIFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold),
                    .foregroundColor: focused
                        ? UIColor.cucuPaper.withAlphaComponent(0.7)
                        : UIColor.cucuInkFaded,
                ]
            )
            transform = focused
                ? CGAffineTransform(scaleX: 1.06, y: 1.06)
                : .identity
        }
        if animated {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: apply
            )
        } else {
            apply()
        }
    }
}

private extension UIColor {
    /// Re-stated rule colour that reads as ink at 12% — same value
    /// `Color.cucuInkRule` uses on the SwiftUI side. Kept private to
    /// the file because no other UIKit consumer needs it yet.
    static let cucuInkRule = UIColor.black.withAlphaComponent(0.12)
}

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

    private let overlay = SelectionOverlayView()
    private let editModeOverlay = CanvasEditModeOverlay()

    /// Toggle that flips the canvas into "edit mode" — every top-level
    /// node grows a dashed accent outline and a labelled chip floats
    /// above it so a user can hop straight into the inspector for any
    /// element. Off by default; the SwiftUI host owns the bound state
    /// and routes Esc-key + Done-button changes through `setEditMode`.
    private(set) var editMode: Bool = false

    /// Public mutator that drives `editMode` and re-runs the overlay
    /// reconciliation. Pulled out as its own method so the SwiftUI
    /// representable can flip it without re-applying the whole document
    /// — `apply(document:selectedID:)` would do too much work for a
    /// pure mode flip on dense canvases.
    func setEditMode(_ flag: Bool) {
        guard editMode != flag else { return }
        editMode = flag
        // While editing, the canvas-wide selection overlay is purely a
        // distraction — the dashed per-node outlines are doing that
        // job. Hide it while edit mode is on; the regular `apply` path
        // brings it back when edit mode ends.
        if flag {
            overlay.isHidden = true
        }
        applyEditModeOverlays()
        // Drag gestures on top-level nodes don't make sense while the
        // user is in "tap a chip to edit" mode — flatten interaction
        // so the empty-canvas tap fires and chips get clean hit slots.
        applyNodeInteractionForEditMode()
    }

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

    private let pagesStackView: UIStackView = {
        let v = UIStackView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 40
        return v
    }()

    private struct PageSurface {
        let pageID: UUID
        let shadowView: UIView
        /// Editorial page-number tag pinned to the top-left of the
        /// page. Owns its own caption / rule / numeral; the
        /// surrounding host only flips its focused state.
        let pageTagView: PageIdentifierTagView
        /// Container for `pageTagView` + `deleteButton`. Lives on the
        /// shadowView so the page-number tag floats above the
        /// page-edge stroke without clipping. Toggled to alpha 0
        /// during published-viewer preview.
        let chromeView: UIView
        let deleteButton: UIButton
        let pageView: UIView
        let backgroundImageView: UIImageView
        /// Tiled pattern overlay. Empty by default; either gets a
        /// `UIColor(patternImage:)` background for tile patterns or
        /// hosts a gradient layer for the wash patterns. Sits above
        /// `backgroundImageView` and below the paper grain.
        let backgroundPatternView: UIView
        /// Gradient sublayer hosted inside `backgroundPatternView`
        /// when a wash pattern (sunset / meadow / hazyDusk) is
        /// selected. Removed when the active pattern flips back to
        /// a tile pattern or `nil`.
        let backgroundPatternGradientLayer: CAGradientLayer
        /// Always-on noise overlay. Reads as newsprint texture on
        /// top of whatever the bg color / pattern produced.
        let paperGrainView: UIImageView
        /// Automatic, subtle top shading for user-customized page
        /// backgrounds. Render-only: derived from page bg state so it
        /// needs no document migration and publishes through the same
        /// renderer path as the editor.
        let topGradientView: UIView
        let topGradientLayer: CAGradientLayer
        let topGradientHeightConstraint: NSLayoutConstraint
        let widthConstraint: NSLayoutConstraint
        let heightConstraint: NSLayoutConstraint
    }

    private var pageSurfaces: [UUID: PageSurface] = [:]
    private var orderedPageIDs: [UUID] = []
    private let addPageAffordance = AddPageAffordanceView()
    private var addPageWidthConstraint: NSLayoutConstraint?
    private var addPageHeightConstraint: NSLayoutConstraint?

    private var contentWidthConstraint: NSLayoutConstraint?
    /// Drives `contentView.height`. Updated by `updateContentHeight()`
    /// based on page height and viewport height.
    private var contentHeightConstraint: NSLayoutConstraint?
    private var pagesStackTopConstraint: NSLayoutConstraint?

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
    private var backgroundRenderVersions: [UUID: Int] = [:]

    /// Signature of the last document state we actually applied. Lets us
    /// skip whole `apply(...)` passes when nothing background-relevant
    /// changed (e.g., a node mutation that doesn't touch the page).
    /// Includes `mtime` so an in-place file replace counts as a change.
    private var lastBackgroundSignatures: [UUID: (path: String?, mtime: Date?, blur: Double, vignette: Double)] = [:]

    /// Snapshot taken at the start of a drag/resize, so each `.changed` event
    /// can compute an absolute-from-translation frame instead of accumulating
    /// translation deltas (UIPanGestureRecognizer reports cumulative
    /// translation since `.began` by default).
    private var dragStartFrame: CGRect = .zero
    /// Drag-only snapshots taken at `.began`, captured separately
    /// from `dragStartFrame` because the move path uses
    /// `view.center` + `view.bounds.size` (both transform-safe)
    /// instead of `view.frame` (which is "undefined" per Apple's
    /// docs when `transform` is non-identity — a tilted element's
    /// `view.frame` returns the *bounding box* of the rotated
    /// view, which would grow the un-rotated logical size every
    /// drag tick if used to drive the move).
    private var dragStartCenter: CGPoint = .zero
    private var dragStartSize: CGSize = .zero
    /// Snapshot of every descendant's frame at the start of a resize.
    /// Used to scale children proportionally as the resized node's
    /// bounds change — without this, resizing a container leaves its
    /// children at fixed local positions and they get clipped /
    /// stranded as the parent grows or shrinks. Cleared on gesture
    /// end. Empty for resizes on leaf nodes (text, image, etc.).
    private var dragStartDescendantFrames: [UUID: CGRect] = [:]
    /// Vertical gap between the canvas top and the first page. Was
    /// 56pt to leave room for a card-style "page card on a tray" look,
    /// but the editor now paints the page edge-to-edge so the page
    /// can sit flush under the toolbar — matching the published
    /// view (where this padding has always been 0).
    private let pageTopPadding: CGFloat = 0
    private let pageBottomPadding: CGFloat = 48
    private let addPageHeight: CGFloat = 64
    private var lastReportedEditingPageIndex: Int = 0
    private var appliedPageCount = ProfileDocument.blank.pages.count
    /// False until the first `apply(document:)` pass lands. Gates the
    /// "user appended a new page → auto-scroll to it" behaviour so
    /// cold launches of multi-page drafts open at page 1 instead of
    /// jumping to the last page (the load looks like "new pages
    /// appeared since the blank baseline" without this flag).
    private var hasAppliedFirstDocument = false
    /// True until the first valid layout pass scrolls page 1 into
    /// view. The scroll has to run after `scrollView.bounds` is sized
    /// — calling `scrollToPage` from inside `apply(document:)` on a
    /// cold launch hits a 0×0 scroll view and the offset assignment
    /// is silently clamped / overwritten. Honored in `layoutSubviews`
    /// once dimensions are real, then cleared.
    private var pendingInitialScrollToTop = false

    // MARK: - SwiftUI bridges

    /// Called when the user taps a node (or empty canvas to deselect).
    var onSelectionChanged: ((UUID?) -> Void)?

    /// Called whenever the model is mutated by a user gesture and the
    /// gesture has ended (drag-end, resize-end). The caller persists.
    var onCommit: ((ProfileDocument) -> Void)?

    /// Editor-only affordance below the last page.
    var onAddPage: (() -> Void)?

    /// Editor-only page chrome delete request. The SwiftUI host owns the
    /// confirmation alert and actual mutation.
    var onDeletePageRequested: ((Int) -> Void)?

    /// Reports the page whose settings should be edited. Selection wins;
    /// otherwise the topmost visible page in the scroll viewport wins.
    var onEditingPageChanged: ((Int) -> Void)?

    /// When `false`, the canvas runs as a **read-only viewer**:
    /// - No pan recognizers are attached to nodes.
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

    /// Non-nil in the public viewer: render only that page so off-screen
    /// page backgrounds and node images are not mounted or fetched.
    var viewerPageIndex: Int?


    // MARK: - Init

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        // Edge-to-edge backdrop matches the editorial paper tone, so
        // the few pixels of canvas visible past the page edges (or
        // when the user scrolls past the page bottom) read as
        // continuous paper margin instead of iOS settings grey.
        backgroundColor = .cucuPaper

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
        // Edge-to-edge: contentView tracks the scroll view's visible
        // frame width, not a fixed page-size constant. Pages inside
        // the stack stretch to this width via their own constraint
        // (see `makePageSurface`), so the page paints flush with the
        // canvas — no horizontal gutter, regardless of which iPhone
        // model the user is on. The document's `pageWidth` stays the
        // canonical model field; children still address coordinates
        // in that logical space, accepting a few-point trailing gap
        // on Plus / Max devices in exchange for keeping the
        // persisted document portable across screen widths.
        let w = contentView.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor
        )
        w.priority = .required
        w.isActive = true
        contentWidthConstraint = w
        let h = contentView.heightAnchor.constraint(equalToConstant: 0)
        h.priority = .required
        h.isActive = true
        contentHeightConstraint = h

        contentView.addSubview(pagesStackView)
        let stackTop = pagesStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: pageTopPadding)
        pagesStackTopConstraint = stackTop
        NSLayoutConstraint.activate([
            stackTop,
            pagesStackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])

        addPageAffordance.addTarget(self, action: #selector(handleAddPageTapped), for: .touchUpInside)
        addPageWidthConstraint = addPageAffordance.widthAnchor.constraint(equalToConstant: ProfileDocument.defaultPageWidth)
        addPageHeightConstraint = addPageAffordance.heightAnchor.constraint(equalToConstant: addPageHeight)
        NSLayoutConstraint.activate([
            addPageWidthConstraint!,
            addPageHeightConstraint!
        ])

        // Tap recognizer on `contentView` so `gesture.location(in:)`
        // is already in content coordinates (not viewport).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        contentView.addGestureRecognizer(tap)
        scrollView.delegate = self

        // Selection overlay lives inside `contentView` so it scrolls
        // along with the selected node while drawing above the page's clipping.
        contentView.addSubview(overlay)
        overlay.isHidden = true
        overlay.frame = .zero

        for handle in overlay.handles {
            handle.referenceView = contentView
            let corner = handle.corner
            handle.onPan = { [weak self] state, translation in
                self?.handleResize(corner: corner, state: state, translation: translation)
            }
        }

        // Edit-mode chip taps land here — we route them through the
        // same selection callback the in-place tap recognizer uses so
        // the SwiftUI host's inspector path is identical.
        editModeOverlay.onSelectChip = { [weak self] id in
            guard let self else { return }
            // Defensive: fallthrough only when the id still belongs to a
            // live node. The reconciler in `apply` already prunes dead
            // chips, but the chip's tap handler is async w.r.t. document
            // mutation so it could fire on a node deleted milliseconds
            // earlier (rare, but free to guard).
            guard self.document.nodes[id] != nil else { return }
            self.endActiveTextEditingIfNeeded(except: id)
            self.selectedID = id
            self.onSelectionChanged?(id)
            self.updateEditingPageForCurrentState()
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
        #if DEBUG
        print("CanvasEditorView deinit")
        #endif
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

        // While a text node is actively editing, the SwiftUI parent's
        // copy of `content.text` lags behind UITextView (typing fires
        // `onTextChanged` into our internal document only — we don't
        // commit upstream on every keystroke). If the parent now pushes
        // a doc back through this method (e.g. the user toggled a
        // formatting control on the bottom panel mid-edit), accepting
        // it verbatim would clobber the in-flight string. Snapshot the
        // live UITextView text into the incoming document for the
        // editing node so style mutations land without losing keystrokes.
        var incomingDocument = document
        if let editingID = editingTextNodeID,
           editingID == selectedID,
           let textView = renderViews[editingID] as? TextNodeView,
           textView.isEditing,
           var editingNode = incomingDocument.nodes[editingID] {
            editingNode.content.text = textView.liveText
            incomingDocument.nodes[editingID] = editingNode
        }

        self.document = incomingDocument
        self.selectedID = selectedID
        // Only auto-scroll to a new page when one was just appended
        // *during this session*. On first apply (cold launch) the
        // load looks like "pages appeared past the blank baseline"
        // — that's not an append, that's the existing draft. Open
        // at page 1 instead.
        let shouldFocusNewPage = viewerPageIndex == nil
            && hasAppliedFirstDocument
            && document.pages.count > appliedPageCount

        backgroundColor = .cucuPaper
        let pageIndices = visiblePageIndices(for: document)
        reconcilePageSurfaces(for: pageIndices, in: document)
        applyPageSizing(for: document)

        // Walk the live tree, ensuring each node has a render view in the
        // right superview, then prune any cached views whose IDs are gone.
        // Root children live inside their page's bounded surface. Nested
        // children live inside container node views.
        var liveIDs: Set<UUID> = []

        for pageIndex in pageIndices {
            let page = document.pages[pageIndex]
            guard let surface = pageSurfaces[page.id] else { continue }
            applyPageBackground(page, surface: surface)
            for childID in page.rootChildrenIDs {
                applyNode(id: childID, parent: surface.pageView, liveIDs: &liveIDs)
            }
        }

        // Prune orphans (deleted nodes).
        for (id, view) in renderViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            renderViews.removeValue(forKey: id)
            appliedNodeSignatures.removeValue(forKey: id)
            nodePanGestures.removeValue(forKey: id)
        }

        // Apply z-order: subviews must be ordered to match `childrenIDs`.
        // Wrapped in a CATransaction with implicit actions disabled so
        // every `bringSubviewToFront` / `sendSubviewToBack` inside this
        // block coalesces into a single layout pass — on dense canvases
        // each individual call would otherwise schedule its own
        // `setNeedsLayout` and the layout invalidation count exploded.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pageIndex in pageIndices {
            let page = document.pages[pageIndex]
            if let surface = pageSurfaces[page.id] {
                applyZOrder(parentID: nil, in: surface.pageView, onPage: pageIndex)
                surface.pageView.sendSubviewToBack(surface.backgroundImageView)
            }
        }
        for (id, view) in renderViews {
            guard let nodeType = document.nodes[id]?.type else { continue }
            // Carousel keeps its dedicated host-view ordering; every
            // other node orders children directly on its own view so
            // leaf parents (image, icon, divider, link, gallery) layer
            // their nested badges/accents like containers do.
            if nodeType == .carousel, let carousel = view as? CarouselNodeView {
                applyZOrder(parentID: id, in: carousel.itemHostView, onPage: nil)
                carousel.updateContentSizeToFitItems()
            } else {
                applyZOrder(parentID: id, in: view, onPage: nil)
            }
        }

        // Selection overlay tracks the selected node, regardless of nesting.
        contentView.bringSubviewToFront(overlay)
        CATransaction.commit()
        if let selectedID, let node = renderViews[selectedID], editMode {
            // Resize handles are an editing affordance — only relevant
            // while edit mode is on. In live mode the bottom panel is
            // the sole selection indicator; the canvas itself stays
            // chrome-free so the user can't accidentally resize or
            // drag a node without explicitly entering edit mode.
            overlay.isHidden = false
            overlay.resizeMode = selectionOverlayResizeMode(for: selectedID)
            overlay.frame = contentView.convert(node.bounds, from: node)
        } else {
            overlay.isHidden = true
        }

        // Edit-mode chrome reconciles after node layout so chip + dashed
        // outline frames sit in front of the just-positioned node UIViews.
        applyEditModeOverlays()
        applyNodeInteractionForEditMode()

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

        updateContentHeight()
        if shouldFocusNewPage {
            layoutIfNeeded()
            scrollToPage(at: document.pages.count - 1, animated: true)
        } else {
            updateEditingPageForCurrentState()
            // First apply: defer the "open at page 1" snap to the
            // next valid layout pass. Calling `scrollToPage` here
            // is too early on a cold launch — `scrollView.bounds`
            // is still 0×0 so the offset assignment lands, then
            // gets clobbered when the actual layout runs and the
            // scroll view re-anchors at top automatically (which
            // is *not* page 1 once content has scrolled to the
            // restored 2nd-page position from a prior session).
            if !hasAppliedFirstDocument, viewerPageIndex == nil {
                pendingInitialScrollToTop = true
                setNeedsLayout()
            }
        }
        appliedPageCount = document.pages.count
        hasAppliedFirstDocument = true
    }

    private func visiblePageIndices(for document: ProfileDocument) -> [Int] {
        guard !document.pages.isEmpty else { return [] }
        if let viewerPageIndex {
            guard document.pages.indices.contains(viewerPageIndex) else { return [] }
            return [viewerPageIndex]
        }
        return Array(document.pages.indices)
    }

    private func reconcilePageSurfaces(for pageIndices: [Int], in document: ProfileDocument) {
        let requiredIDs = pageIndices.map { document.pages[$0].id }
        for pageID in orderedPageIDs where !requiredIDs.contains(pageID) {
            if let surface = pageSurfaces.removeValue(forKey: pageID) {
                pagesStackView.removeArrangedSubview(surface.shadowView)
                surface.shadowView.removeFromSuperview()
                lastBackgroundSignatures.removeValue(forKey: pageID)
                backgroundRenderVersions.removeValue(forKey: pageID)
            }
        }

        orderedPageIDs = []
        for (stackIndex, pageIndex) in pageIndices.enumerated() {
            let page = document.pages[pageIndex]
            let surface = pageSurfaces[page.id] ?? makePageSurface(for: page)
            pageSurfaces[page.id] = surface
            updatePageChrome(pageIndex: pageIndex, surface: surface)
            orderedPageIDs.append(page.id)
            if surface.shadowView.superview !== pagesStackView {
                pagesStackView.insertArrangedSubview(surface.shadowView, at: min(stackIndex, pagesStackView.arrangedSubviews.count))
            }
            if let currentIndex = pagesStackView.arrangedSubviews.firstIndex(of: surface.shadowView),
               currentIndex != stackIndex {
                pagesStackView.removeArrangedSubview(surface.shadowView)
                pagesStackView.insertArrangedSubview(surface.shadowView, at: stackIndex)
            }
        }

        let shouldShowAddPage = viewerPageIndex == nil && isInteractive
        if shouldShowAddPage {
            if addPageAffordance.superview !== pagesStackView {
                pagesStackView.addArrangedSubview(addPageAffordance)
            } else if pagesStackView.arrangedSubviews.last !== addPageAffordance {
                pagesStackView.removeArrangedSubview(addPageAffordance)
                pagesStackView.addArrangedSubview(addPageAffordance)
            }
        } else if addPageAffordance.superview === pagesStackView {
            pagesStackView.removeArrangedSubview(addPageAffordance)
            addPageAffordance.removeFromSuperview()
        }
    }

    private func makePageSurface(for page: PageStyle) -> PageSurface {
        let shadowView = UIView()
        shadowView.translatesAutoresizingMaskIntoConstraints = false
        shadowView.backgroundColor = .clear
        // Edge-to-edge: page sits flush against the canvas with no
        // lifted-card shadow. `updatePageChrome` keeps the shadow
        // properties at 0 too — the cherry-tinted focus shadow has
        // been retired in favour of the floating page-tag's
        // ink-fill flip as the focus indicator.
        shadowView.layer.shadowOpacity = 0

        // Chrome host — a transparent container that lives over the
        // page edge so the editorial tag and trash button float
        // without clipping. No blur, no fill; the visual chrome
        // belongs to the tag itself.
        let chromeView = UIView()
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.backgroundColor = .clear
        chromeView.alpha = 0

        // Page-number label suppressed per UX direction: the editor
        // canvas reads as a single uninterrupted page, no editorial
        // marginalia floating in the corner. The view stays in the
        // hierarchy (rather than being deleted from `PageSurface`
        // entirely) so the rest of the chrome plumbing — alpha
        // toggling for viewer mode, layout constraints, focus-state
        // setters — keeps working without a structural refactor.
        // Flip `isHidden = false` to bring the tag back.
        let pageTagView = PageIdentifierTagView()
        pageTagView.isHidden = true

        // Trash button — circular paper-fill / ink-stroke / cherry
        // glyph. System red read as iOS settings; cherry keeps the
        // delete affordance in the editorial palette without losing
        // its "this is destructive" valence.
        let deleteButton = UIButton(type: .system)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        let trashConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        deleteButton.setImage(
            UIImage(systemName: "trash", withConfiguration: trashConfig),
            for: .normal
        )
        deleteButton.tintColor = .cucuCherry
        deleteButton.backgroundColor = .cucuPaper
        deleteButton.layer.cornerRadius = 16
        deleteButton.layer.borderWidth = 1
        deleteButton.layer.borderColor = UIColor.cucuInk.cgColor
        deleteButton.layer.shadowColor = UIColor.cucuInk.cgColor
        deleteButton.layer.shadowOpacity = 0.10
        deleteButton.layer.shadowRadius = 4
        deleteButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        deleteButton.accessibilityLabel = "Delete Page"
        deleteButton.addTarget(self, action: #selector(handleDeletePageTapped(_:)), for: .touchUpInside)

        let pageView = UIView()
        pageView.translatesAutoresizingMaskIntoConstraints = false
        pageView.backgroundColor = uiColor(hex: page.backgroundHex)
        pageView.clipsToBounds = true
        // Edge-to-edge: no visible border / shadow on the page. Focus
        // is communicated through the floating page tag's ink-fill
        // flip in `updatePageChrome`, not by ringing the page itself.
        pageView.layer.borderColor = UIColor.clear.cgColor
        pageView.layer.borderWidth = 0

        let backgroundImageView = UIImageView()
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isUserInteractionEnabled = false
        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.isHidden = true

        // Pattern overlay container. Stays clear by default and gets
        // a tiled UIColor backgroundColor or a CAGradientLayer
        // sublayer once the user selects a `CanvasBackgroundPattern`.
        // Uses `BackgroundPatternHostView` so the gradient sublayer's
        // frame tracks the host's bounds without a manual relayout.
        let backgroundPatternView = BackgroundPatternHostView()
        backgroundPatternView.translatesAutoresizingMaskIntoConstraints = false
        backgroundPatternView.isUserInteractionEnabled = false
        backgroundPatternView.backgroundColor = .clear
        backgroundPatternView.clipsToBounds = true

        let backgroundPatternGradientLayer = CAGradientLayer()
        backgroundPatternGradientLayer.isHidden = true

        // Always-on paper grain. UIView's `pattern image` background
        // tiles a small noise UIImage edge-to-edge for free, then we
        // dim it with `alpha` rather than a multiply blend (UIKit
        // doesn't compose blends across siblings reliably; alpha on
        // a low-contrast tile reads close enough to the SVG version).
        let paperGrainView = UIImageView()
        paperGrainView.translatesAutoresizingMaskIntoConstraints = false
        paperGrainView.isUserInteractionEnabled = false
        paperGrainView.backgroundColor = UIColor(patternImage: CucuPaperGrain.uiTile)
        paperGrainView.alpha = 0.22

        // User-added page backgrounds get a quiet dark falloff at the
        // top. It sits above color/image/pattern and below content so
        // profile text stays readable without making the page feel
        // like it has a heavy overlay.
        let topGradientView = BackgroundPatternHostView()
        topGradientView.translatesAutoresizingMaskIntoConstraints = false
        topGradientView.isUserInteractionEnabled = false
        topGradientView.backgroundColor = .clear
        topGradientView.clipsToBounds = true
        topGradientView.isHidden = true

        let topGradientLayer = CAGradientLayer()
        topGradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        topGradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        topGradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.24).cgColor,
            UIColor.black.withAlphaComponent(0.10).cgColor,
            UIColor.black.withAlphaComponent(0.0).cgColor,
        ]
        topGradientLayer.locations = [0, 0.48, 1]
        topGradientLayer.isHidden = true
        topGradientLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull()
        ]

        shadowView.addSubview(pageView)
        pageView.addSubview(backgroundImageView)
        pageView.addSubview(backgroundPatternView)
        pageView.addSubview(paperGrainView)
        pageView.addSubview(topGradientView)
        shadowView.addSubview(chromeView)
        chromeView.addSubview(pageTagView)
        chromeView.addSubview(deleteButton)

        let width = shadowView.widthAnchor.constraint(equalToConstant: ProfileDocument.defaultPageWidth)
        let height = shadowView.heightAnchor.constraint(equalToConstant: ProfileDocument.defaultPageHeight)
        let topGradientHeight = topGradientView.heightAnchor.constraint(equalToConstant: 280)
        NSLayoutConstraint.activate([
            width,
            height,
            // Chrome stretches the full top of the shadowView so its
            // children (the tag at the leading edge, the trash at
            // the trailing edge) can use raw absolute positioning
            // without resorting to two separate floating subviews.
            chromeView.leadingAnchor.constraint(equalTo: shadowView.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: shadowView.trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: shadowView.topAnchor),
            chromeView.heightAnchor.constraint(equalToConstant: 64),

            // Page tag — slightly inset from the page edge so the
            // tag's own ink stroke doesn't visually merge with the
            // page border. Tag is square-ish (~58×56) so the
            // numeral has room to breathe in italic.
            pageTagView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor, constant: 10),
            pageTagView.topAnchor.constraint(equalTo: chromeView.topAnchor, constant: 10),
            pageTagView.widthAnchor.constraint(equalToConstant: 58),
            pageTagView.heightAnchor.constraint(equalToConstant: 56),

            deleteButton.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor, constant: -10),
            deleteButton.topAnchor.constraint(equalTo: chromeView.topAnchor, constant: 14),
            deleteButton.widthAnchor.constraint(equalToConstant: 32),
            deleteButton.heightAnchor.constraint(equalToConstant: 32),
            pageView.leadingAnchor.constraint(equalTo: shadowView.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: shadowView.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: shadowView.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: shadowView.bottomAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            backgroundImageView.topAnchor.constraint(equalTo: pageView.topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
            backgroundPatternView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            backgroundPatternView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            backgroundPatternView.topAnchor.constraint(equalTo: pageView.topAnchor),
            backgroundPatternView.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
            paperGrainView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            paperGrainView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            paperGrainView.topAnchor.constraint(equalTo: pageView.topAnchor),
            paperGrainView.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
            topGradientView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            topGradientView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            topGradientView.topAnchor.constraint(equalTo: pageView.topAnchor),
            topGradientHeight
        ])

        backgroundPatternView.layer.addSublayer(backgroundPatternGradientLayer)
        topGradientView.layer.addSublayer(topGradientLayer)

        return PageSurface(
            pageID: page.id,
            shadowView: shadowView,
            pageTagView: pageTagView,
            chromeView: chromeView,
            deleteButton: deleteButton,
            pageView: pageView,
            backgroundImageView: backgroundImageView,
            backgroundPatternView: backgroundPatternView,
            backgroundPatternGradientLayer: backgroundPatternGradientLayer,
            paperGrainView: paperGrainView,
            topGradientView: topGradientView,
            topGradientLayer: topGradientLayer,
            topGradientHeightConstraint: topGradientHeight,
            widthConstraint: width,
            heightConstraint: height
        )
    }

    private func updatePageChrome(pageIndex: Int, surface: PageSurface) {
        let isFocusedPage = pageIndex == focusedPageIndex()
        surface.pageTagView.setNumber(pageIndex + 1)
        surface.pageTagView.setFocused(isFocusedPage, animated: true)
        surface.deleteButton.tag = pageIndex
        surface.deleteButton.isHidden = !isInteractive || pageIndex == 0 || document.pages.count <= 1
        surface.chromeView.alpha = viewerPageIndex == nil ? 1 : 0

        // Edge-to-edge layout: page has no visible border or drop
        // shadow in either focused or unfocused state. The floating
        // page tag is the sole focus indicator (ink fill + scale on
        // active, paper fill + faded text on inactive — see
        // `PageIdentifierTagView.setFocused`).
        surface.pageView.layer.borderColor = UIColor.clear.cgColor
        surface.pageView.layer.borderWidth = 0
        surface.shadowView.layer.shadowOpacity = 0
    }

    private func focusedPageIndex() -> Int {
        if let selectedID, let pageIndex = document.pageContaining(selectedID) {
            return pageIndex
        }
        return min(lastReportedEditingPageIndex, max(0, document.pages.count - 1))
    }

    private func applyPageBackground(_ page: PageStyle, surface: PageSurface) {
        surface.pageView.backgroundColor = uiColor(hex: page.backgroundHex)
        let path = page.backgroundImagePath
        let blur = page.backgroundBlur ?? 0
        let vignette = page.backgroundVignette ?? 0
        let mtime = LocalCanvasAssetStore.modificationDate(path)
        let previous = lastBackgroundSignatures[page.id]

        let signatureChanged =
            previous?.path != path ||
            previous?.mtime != mtime ||
            previous?.blur != blur ||
            previous?.vignette != vignette

        if signatureChanged {
            if let path, !path.isEmpty,
               let original = cachedOrLoadBackgroundOriginal(path: path, mtime: mtime, pageID: page.id) {
                surface.backgroundImageView.isHidden = false
                if blur <= 0.01 && vignette <= 0.01 {
                    surface.backgroundImageView.image = original
                } else {
                    scheduleBackgroundFilterRender(
                        image: original,
                        blur: blur,
                        vignette: vignette,
                        pageID: page.id,
                        imageView: surface.backgroundImageView
                    )
                }
            } else {
                surface.backgroundImageView.image = nil
                surface.backgroundImageView.isHidden = true
            }
            lastBackgroundSignatures[page.id] = (path, mtime, blur, vignette)
        }

        // Image opacity. Cheap; reapplied every pass since it's not
        // part of the cached signature above.
        surface.backgroundImageView.alpha = CGFloat(page.backgroundImageOpacity ?? 1)

        // Pattern overlay. Tile patterns set a `UIColor(patternImage:)`
        // background; gradient washes use the cached `CAGradientLayer`.
        applyBackgroundPattern(page, surface: surface)
        applyAutomaticTopGradient(page, surface: surface)

        // Z-order: image (back) → pattern → top gradient → grain
        // (front, but below nodes). Nodes are added to `pageView`
        // later in the apply pass; sending these to the back keeps
        // them under whatever node stack lands here next.
        surface.pageView.sendSubviewToBack(surface.paperGrainView)
        surface.pageView.sendSubviewToBack(surface.topGradientView)
        surface.pageView.sendSubviewToBack(surface.backgroundPatternView)
        surface.pageView.sendSubviewToBack(surface.backgroundImageView)
    }

    private func applyAutomaticTopGradient(_ page: PageStyle, surface: PageSurface) {
        let showGradient = hasUserCustomizedBackground(page)
        surface.topGradientView.isHidden = !showGradient
        surface.topGradientLayer.isHidden = !showGradient

        let targetHeight = min(320, max(180, CGFloat(page.height) * 0.28))
        if abs(surface.topGradientHeightConstraint.constant - targetHeight) > 0.5 {
            surface.topGradientHeightConstraint.constant = targetHeight
            surface.topGradientView.setNeedsLayout()
        }
    }

    private func hasUserCustomizedBackground(_ page: PageStyle) -> Bool {
        let customColor = page.backgroundHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(ProfileDocument.defaultPageBackgroundHex) != .orderedSame
        let hasImage = !(page.backgroundImagePath?.isEmpty ?? true)
        return customColor || hasImage
    }

    private func applyBackgroundPattern(_ page: PageStyle, surface: PageSurface) {
        let pattern = CanvasBackgroundPattern(key: page.backgroundPatternKey)
        guard let pattern else {
            surface.backgroundPatternView.backgroundColor = .clear
            surface.backgroundPatternGradientLayer.isHidden = true
            return
        }
        if let tile = pattern.tileImage {
            surface.backgroundPatternView.backgroundColor = UIColor(patternImage: tile)
            surface.backgroundPatternGradientLayer.isHidden = true
        } else if let fresh = pattern.makeGradientLayer() {
            surface.backgroundPatternView.backgroundColor = .clear
            // Copy the freshly built layer's properties onto the
            // surface's persistent gradient layer rather than
            // swapping layers in/out — keeps the layer hierarchy
            // stable across pattern changes and avoids implicit
            // animations from re-adding sublayers.
            surface.backgroundPatternGradientLayer.colors = fresh.colors
            surface.backgroundPatternGradientLayer.locations = fresh.locations
            surface.backgroundPatternGradientLayer.startPoint = fresh.startPoint
            surface.backgroundPatternGradientLayer.endPoint = fresh.endPoint
            surface.backgroundPatternGradientLayer.type = fresh.type
            surface.backgroundPatternGradientLayer.frame = surface.backgroundPatternView.bounds
            surface.backgroundPatternGradientLayer.isHidden = false
        }
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

        // Recurse children for every node that can host them. Carousel
        // children mount into the strip's scroll content (so horizontal
        // scrolling moves them as a unit); every other node — including
        // leaves like image / icon / divider / link / gallery — hosts
        // its children directly so users can drop a badge icon on an
        // image, an accent on an icon, etc. Empty `childrenIDs` makes
        // the loop a no-op for nodes without nested children.
        if node.type == .carousel, let carousel = view as? CarouselNodeView {
            for childID in node.childrenIDs {
                applyNode(id: childID, parent: carousel.itemHostView, liveIDs: &liveIDs)
            }
            carousel.updateContentSizeToFitItems()
        } else {
            for childID in node.childrenIDs {
                applyNode(id: childID, parent: view, liveIDs: &liveIDs)
            }
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

    private func applyZOrder(parentID: UUID?, in container: UIView, onPage pageIndex: Int?) {
        let order: [UUID]
        if let pageIndex {
            order = document.children(of: parentID, onPage: pageIndex)
        } else {
            order = document.children(of: parentID)
        }
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
        if pageSurfaces.values.contains(where: { $0.pageView === container }) {
            contentView.bringSubviewToFront(overlay)
        }
    }

    // MARK: - Gestures: select / deselect

    @objc private func handleAddPageTapped() {
        onAddPage?()
    }

    @objc private func handleDeletePageTapped(_ sender: UIButton) {
        onDeletePageRequested?(sender.tag)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Viewer mode: nothing to select. The recognizer stays
        // attached because it lives on `contentView` (we don't need
        // to tear it down per render-view), but it short-circuits
        // here so empty taps don't push spurious `selectedID` updates
        // through to SwiftUI.
        guard isInteractive else { return }

        // Editing is gated on the user-facing Edit toggle. In live
        // mode the canvas reads as a published preview — tapping an
        // element never *opens* a new selection. But adding an
        // element auto-selects it (so the bottom inspector panel
        // appears for the freshly-added node), and the user expects
        // a tap-outside-the-panel to dismiss that selection. So in
        // live mode the rule is: any tap on the canvas clears the
        // current selection — closes the panel — and never opens a
        // new one.
        guard editMode else {
            if selectedID != nil {
                endActiveTextEditingIfNeeded(except: nil)
                selectedID = nil
                onSelectionChanged?(nil)
            }
            return
        }

        let point = gesture.location(in: contentView)
        let hit = hitTestNode(at: point)

        // Already-selected text node: a second tap drops directly into
        // in-place text editing (keyboard up, cursor in the box). This
        // is the only case where a node-body tap *acts* in edit mode
        // — the user has already chosen the text node via its chip,
        // so a follow-up tap on the body is a deliberate "edit text"
        // gesture, not a selection event.
        if let hit, hit == selectedID,
           document.nodes[hit]?.type == .text,
           let textView = renderViews[hit] as? TextNodeView,
           !textView.isEditing {
            editingTextNodeID = hit
            bringEditingNodeChainToFront(view: textView)
            textView.beginEditing()
            return
        }

        // Anywhere else — empty canvas, a node body that isn't the
        // currently-selected text node, or a nested element — closes
        // the inspector but keeps edit mode armed. Selection in edit
        // mode comes from chips, never from body taps, so there is no
        // "select on tap" branch here.
        if selectedID != nil {
            endActiveTextEditingIfNeeded(except: nil)
            selectedID = nil
            onSelectionChanged?(nil)
        }
    }

    private func focusPage(at pageIndex: Int) {
        guard document.pages.indices.contains(pageIndex) else { return }
        endActiveTextEditingIfNeeded(except: nil)
        if selectedID != nil {
            selectedID = nil
            onSelectionChanged?(nil)
        }
        overlay.isHidden = true
        lastReportedEditingPageIndex = pageIndex
        onEditingPageChanged?(pageIndex)
        updatePageChromeSelection()
    }

    private func updateEditingPageForCurrentState() {
        let resolvedIndex: Int
        if let selectedID, let pageIndex = document.pageContaining(selectedID) {
            resolvedIndex = pageIndex
        } else {
            resolvedIndex = topmostVisiblePageIndex()
        }
        guard resolvedIndex != lastReportedEditingPageIndex else { return }
        lastReportedEditingPageIndex = resolvedIndex
        onEditingPageChanged?(resolvedIndex)
        updatePageChromeSelection()
    }

    private func topmostVisiblePageIndex() -> Int {
        let visibleRect = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        for pageIndex in visiblePageIndices(for: document) {
            let page = document.pages[pageIndex]
            guard let surface = pageSurfaces[page.id] else { continue }
            let frame = contentView.convert(surface.shadowView.bounds, from: surface.shadowView)
            if frame.intersects(visibleRect) || frame.maxY >= visibleRect.minY {
                return pageIndex
            }
        }
        return min(lastReportedEditingPageIndex, max(0, document.pages.count - 1))
    }

    private func scrollToPage(at pageIndex: Int, animated: Bool) {
        guard document.pages.indices.contains(pageIndex),
              let surface = pageSurfaces[document.pages[pageIndex].id] else { return }
        let pageFrame = contentView.convert(surface.shadowView.bounds, from: surface.shadowView)
        let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let targetY = min(max(0, pageFrame.minY - 12), maxOffsetY)
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
        lastReportedEditingPageIndex = pageIndex
        onEditingPageChanged?(pageIndex)
        updatePageChromeSelection()
    }

    private func pageIndex(at point: CGPoint) -> Int? {
        for pageIndex in visiblePageIndices(for: document).reversed() {
            let page = document.pages[pageIndex]
            guard let surface = pageSurfaces[page.id] else { continue }
            let pagePoint = contentView.convert(point, to: surface.pageView)
            if surface.pageView.bounds.contains(pagePoint) {
                return pageIndex
            }
        }
        return nil
    }

    private func updatePageChromeSelection() {
        for pageIndex in visiblePageIndices(for: document) {
            let page = document.pages[pageIndex]
            guard let surface = pageSurfaces[page.id] else { continue }
            updatePageChrome(pageIndex: pageIndex, surface: surface)
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
        for pageIndex in visiblePageIndices(for: document).reversed() {
            let page = document.pages[pageIndex]
            guard let surface = pageSurfaces[page.id] else { continue }
            let pagePoint = contentView.convert(point, to: surface.pageView)
            guard surface.pageView.bounds.contains(pagePoint) else { continue }
            return hitTestNode(at: pagePoint, in: surface.pageView, parent: nil, onPage: pageIndex)
        }
        return nil
    }

    private func hitTestNode(at point: CGPoint, in superview: UIView, parent: UUID?, onPage pageIndex: Int) -> UUID? {
        let order = document.children(of: parent, onPage: pageIndex)
        for id in order.reversed() {
            guard let view = renderViews[id] else { continue }
            let local = superview.convert(point, to: view)
            if view.bounds.contains(local) {
                // Always try children first so a nested icon/text/etc.
                // wins over the leaf it sits on. Empty `childrenIDs`
                // makes the recursion return nil and we fall through
                // to returning `id` — same as before for true leaves.
                if let inner = hitTestNode(at: local, in: view, parent: id, onPage: pageIndex) {
                    return inner
                }
                return id
            }
        }
        return nil
    }

    private func applyOverlayForCurrentSelection() {
        if let selectedID, let node = renderViews[selectedID], editMode {
            // Mirrors the rule in `apply(...)`: the resize-handle
            // overlay only surfaces while edit mode is on. Live mode
            // never shows it, even after a fresh add — selection
            // visibility comes from the bottom inspector panel.
            overlay.isHidden = false
            overlay.resizeMode = selectionOverlayResizeMode(for: selectedID)
            overlay.frame = contentView.convert(node.bounds, from: node)
            contentView.bringSubviewToFront(overlay)
        } else {
            overlay.isHidden = true
        }
    }

    private func selectionOverlayResizeMode(for id: UUID) -> SelectionOverlayView.ResizeMode {
        switch StructuredProfileLayout.resizeBehavior(for: id, in: document) {
        case .locked:
            return .locked
        case .verticalOnly:
            return .verticalOnly
        case .freeform:
            return .freeform
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

    @objc private func handleNodePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view as? NodeRenderView else { return }
        let id = view.nodeID

        // Top-level non-system nodes are vertically reorderable. The
        // page root reads as a stacked list — drag a card up/down to
        // swap it with siblings, and `StructuredProfileLayout.normalize`
        // re-snaps everyone to their final y on commit.
        let isTopLevel = document.parent(of: id) == nil
        let isSystemOwned = document.nodes[id]?.role?.isSystemOwned == true
        if isTopLevel && !isSystemOwned {
            handleTopLevelReorderPan(gesture: gesture, view: view, id: id)
            return
        }

        // In structured-profile mode every nested node — image, text,
        // icon, link, anything inside a Section Card, and the hero's
        // own children — is position-locked. Position edits go
        // through the Layout tab of the inspector, not the canvas.
        // Legacy / freeform documents (no structured hero) keep the
        // original freeform drag so older drafts don't regress.
        if StructuredProfileLayout.isStructured(document) {
            return
        }

        guard StructuredProfileLayout.canMove(id, in: document) else { return }

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
            // Capture transform-safe snapshots: `center` for
            // position, `bounds.size` for the un-rotated logical
            // size. Both are well-defined regardless of any tilt
            // transform on the view; `view.frame` is not.
            dragStartCenter = view.center
            dragStartSize = view.bounds.size

        case .changed:
            // Move the dragged view by mutating its `center`
            // directly. `view.center` translates correctly even
            // when the view has a rotation transform, so a tilted
            // element drags by the same vector the user's finger
            // travels. Nested children follow because they're real
            // UIKit subviews and their frames live in this view's
            // (un-rotated) coord space — moving the parent's
            // center moves the whole subtree visually.
            // Document is untouched until `.ended` so SwiftUI
            // doesn't re-render mid-drag and stomp the in-flight
            // position.
            let translation = gesture.translation(in: view.superview)
            var newCenter = CGPoint(
                x: dragStartCenter.x + translation.x,
                y: dragStartCenter.y + translation.y
            )
            if shouldClampToParentBounds(id),
               let bounds = parentBoundsSize(for: id) {
                let proposed = CGRect(
                    x: newCenter.x - dragStartSize.width / 2,
                    y: newCenter.y - dragStartSize.height / 2,
                    width: dragStartSize.width,
                    height: dragStartSize.height
                )
                let clamped = clampFrameToParentBounds(proposed, parentSize: bounds)
                newCenter = CGPoint(x: clamped.midX, y: clamped.midY)
            }
            view.center = newCenter
            nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
            applyOverlayForCurrentSelection()

        case .ended, .cancelled:
            // Commit the new frame to the document and notify the
            // host. Build the model frame from the captured
            // un-rotated size + the dragged center so a tilted
            // element gets the right model position even though
            // its `view.frame` is undefined.
            if var node = document.nodes[id] {
                let size = dragStartSize
                var newFrame = CGRect(
                    x: view.center.x - size.width / 2,
                    y: view.center.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                if shouldClampToParentBounds(id),
                   let bounds = parentBoundsSize(for: id) {
                    newFrame = clampFrameToParentBounds(newFrame, parentSize: bounds)
                }
                node.frame = NodeFrame(newFrame)
                document.nodes[id] = node
                nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
                onCommit?(document)
            }

        default:
            break
        }
    }

    // MARK: - Gestures: top-level reorder

    /// Vertical drag-to-reorder for top-level non-system nodes. The
    /// node only translates on the Y axis during the drag (X stays
    /// pinned to its committed center), and on release we mutate the
    /// page's `rootChildrenIDs` to put the dragged node into the slot
    /// its final y position lands in. `onCommit` then runs the host's
    /// `StructuredProfileLayout.normalize` pass which re-snaps every
    /// sibling to its new auto-stacked y. Lift visuals (scale + alpha
    /// + shadow proxy via z-position) signal that the node is "in
    /// flight" and distinguish reorder from freeform drag.
    private func handleTopLevelReorderPan(gesture: UIPanGestureRecognizer,
                                          view: NodeRenderView,
                                          id: UUID) {
        switch gesture.state {
        case .began:
            if selectedID != id {
                endActiveTextEditingIfNeeded(except: id)
                selectedID = id
                onSelectionChanged?(id)
            }
            dragStartCenter = view.center
            dragStartSize = view.bounds.size
            // Lift purely via opacity + raised z-position — no scale
            // transform. A `transform != .identity` would force every
            // call site that touches `frame` to reach for the
            // bounds+center workaround, and it visually muddies the
            // Y-only intent (the view stretches at the same instant
            // it starts following the finger, which reads as
            // freeform). Plain alpha drop is enough to signal "in
            // flight" without that confusion.
            view.layer.zPosition = 100
            UIView.animate(withDuration: 0.18,
                           delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                view.alpha = 0.92
            }

        case .changed:
            // Y-only translation. `view.center.x` stays pinned to
            // the committed start so the user can't drag off-axis.
            let translation = gesture.translation(in: view.superview)
            view.center = CGPoint(
                x: dragStartCenter.x,
                y: dragStartCenter.y + translation.y
            )
            applyOverlayForCurrentSelection()

        case .ended, .cancelled:
            commitTopLevelReorder(id: id, finalCenterY: view.center.y)
            view.layer.zPosition = 0
            // Snap the dragged view back to its document frame
            // explicitly. When the drag triggered an actual reorder,
            // the render signature changed and the upstream `apply`
            // pass already restored the frame — but when the user
            // drags and releases without crossing a sibling's
            // midpoint (or there's only one movable sibling), the
            // signature is unchanged, `applyNode` skips `view.apply`,
            // and the view ends up frozen at its dragged position
            // while the dashed outlines and selection overlay snap
            // back to the document frame. Forcing the assignment
            // here keeps the canvas visually consistent regardless
            // of whether the order actually changed.
            if let node = document.nodes[id] {
                view.frame = node.frame.cgRect
                applyOverlayForCurrentSelection()
            }
            UIView.animate(withDuration: 0.22,
                           delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                view.alpha = 1.0
            }

        default:
            break
        }
    }

    /// Resolves the dragged node's final y to a new index in its
    /// page's `rootChildrenIDs`, mutates the document, and fires
    /// `onCommit`. System-owned siblings (hero, optional fixed
    /// divider) stay pinned to the front of the order — the dragged
    /// node can only move within the user-content range.
    private func commitTopLevelReorder(id: UUID, finalCenterY: CGFloat) {
        guard let pageIndex = document.pageContaining(id) else {
            onCommit?(document)
            return
        }
        var rootIDs = document.pages[pageIndex].rootChildrenIDs
        guard let oldIndex = rootIDs.firstIndex(of: id) else {
            onCommit?(document)
            return
        }
        rootIDs.remove(at: oldIndex)

        // System-owned nodes (the hero, plus any legacy fixed divider)
        // always lead the list. The dragged node lands somewhere among
        // the remaining movable siblings.
        var leadingPinned = 0
        for sibling in rootIDs {
            if document.nodes[sibling]?.role?.isSystemOwned == true {
                leadingPinned += 1
            } else {
                break
            }
        }

        var newIndex = leadingPinned
        for sibling in rootIDs.dropFirst(leadingPinned) {
            guard let frame = document.nodes[sibling]?.frame else {
                newIndex += 1
                continue
            }
            let siblingMid = frame.y + frame.height / 2
            if Double(finalCenterY) > siblingMid {
                newIndex += 1
            } else {
                break
            }
        }

        rootIDs.insert(id, at: newIndex)
        document.pages[pageIndex].rootChildrenIDs = rootIDs
        onCommit?(document)
    }

    // MARK: - Gestures: resize

    private func handleResize(corner: ResizeHandleView.Corner,
                              state: UIPanGestureRecognizer.State,
                              translation: CGPoint) {
        guard let id = selectedID,
              let view = renderViews[id] else { return }
        let resizeMode = StructuredProfileLayout.resizeBehavior(for: id, in: document)
        guard resizeMode != .locked else { return }

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
            if resizeMode == .freeform {
                for descendantID in document.subtree(rootedAt: id) where descendantID != id {
                    if let descendantView = renderViews[descendantID] {
                        dragStartDescendantFrames[descendantID] = descendantView.frame
                    }
                }
            }

        case .changed:
            // Translation arrives in canvas-root coords. With no transforms
            // in ancestors (Phase 1 invariant), this vector equals the
            // translation in the node's parent space.
            var newFrame = dragStartFrame
            if resizeMode == .verticalOnly {
                newFrame.size.height = max(
                    CGFloat(StructuredProfileLayout.cardMinimumHeight),
                    dragStartFrame.height + translation.y
                )
            } else {
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
                case .bottomCenter:
                    newFrame.size.height += translation.y
                }
            }

            // Aspect-lock when the node is in Circle mode so dragging a corner
            // keeps the shape a true circle (not a capsule). Pivot around the
            // corner opposite the one being dragged so the user feels the
            // resize anchor as fixed. Use the larger of the two requested
            // sizes — that matches Shift-resize behavior in Figma/Sketch and
            // avoids surprise shrink-to-zero when the user pulls outward.
            if resizeMode == .freeform && document.nodes[id]?.style.clipShape == .circle {
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
                case .bottomCenter:
                    newFrame.origin.x = dragStartFrame.minX
                    newFrame.origin.y = dragStartFrame.minY
                }
                newFrame.size.width = side
                newFrame.size.height = side
            }

            // Min size clamp: don't allow the frame to collapse past 24x24.
            let minimumHeight = resizeMode == .verticalOnly
                ? CGFloat(StructuredProfileLayout.cardMinimumHeight)
                : 24
            if resizeMode == .freeform && newFrame.size.width < 24 {
                if corner == .topLeft || corner == .bottomLeft {
                    newFrame.origin.x = dragStartFrame.maxX - 24
                }
                newFrame.size.width = 24
            }
            if newFrame.size.height < minimumHeight {
                if corner == .topLeft || corner == .topRight {
                    newFrame.origin.y = dragStartFrame.maxY - minimumHeight
                }
                newFrame.size.height = minimumHeight
            }
            if shouldClampToParentBounds(id),
               let bounds = parentBoundsSize(for: id) {
                newFrame = clampFrameToParentBounds(newFrame, parentSize: bounds)
            }
            view.frame = newFrame

            // Scale every descendant's UIView frame by the same
            // ratio as the resize. Pure visual update during the
            // gesture — the document is not mutated until `.ended`
            // so SwiftUI doesn't re-render mid-drag and stomp on
            // the in-flight frames.
            if resizeMode == .freeform {
                applyDescendantScale(
                    in: dragStartDescendantFrames,
                    scaleX: dragStartFrame.width > 0 ? newFrame.width / dragStartFrame.width : 1,
                    scaleY: dragStartFrame.height > 0 ? newFrame.height / dragStartFrame.height : 1
                )
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
                var committedFrame = view.frame
                if shouldClampToParentBounds(id),
                   let bounds = parentBoundsSize(for: id) {
                    committedFrame = clampFrameToParentBounds(committedFrame, parentSize: bounds)
                }
                node.frame = NodeFrame(committedFrame)
                document.nodes[id] = node
            }
            if resizeMode == .freeform {
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
            }
            dragStartDescendantFrames.removeAll()

            if document.nodes[id] != nil {
                StructuredProfileLayout.normalize(&document)
                nearestCarouselAncestor(of: view)?.updateContentSizeToFitItems()
                onCommit?(document)
            }

        default:
            break
        }
    }

    private func shouldClampToParentBounds(_ id: UUID) -> Bool {
        guard let node = document.nodes[id],
              node.role != .sectionCard,
              let parentID = document.parent(of: id),
              let parent = document.nodes[parentID] else { return false }
        if parent.type == .carousel { return false }
        if parent.role == .sectionCard { return true }
        return parent.type == .container &&
            StructuredProfileLayout.sectionCardAncestor(containing: parentID, in: document) != nil
    }

    private func parentBoundsSize(for id: UUID) -> CGSize? {
        guard let parentID = document.parent(of: id),
              let parent = document.nodes[parentID] else { return nil }
        return CGSize(width: parent.frame.width, height: parent.frame.height)
    }

    private func clampFrameToParentBounds(_ frame: CGRect, parentSize: CGSize) -> CGRect {
        var next = frame
        next.size.width = min(max(24, next.width), max(24, parentSize.width))
        next.size.height = min(max(24, next.height), max(24, parentSize.height))
        next.origin.x = min(max(0, next.origin.x), max(0, parentSize.width - next.width))
        next.origin.y = min(max(0, next.origin.y), max(0, parentSize.height - next.height))
        return next
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
    private func cachedOrLoadBackgroundOriginal(path: String, mtime: Date?, pageID: UUID) -> UIImage? {
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
                    guard self.document.pages.first(where: { $0.id == pageID })?.backgroundImagePath == path else { return }
                    self.applyFetchedPageBackground(image: fetched, path: path, mtime: mtime, pageID: pageID)
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
    private func applyFetchedPageBackground(image: UIImage, path: String, mtime: Date?, pageID: UUID) {
        backgroundImageCache.insert(path: path, mtime: mtime, image: image)

        guard let page = document.pages.first(where: { $0.id == pageID }),
              let surface = pageSurfaces[pageID] else { return }
        let blur = page.backgroundBlur ?? 0
        let vignette = page.backgroundVignette ?? 0
        surface.backgroundImageView.isHidden = false
        if blur <= 0.01 && vignette <= 0.01 {
            surface.backgroundImageView.image = image
        } else {
            scheduleBackgroundFilterRender(
                image: image,
                blur: blur,
                vignette: vignette,
                pageID: pageID,
                imageView: surface.backgroundImageView
            )
        }
        // Background sits behind every node view; keep that layering
        // intact since `apply(document:)` is the path that normally
        // calls `sendSubviewToBack` for us.
        surface.pageView.sendSubviewToBack(surface.backgroundImageView)
        lastBackgroundSignatures[pageID] = (path, mtime, blur, vignette)
    }

    /// Run `PageBackgroundEffects.apply(...)` on a background queue and
    /// hand the resulting bitmap back to the main thread. A per-page version
    /// token drops stale slider results so the latest effect values win.
    private func scheduleBackgroundFilterRender(image: UIImage,
                                                blur: Double,
                                                vignette: Double,
                                                pageID: UUID,
                                                imageView: UIImageView) {
        let version = (backgroundRenderVersions[pageID] ?? 0) + 1
        backgroundRenderVersions[pageID] = version
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = PageBackgroundEffects.apply(to: image, blur: blur, vignette: vignette)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.backgroundRenderVersions[pageID] == version else { return }
                imageView.image = result
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
        // Honor the deferred "open at page 1" snap once the scroll
        // view has real bounds and content size. Doing this in
        // layoutSubviews (rather than apply(document:)) is the only
        // moment we can trust that `scrollToPage`'s `pageFrame.minY`
        // computation reflects the actual rendered layout — earlier
        // calls compute against a 0×0 viewport and the offset gets
        // overwritten as soon as real layout lands.
        if pendingInitialScrollToTop,
           scrollView.bounds.height > 0,
           scrollView.contentSize.height > 0 {
            pendingInitialScrollToTop = false
            scrollToPage(at: 0, animated: false)
        }
    }

    /// Apply document-level page dimensions to the visible page frame
    /// and keep the scroll content wide/tall enough to show it.
    private func applyPageSizing(for document: ProfileDocument) {
        let pageWidth = effectivePageWidth(for: document)
        let viewportWidth = scrollView.bounds.width > 0 ? scrollView.bounds.width : bounds.width
        // Edge-to-edge on phones: pages render at the full canvas
        // width regardless of the document's `pageWidth`. The model's
        // pageWidth stays the canonical coordinate space children are
        // placed in; the editor stretches the rendered page so the
        // user perceives a full-screen canvas. On standard iPhones
        // the drift between viewport (393) and pageWidth (390) is
        // invisible; on Plus / Max devices a few points of trailing
        // space remain past the children's reach, which is the right
        // tradeoff for keeping the persisted document portable
        // across screen widths.
        //
        // On iPad-sized viewports (≥700pt) we *cap* the rendered
        // page width at a comfortable phone-canvas size and let the
        // pagesStackView's existing centerXAnchor constraint pin the
        // surface to the middle of the screen, with desk-color
        // margin on either side. Without the cap, an iPad would
        // either stretch the page bg edge-to-edge (children
        // clustered on the leading edge with empty trailing space)
        // or render at full iPad width with nodes scattered into
        // negative space on phone-authored documents — both feel
        // wrong. The cap matches the published viewer's behaviour
        // and the editor reads as "phone canvas on desk surface."
        let iPadBreakpoint: CGFloat = 700
        let iPadCap: CGFloat = 540
        let renderedPageWidth: CGFloat
        if viewportWidth >= iPadBreakpoint {
            renderedPageWidth = min(viewportWidth, max(pageWidth, iPadCap))
        } else {
            renderedPageWidth = max(viewportWidth, pageWidth)
        }
        let topPadding = viewerPageIndex == nil ? pageTopPadding : 0
        if let constraint = pagesStackTopConstraint,
           abs(constraint.constant - topPadding) > 0.5 {
            constraint.constant = topPadding
        }

        for pageIndex in visiblePageIndices(for: document) {
            let page = document.pages[pageIndex]
            guard let surface = pageSurfaces[page.id] else { continue }
            let pageHeight = effectivePageHeight(for: page)
            if abs(surface.widthConstraint.constant - renderedPageWidth) > 0.5 {
                surface.widthConstraint.constant = renderedPageWidth
            }
            if abs(surface.heightConstraint.constant - pageHeight) > 0.5 {
                surface.heightConstraint.constant = pageHeight
            }
            surface.shadowView.layer.shadowPath = UIBezierPath(
                rect: CGRect(origin: .zero, size: CGSize(width: renderedPageWidth, height: pageHeight))
            ).cgPath
        }

        // contentView width tracks the scroll view's frame (set up
        // in `init` via a layout-anchor equality), so its `.constant`
        // is unused in this path — no manual width math required
        // here anymore. Keep the addPageAffordance synced with the
        // rendered page width so the "+" affordance also spans
        // edge-to-edge.
        if let constraint = addPageWidthConstraint,
           abs(constraint.constant - renderedPageWidth) > 0.5 {
            constraint.constant = renderedPageWidth
        }
        if let constraint = addPageHeightConstraint,
           abs(constraint.constant - addPageHeight) > 0.5 {
            constraint.constant = addPageHeight
        }
        updateContentHeight()
    }

    private func effectivePageWidth(for document: ProfileDocument) -> CGFloat {
        max(240, CGFloat(document.pageWidth))
    }

    private func effectivePageHeight(for page: PageStyle) -> CGFloat {
        max(400, CGFloat(page.height))
    }

    /// Resize `contentView` to fit either the viewport or the page frame,
    /// whichever is taller. The page itself owns the visible design bounds;
    /// `contentView` is just scroll-space around that page.
    private func updateContentHeight() {
        let viewport = scrollView.bounds.height
        let topPadding = viewerPageIndex == nil ? pageTopPadding : 0
        let bottomPadding = viewerPageIndex == nil ? pageBottomPadding : 0
        let pageHeights = visiblePageIndices(for: document).compactMap { index -> CGFloat? in
            guard document.pages.indices.contains(index) else { return nil }
            let page = document.pages[index]
            return pageSurfaces[page.id]?.heightConstraint.constant ?? effectivePageHeight(for: page)
        }
        let pageGapTotal = CGFloat(max(0, pageHeights.count - 1)) * pagesStackView.spacing
        let addPageTotal = (viewerPageIndex == nil && isInteractive) ? pagesStackView.spacing + addPageHeight : 0
        let stackHeight = pageHeights.reduce(0, +) + pageGapTotal + addPageTotal
        let target = max(viewport, topPadding + stackHeight + bottomPadding)
        if let constraint = contentHeightConstraint,
           abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
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

    // MARK: - Edit mode chrome

    /// Walks every visible page surface and reconciles the edit-mode
    /// chrome (dashed outlines, labelled chips, inset accent stroke).
    /// Called from `setEditMode` and from the tail of `apply(...)` so
    /// document mutations during edit mode reposition chips immediately.
    ///
    /// The hero container itself is intentionally not chipped — it's
    /// system-owned, locked-resize, and serves as a transparent group
    /// for the avatar / name / meta / bio children. Those children
    /// each get their own chip so the user can edit them individually
    /// in edit mode. Other system-owned roots (the legacy
    /// `fixedDivider`) are skipped entirely. Everything else passes
    /// through unchanged.
    fileprivate func applyEditModeOverlays() {
        // Viewer mode never enters edit mode — there's no toggle.
        // Building chip / outline overlays here would still install
        // hidden UIControls into the page view tree, and even with
        // `alpha = 0` those chips can intercept hit-test inside
        // their bounds.insetBy(-6, -6) tap targets. That silently
        // ate taps meant for the gallery's "View Gallery" chip on
        // the published profile. Wipe any leftover overlay state
        // from an earlier editor session, then bail.
        guard isInteractive else {
            editModeOverlay.purgeAll()
            return
        }

        let pageIDs = visiblePageIndices(for: document).compactMap { document.pages[$0].id }
        let liveSet = Set(pageIDs)
        // Drop overlays for pages that no longer exist.
        for pageID in pageSurfaces.keys where !liveSet.contains(pageID) {
            editModeOverlay.purge(pageID: pageID)
        }
        for index in visiblePageIndices(for: document) {
            let page = document.pages[index]
            guard let surface = pageSurfaces[page.id] else { continue }
            // The page's actual bounds aren't laid out until the next
            // run-loop tick on first appear, so trigger one layout pass
            // up-front; the inset stroke needs accurate bounds to draw
            // along the page's rounded corners on a cold launch.
            surface.pageView.layoutIfNeeded()

            var editableNodeIDs: [UUID] = []
            for rootID in page.rootChildrenIDs {
                guard let node = document.nodes[rootID] else { continue }
                if node.role == .profileHero {
                    // Expand the hero into its editable children so
                    // each one (avatar, name, meta, bio) is reachable
                    // individually via its own chip. The hero itself
                    // gets no chip — it's a layout wrapper, not user
                    // content.
                    editableNodeIDs.append(contentsOf: node.childrenIDs.filter {
                        document.nodes[$0] != nil
                    })
                } else if node.role?.isSystemOwned != true {
                    editableNodeIDs.append(rootID)
                }
            }

            // Cherry on light page surfaces, soft shell on dark ones —
            // the dashed outline and the page's inset "armed" stroke
            // both pick up this accent so the chrome stays legible
            // against whatever theme or bg image is in play. Routes
            // through the same `isPageBackgroundDark` predicate the
            // hero text adaptive contrast uses, so a single luminance
            // decision drives every adaptive surface on the page.
            let darkBg = StructuredProfileLayout.isPageBackgroundDark(page: page)
            let accent: UIColor = darkBg ? .cucuShell : .cucuCherry

            editModeOverlay.apply(
                editMode: editMode,
                pageID: page.id,
                pageView: surface.pageView,
                accent: accent,
                nodeIDs: editableNodeIDs,
                lookup: { [weak self] id -> (node: CanvasNode, frame: CGRect)? in
                    guard let self,
                          let node = self.document.nodes[id] else { return nil }
                    return (node, self.absolutePageFrame(of: id))
                }
            )
        }
    }

    /// Walk the document parent chain and accumulate frame offsets so
    /// the chip overlay can place outlines/chips for nested nodes
    /// (e.g. the hero's children) directly inside the page UIView. The
    /// document's parent topology is the source of truth — using it
    /// means a `pageView.convert(_:from:)` round trip isn't required,
    /// which avoids a stale-layout class of bugs where the UIView
    /// hierarchy hasn't yet caught up to a freshly-applied document.
    private func absolutePageFrame(of nodeID: UUID) -> CGRect {
        guard let node = document.nodes[nodeID] else { return .zero }
        var origin = CGPoint(x: node.frame.x, y: node.frame.y)
        var current = document.parent(of: nodeID)
        while let parentID = current {
            guard let parent = document.nodes[parentID] else { break }
            origin.x += CGFloat(parent.frame.x)
            origin.y += CGFloat(parent.frame.y)
            current = document.parent(of: parentID)
        }
        return CGRect(origin: origin,
                      size: CGSize(width: node.frame.width, height: node.frame.height))
    }

    /// Sets per-node interaction state to match the user-facing
    /// "editing requires the toggle" rule.
    ///
    /// - Live mode: top-level node bodies are non-interactive and
    ///   their pan recognizers are off. Tap and drag both fall
    ///   through to the canvas-level recognizer (which no-ops in
    ///   live mode), so the canvas reads as a pure preview.
    /// - Edit mode: bodies stay non-interactive (selection happens
    ///   via the floating chip), with one exception — the
    ///   currently-selected text node keeps interaction so a second
    ///   tap can drop into in-place text editing. Pan gestures
    ///   re-enable in edit mode so drag-to-reposition still works as
    ///   a productive editing affordance.
    /// - Viewer mode (`!isInteractive`): no-op. The viewer attaches
    ///   its own per-type tap recognizers in `attachPanGesture` (the
    ///   link / journal card paths) and content-bearing nodes like
    ///   the gallery rely on internal UIControls (the "View
    ///   Gallery" chip). Disabling the parent here would propagate
    ///   down via UIKit's hit-test rules and silently break those
    ///   internal taps — matching the published profile bug where
    ///   the View Gallery chip became unclickable.
    fileprivate func applyNodeInteractionForEditMode() {
        guard isInteractive else { return }
        let topLevelIDs: Set<UUID> = Set(
            visiblePageIndices(for: document)
                .flatMap { document.pages[$0].rootChildrenIDs }
        )
        for id in topLevelIDs {
            guard let view = renderViews[id] else { continue }
            // System-owned roles (hero, fixed divider, and the hero's
            // children) are part of the structured profile chrome —
            // they have no edit chip and are intentionally untappable
            // in both modes. Treat them as locked even when edit mode
            // re-enables interaction on user-added top-level nodes.
            let systemOwned = document.nodes[id]?.role?.isSystemOwned == true
            view.isUserInteractionEnabled = editMode && !systemOwned
            nodePanGestures[id]?.isEnabled = editMode && !systemOwned
        }
    }
}

// MARK: - Gesture delegate (selection-aware arbitration)

extension CanvasEditorView: UIGestureRecognizerDelegate, UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateEditingPageForCurrentState()
    }

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
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let view = pan.view as? NodeRenderView
        let touchPoint = pan.location(in: pan.view ?? self)
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
        //   2. Press + drag the same node → it moves (or reorders
        //      at the page root).
        //   3. Press + drag elsewhere on the canvas → page scrolls.

        // Top-level non-system nodes use the pan as a vertical
        // *reorder* gesture, not a freeform-move gesture. The
        // type-level resize lock (`image`/`gallery`/`carousel`/
        // `divider`/`link` → `.locked`, `sectionCard` →
        // `.verticalOnly`) makes `canMove` return false for almost
        // every reorderable block, which would otherwise reject the
        // pan here and hand the touch to the scroll view. Bypass
        // the `canMove` gate when the touch is a legitimate reorder
        // attempt — top-level, not system-owned, edit mode on, and
        // the node is the active selection.
        let isTopLevel = document.parent(of: viewID) == nil
        let isSystemOwned = document.nodes[viewID]?.role?.isSystemOwned == true
        let isTopLevelReorder = isTopLevel && !isSystemOwned && editMode

        if !isTopLevelReorder {
            guard StructuredProfileLayout.canMove(viewID, in: document) else {
                return false
            }
        }
        guard let selID = selectedID, selID == viewID else {
            return false
        }
        if let carousel = view as? CarouselNodeView,
           carousel.shouldPreferScrolling(forPanVelocity: pan.velocity(in: view)) {
            return false
        }
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
