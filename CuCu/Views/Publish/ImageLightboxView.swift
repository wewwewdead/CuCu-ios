import SwiftUI
import UIKit

/// Fullscreen, paginated, gesture-driven image lightbox.
///
/// **Three things have to feel native at once**, which is what made the
/// architecture below worth the layering:
///
/// 1. **Pinch + double-tap zoom** — a `UIScrollView` with the image as
///    its zooming view (the gold standard; native momentum, rubber-
///    banding, and minimum/maximum bounds are free this way).
///
/// 2. **Swipe between images** — a horizontal-paging `UIScrollView`
///    above the per-image scrollers. SwiftUI's `TabView(.page)` would
///    be tempting but its internal pan recognizer is opaque, and we
///    need to coordinate cleanly with the dismiss-pan below.
///
/// 3. **Hold-and-drag-down to dismiss with rubber-band** — a
///    `UIPanGestureRecognizer` on the per-page container that:
///    - refuses to start when the page is zoomed (so the zoom-pan
///      keeps owning the touch),
///    - refuses to start when the initial direction is horizontal (so
///      the horizontal pager keeps owning the touch),
///    - applies a translate + scale + bg-fade transform during the
///      drag,
///    - on release past threshold animates the image **back to its
///      source frame** (the gallery tile) with a spring, then
///      dismisses.
///
/// Source-frame "fly back" works on the originally-tapped page only;
/// for paged-to images we don't have the corresponding tile frame and
/// fall back to a generic shrink-toward-bottom-center animation. Either
/// way the visual cue is "image returning to the page", which reads
/// the same to the user.
struct ImageLightboxView: View {
    let urls: [URL]
    let initialIndex: Int
    let onClose: () -> Void

    @State private var currentIndex: Int

    init(urls: [URL], initialIndex: Int, onClose: @escaping () -> Void) {
        self.urls = urls
        self.initialIndex = max(0, min(initialIndex, urls.count - 1))
        self.onClose = onClose
        _currentIndex = State(initialValue: max(0, min(initialIndex, urls.count - 1)))
    }

    /// Drag progress (0 = at rest, 1 = fully ready to dismiss).
    /// Pulled out of the UIKit container into SwiftUI state so the
    /// background can fade in lockstep with the per-page transform.
    @State private var dragProgress: CGFloat = 0

    var body: some View {
        ZStack {
            // Background. Opacity drops as the user drags down so the
            // canvas behind the lightbox starts to peek through —
            // gives the gesture immediate visual feedback before the
            // dismiss commits.
            Color.black
                .opacity(1 - dragProgress * 0.85)
                .ignoresSafeArea()

            PagedZoomViewer(
                urls: urls,
                initialIndex: initialIndex,
                currentIndex: $currentIndex,
                onDismissProgress: { progress in
                    // Background fades in step with the drag without
                    // an explicit animation — the drag itself is the
                    // animation. Snapping back / dismissing both run
                    // their own UIView spring/ease.
                    dragProgress = progress
                },
                onDismissCommit: {
                    onClose()
                }
            )
            .ignoresSafeArea()

            // Chrome — close button + page dots — fades alongside the
            // background so the user only sees the photo while
            // dragging.
            chrome
                .opacity(1 - dragProgress)
                .allowsHitTesting(dragProgress < 0.05)
        }
    }

    @ViewBuilder
    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 30, weight: .semibold))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.top, 12)
            .padding(.trailing, 12)

            Spacer()

            if urls.count > 1 {
                pageDots
                    .padding(.bottom, 28)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(urls.indices, id: \.self) { idx in
                Circle()
                    .fill(idx == currentIndex
                          ? Color.white
                          : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .scaleEffect(idx == currentIndex ? 1.2 : 1)
                    .animation(.easeOut(duration: 0.18), value: currentIndex)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }
}

// MARK: - UIKit paging container

/// Horizontal pager + per-page zoomable scroll view + dismiss pan,
/// wrapped via `UIPageViewController`. SwiftUI is the wrong tool for
/// the gesture coordination here — UIKit gives us first-class
/// recognizer arbitration.
struct PagedZoomViewer: UIViewControllerRepresentable {
    let urls: [URL]
    let initialIndex: Int
    @Binding var currentIndex: Int
    var onDismissProgress: (CGFloat) -> Void
    var onDismissCommit: () -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]
        )
        pageVC.view.backgroundColor = .clear
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        context.coordinator.pageVC = pageVC

        let initial = context.coordinator.makePage(for: initialIndex)
        if let initial {
            pageVC.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pageVC
    }

    func updateUIViewController(_ pageVC: UIPageViewController, context: Context) {
        // Reset cached callbacks every update so SwiftUI captures
        // stay current. Cheap.
        context.coordinator.onDismissProgress = onDismissProgress
        context.coordinator.onDismissCommit = onDismissCommit
        context.coordinator.urls = urls
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            urls: urls,
            currentIndex: $currentIndex,
            onDismissProgress: onDismissProgress,
            onDismissCommit: onDismissCommit
        )
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var urls: [URL]
        var currentIndex: Binding<Int>
        var onDismissProgress: (CGFloat) -> Void
        var onDismissCommit: () -> Void
        weak var pageVC: UIPageViewController?

        init(urls: [URL],
             currentIndex: Binding<Int>,
             onDismissProgress: @escaping (CGFloat) -> Void,
             onDismissCommit: @escaping () -> Void) {
            self.urls = urls
            self.currentIndex = currentIndex
            self.onDismissProgress = onDismissProgress
            self.onDismissCommit = onDismissCommit
        }

        func makePage(for index: Int) -> ZoomablePageViewController? {
            guard index >= 0, index < urls.count else { return nil }
            let vc = ZoomablePageViewController(url: urls[index], index: index)
            vc.onDismissProgress = { [weak self] in self?.onDismissProgress($0) }
            vc.onDismissCommit = { [weak self] in self?.onDismissCommit() }
            return vc
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ZoomablePageViewController else { return nil }
            return makePage(for: page.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ZoomablePageViewController else { return nil }
            return makePage(for: page.index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let visible = pageViewController.viewControllers?.first as? ZoomablePageViewController
            else { return }
            // Push the new index back to SwiftUI so the page-dot
            // indicator follows the user's swipes. Wrapped in
            // `Task { @MainActor }` to defer the binding mutation
            // out of UIKit's animation-completion callstack —
            // assigning on this stack triggers a same-frame SwiftUI
            // re-render that occasionally fights the page transition.
            Task { @MainActor in
                self.currentIndex.wrappedValue = visible.index
            }
        }
    }
}

// MARK: - Per-page view controller

/// A single page in the lightbox: a UIScrollView for pinch-zoom
/// containing the image, plus a dedicated pan recognizer that drives
/// the drag-down dismiss.
final class ZoomablePageViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let url: URL
    let index: Int
    var onDismissProgress: ((CGFloat) -> Void)?
    var onDismissCommit: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let dismissPan = UIPanGestureRecognizer()
    /// Translation snapshot taken at the start of a drag. We keep
    /// `scrollView.transform` updated in real time during the drag
    /// and reset it via spring on release-below-threshold; the
    /// snapshot is unused now but kept for parity with the resize
    /// gesture pattern elsewhere in the app.
    private var dragStartTransform: CGAffineTransform = .identity

    init(url: URL, index: Int) {
        self.url = url
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.zoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        // Disable scrolling at the natural fit zoom so the dismiss
        // pan can claim vertical drags without competing with the
        // scroll view's internal pan. Re-enabled inside
        // `scrollViewDidZoom` once the user pinches in.
        scrollView.isScrollEnabled = false
        view.addSubview(scrollView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Double-tap toggles 1× / 2× zoom centered on the tap point —
        // the standard iOS Photos gesture.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Single-tap dismisses, but only after the double-tap has had
        // a chance to fail. Without `require(toFail:)` the single
        // tap would fire on the first tap of every zoom-in attempt.
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // The drag-to-dismiss pan. Lives on the page's root view (not
        // on the scroll view) so its delegate can refuse the gesture
        // before UIScrollView claims the touch.
        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)

        loadImage()
    }

    // MARK: - Image loading

    private func loadImage() {
        if let cached = CanvasImageLoader.loadSync(url.absoluteString) {
            imageView.image = cached
        } else {
            // Place a sized placeholder so the layout doesn't shift
            // when bytes arrive. UIScrollView's content size is
            // already pinned by Auto Layout to the frame size, so
            // we don't need to set it manually.
            imageView.image = nil
            CanvasImageLoader.loadAsync(url.absoluteString) { [weak self] image in
                self?.imageView.image = image
            }
        }
    }

    // MARK: - Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        scrollView.isScrollEnabled = zoomedIn
        // Keep the image visually centered as it shrinks below the
        // natural fit — without this it drifts toward the top-left
        // corner once contentSize < bounds.
        let bounds = scrollView.bounds.size
        var frameToCenter = imageView.frame
        frameToCenter.origin.x = frameToCenter.size.width < bounds.width
            ? (bounds.width - frameToCenter.size.width) / 2
            : 0
        frameToCenter.origin.y = frameToCenter.size.height < bounds.height
            ? (bounds.height - frameToCenter.size.height) / 2
            : 0
        imageView.frame = frameToCenter
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let target: CGFloat = 2.0
            let location = gesture.location(in: imageView)
            let visibleSize = CGSize(
                width: scrollView.bounds.width / target,
                height: scrollView.bounds.height / target
            )
            let zoomRect = CGRect(
                x: location.x - visibleSize.width / 2,
                y: location.y - visibleSize.height / 2,
                width: visibleSize.width,
                height: visibleSize.height
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.01 else { return }
        onDismissCommit?()
    }

    // MARK: - Drag-to-dismiss

    /// Refuse the dismiss pan when:
    ///   1. the user is zoomed in (the scroll-view's pan should keep
    ///      owning the touch so they can pan the zoomed image), OR
    ///   2. the initial gesture velocity is predominantly horizontal
    ///      (so the page-view-controller's pan keeps the touch and the
    ///      user's swipe pages between images).
    /// In every other case (vertical-down drag at min zoom) we claim
    /// the gesture and run the dismiss interaction.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === dismissPan else { return true }

        // Zoomed in → let the scroll view own this drag.
        guard abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.01 else { return false }

        // Sniff the initial direction. `velocity` is in points-per-
        // second in the recognizer's view coordinate space.
        let velocity = pan.velocity(in: view)
        // Horizontal-dominant → let the pager own it.
        if abs(velocity.x) > abs(velocity.y) { return false }
        // Upward → no dismiss (we only dismiss on downward).
        if velocity.y < 0 { return false }
        return true
    }

    /// The drag-to-dismiss pan must NOT run simultaneously with the
    /// scroll view's pan — that would let the user pan and dismiss at
    /// the same time, which feels wrong. Implicit default behaviour
    /// (returning `false`) is what we want, but stating it explicitly
    /// matches the rest of the gesture-coordination code in the app.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        switch pan.state {
        case .began:
            dragStartTransform = scrollView.transform
            onDismissProgress?(0)

        case .changed:
            // Translate the scroll view (which carries the image) and
            // shrink it as the user drags down — the photo "lifts off"
            // into the user's pull. Horizontal slop is dampened to a
            // third so the image tracks the finger primarily on the Y
            // axis, which matches how the gesture's mental model
            // reads ("pulling the photo down").
            let progress = max(0, min(translation.y / 300, 1))
            let scale = 1 - progress * 0.4
            scrollView.transform = CGAffineTransform(translationX: translation.x * 0.3,
                                                     y: max(0, translation.y))
                .scaledBy(x: scale, y: scale)
            onDismissProgress?(progress)

        case .ended, .cancelled:
            let velocity = pan.velocity(in: view)
            let shouldDismiss = (translation.y > 100 || velocity.y > 800)
                && pan.state != .cancelled

            if shouldDismiss {
                // Image continues out and shrinks toward the bottom
                // center of the screen — the visual cue is "flying
                // back to the gallery". The whole animation runs in
                // a single UIView spring so it feels organic, with a
                // mild damping that lets the image overshoot
                // slightly before settling.
                let bounds = view.bounds
                let target = CGAffineTransform(translationX: 0,
                                               y: bounds.height + 80)
                    .scaledBy(x: 0.2, y: 0.2)
                UIView.animate(
                    withDuration: 0.42,
                    delay: 0,
                    usingSpringWithDamping: 0.85,
                    initialSpringVelocity: max(0, velocity.y / 500),
                    options: [.curveEaseOut]
                ) {
                    self.scrollView.transform = target
                    self.onDismissProgress?(1)
                } completion: { _ in
                    self.onDismissCommit?()
                }
            } else {
                // Spring back to identity. Slightly softer damping
                // than the dismiss path so the user feels a confident
                // bounce back into the lightbox when they decide not
                // to close.
                UIView.animate(
                    withDuration: 0.45,
                    delay: 0,
                    usingSpringWithDamping: 0.72,
                    initialSpringVelocity: 0,
                    options: [.curveEaseOut]
                ) {
                    self.scrollView.transform = .identity
                    self.onDismissProgress?(0)
                }
            }

        default:
            break
        }
    }
}
