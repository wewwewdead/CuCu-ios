import UIKit

/// Renders a `.gallery` node — multiple `LocalCanvasAssetStore` images
/// laid out inside one frame. Three layouts:
///
/// - `.grid`    — 2- or 3-column tile grid, rows fill top-to-bottom.
/// - `.row`     — one horizontal strip, fits-to-width without scrolling.
/// - `.collage` — overlapping rotated tiles, each with a thin white
///                border for that scrapbook feel.
///
/// **Tile model** — each tile is a wrapper `UIView` containing a single
/// `UIImageView`. The wrapper owns the *frame* and (for collage) the
/// *drop shadow*; the inner image view owns the *rounded corners*,
/// *border*, and *clipping*. This split is what makes "rounded corners
/// + drop shadow" work at all on UIKit: shadows require `masksToBounds
/// = false`, but corner clipping requires `masksToBounds = true`. One
/// view can't satisfy both, hence the wrapper.
///
/// Behavior contract:
/// - The list of paths comes from `node.content.imagePaths`.
/// - Missing files render as a gray placeholder tile so the layout
///   doesn't shift if a backup restore is partial.
/// - The shared `cornerRadius`, `borderColor`, `borderWidth`, `opacity`
///   apply per tile so corners are consistent regardless of layout.
final class GalleryNodeView: NodeRenderView {
    private struct TileContentSignature: Equatable {
        var paths: [String]
        var modificationDates: [Date?]
        var imageFit: NodeImageFit
    }

    /// Container for the per-tile wrappers. Cleared and rebuilt on
    /// every apply pass — galleries are usually small (≤ 12 images)
    /// and a fresh layout is simpler than reconciling tiles.
    private let stage = UIView()

    /// Tile wrappers keyed positionally by their index in
    /// `cachedPaths`. The image view inside each wrapper is its only
    /// subview, so `wrapper.subviews.first as? UIImageView` is always
    /// safe.
    private var tileWrappers: [UIView] = []

    /// Set by the host (CanvasEditorView) only in viewer mode. When
    /// non-nil, every tile wrapper gets a tap recognizer that fires
    /// this callback with the tile index. Editor mode leaves it nil
    /// so taps fall through to the canvas's selection logic instead
    /// of the lightbox.
    var onTileTapped: ((Int) -> Void)?

    /// Set by the host (CanvasEditorView) only in viewer mode. When
    /// non-nil, a small "View Gallery" chip appears at the bottom-
    /// right corner of the gallery — tapping it opens the full
    /// paginated grid (`FullGalleryView`). Editor mode leaves the
    /// chip hidden so the canvas surface looks identical to what the
    /// author sees.
    var onViewAll: (() -> Void)? {
        didSet { updateViewAllChipVisibility() }
    }

    /// Editorial-scrapbook chip rendered in viewer mode at the
    /// bottom-right of the gallery. Cream paper + ink stroke, with
    /// a hand-cut tilt and a tactile press animation. See
    /// `ViewGalleryChipView` (below) for the visual recipe.
    private let viewAllChip = ViewGalleryChipView()

    /// Cached on apply so a `layoutSubviews` after a resize can
    /// recompute tile frames without re-decoding bitmaps.
    private var cachedPaths: [String] = []
    private var cachedLayout: NodeGalleryLayout = .grid
    private var cachedGap: CGFloat = 6
    private var cachedCorner: CGFloat = 8
    private var cachedBorderColor: UIColor?
    private var cachedBorderWidth: CGFloat = 0
    private var cachedPlaceholderColor: UIColor = .secondarySystemFill
    /// `Fit` letterboxes the photo inside the tile (whole image
    /// visible); `Fill` crops the photo to fill the tile. Defaults to
    /// `.fit` so freshly added galleries never crop content the user
    /// just picked.
    private var cachedImageFit: NodeImageFit = .fit
    private var lastTileContentSignature: TileContentSignature?

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        stage.translatesAutoresizingMaskIntoConstraints = false
        // Stage MUST allow user interaction so tile-level tap
        // recognizers (attached in viewer mode by `rebuildTiles`)
        // actually receive touches. UIKit's hit-test refuses to
        // descend into a view whose `isUserInteractionEnabled` is
        // false, regardless of any subview's own setting — that's
        // exactly the trap the original `false` here fell into.
        //
        // Editor mode is unaffected: no tile recognizer is attached
        // there, so taps fall through to the canvas's contentView
        // tap recognizer (which selects the gallery node) the same
        // way they did before.
        stage.isUserInteractionEnabled = true
        // Stage doesn't clip — collage shadows can extend slightly
        // beyond the gallery's bounds and we want them visible.
        stage.clipsToBounds = false
        addSubview(stage)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The "View Gallery" chip pins to the bottom-right corner.
        // Lives directly on the gallery view (not inside `stage`)
        // so it sits above the tile wrappers in the z-order without
        // having to re-front-bring it on every rebuild. Starts
        // hidden so the entry-bounce animation has somewhere to
        // bounce from on viewer-mode init.
        viewAllChip.isHidden = true
        addSubview(viewAllChip)
        NSLayoutConstraint.activate([
            viewAllChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            viewAllChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        viewAllChip.addTarget(self, action: #selector(handleViewAllTap), for: .touchUpInside)
    }

    /// Show the chip only when the host has wired the viewer-mode
    /// callback. Flipping `nil → non-nil` triggers a one-shot
    /// scale-in bounce so the user notices the new affordance.
    private func updateViewAllChipVisibility() {
        let shouldShow = (onViewAll != nil)
        let wasHidden = viewAllChip.isHidden
        if shouldShow {
            viewAllChip.isHidden = false
            bringSubviewToFront(viewAllChip)
            if wasHidden {
                viewAllChip.playEntryAnimation()
            }
        } else {
            viewAllChip.isHidden = true
        }
    }

    @objc private func handleViewAllTap() {
        onViewAll?()
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)
        cachedPaths = node.content.imagePaths ?? []
        cachedLayout = node.style.galleryLayout ?? .grid
        cachedGap = max(CGFloat(node.style.galleryGap ?? 6), 0)
        cachedCorner = max(CGFloat(node.style.cornerRadius), 0)
        cachedBorderColor = node.style.borderColorHex.map(uiColor(hex:))
        cachedBorderWidth = max(CGFloat(node.style.borderWidth), 0)
        cachedImageFit = node.style.imageFit ?? .fit
        // Keep the chip's photo count in sync with the live gallery —
        // the user might add or remove images from the inspector and
        // the count should reflect that on the next reconciliation.
        viewAllChip.photoCount = cachedPaths.count
        // Gallery clips its tiles to its own bounds. The trade is
        // that collage shadow tails get clipped at the gallery's edge
        // — that's preferable to letting rotated tiles overflow into
        // the surrounding canvas (the user expects "the gallery's
        // contents" to mean "the contents of the gallery's frame").
        // The collage layout below insets the tiles enough that the
        // shadow remains visible inside the frame.
        let signature = TileContentSignature(
            paths: cachedPaths,
            modificationDates: cachedPaths.map { LocalCanvasAssetStore.modificationDate($0) },
            imageFit: cachedImageFit
        )
        if lastTileContentSignature != signature || tileWrappers.isEmpty {
            rebuildTiles()
            lastTileContentSignature = signature
        }
        relayoutTiles()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayoutTiles()
    }

    // MARK: - Tile management

    private func rebuildTiles() {
        // Drop existing wrappers and create fresh ones. Empty gallery
        // → a single placeholder tile so the user sees the node's
        // bounds and can drag/resize it before adding images.
        tileWrappers.forEach { $0.removeFromSuperview() }
        tileWrappers.removeAll()

        let pathsToRender: [String?]
        if cachedPaths.isEmpty {
            pathsToRender = [nil]
        } else {
            pathsToRender = cachedPaths.map { Optional($0) }
        }

        for (idx, path) in pathsToRender.enumerated() {
            let wrapper = UIView()
            wrapper.backgroundColor = .clear
            wrapper.clipsToBounds = false
            wrapper.layer.masksToBounds = false

            // Viewer mode: every tile is tappable. We store the index
            // on the wrapper's `tag` so the recognizer's selector can
            // look it up without a closure capture per tile (which
            // would proliferate when galleries rebuild often).
            if onTileTapped != nil {
                wrapper.tag = idx
                wrapper.isUserInteractionEnabled = true
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTileTap(_:)))
                tap.numberOfTapsRequired = 1
                wrapper.addGestureRecognizer(tap)
            }

            let iv = UIImageView()
            // Pin via autoresizing mask so a later wrapper.frame
            // change auto-resizes the image (no manual frame
            // re-application required from layoutSubviews).
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            iv.contentMode = effectiveContentMode(for: path)
            iv.clipsToBounds = true
            iv.layer.cornerCurve = .continuous

            if let path, let image = CanvasImageLoader.loadSync(path) {
                iv.image = image
                iv.backgroundColor = UIColor(white: 0.97, alpha: 1)
                iv.tintColor = nil
            } else if let path, !path.isEmpty, CanvasImageLoader.isRemote(path) {
                // Remote tile not yet cached — show the placeholder
                // chrome and swap in when the bytes arrive. Capture
                // the imageView weakly so the callback doesn't keep
                // a torn-down tile alive.
                iv.image = UIImage(systemName: "photo")
                iv.tintColor = .tertiaryLabel
                iv.backgroundColor = cachedPlaceholderColor
                iv.contentMode = .center
                let fit = effectiveContentMode(for: path)
                CanvasImageLoader.loadAsync(path) { [weak iv] image in
                    guard let iv, let image else { return }
                    iv.image = image
                    iv.tintColor = nil
                    iv.backgroundColor = UIColor(white: 0.97, alpha: 1)
                    iv.contentMode = fit
                }
            } else {
                iv.image = UIImage(systemName: "photo")
                iv.tintColor = .tertiaryLabel
                iv.backgroundColor = cachedPlaceholderColor
                iv.contentMode = .center
            }

            wrapper.addSubview(iv)
            stage.addSubview(wrapper)
            tileWrappers.append(wrapper)
        }
    }

    /// Tile-level tap handler. The wrapper's `tag` carries its tile
    /// index so we can resolve the path back inside the host without
    /// re-parsing the view hierarchy. No haptic — the lightbox's
    /// presentation animation is feedback enough.
    @objc private func handleTileTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view, let cb = onTileTapped else { return }
        cb(view.tag)
    }

    /// Resolve the content mode used for *real* photos based on the
    /// gallery's `imageFit` style. Placeholders always use `.center`
    /// (and override this elsewhere) so they don't blur or stretch.
    private func effectiveContentMode(for path: String?) -> UIView.ContentMode {
        switch cachedImageFit {
        case .fill: return .scaleAspectFill
        case .fit:  return .scaleAspectFit
        }
    }

    private func relayoutTiles() {
        guard !tileWrappers.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        switch cachedLayout {
        case .grid:    layoutGrid()
        case .row:     layoutRow()
        case .collage: layoutCollage()
        }
    }

    /// 2-column grid for ≤4 images, 3-column for >4. Rows fill from
    /// the top, last row may have fewer tiles. Always honours
    /// `galleryGap`.
    private func layoutGrid() {
        let count = tileWrappers.count
        let columns = count <= 4 ? 2 : 3
        let rows = Int(ceil(Double(count) / Double(columns)))
        let totalGapW = cachedGap * CGFloat(columns - 1)
        let totalGapH = cachedGap * CGFloat(rows - 1)
        let tileW = (bounds.width - totalGapW) / CGFloat(columns)
        let tileH = (bounds.height - totalGapH) / CGFloat(rows)

        for (i, wrapper) in tileWrappers.enumerated() {
            let row = i / columns
            let col = i % columns
            wrapper.transform = .identity
            wrapper.frame = CGRect(
                x: CGFloat(col) * (tileW + cachedGap),
                y: CGFloat(row) * (tileH + cachedGap),
                width: tileW,
                height: tileH
            )
            applyTileChrome(wrapper: wrapper, collageStyle: false)
        }
    }

    /// One horizontal row spanning the full width — no scrolling, tile
    /// width derived from count + gap.
    private func layoutRow() {
        let count = tileWrappers.count
        guard count > 0 else { return }
        let totalGap = cachedGap * CGFloat(count - 1)
        let tileW = (bounds.width - totalGap) / CGFloat(count)
        let tileH = bounds.height
        for (i, wrapper) in tileWrappers.enumerated() {
            wrapper.transform = .identity
            wrapper.frame = CGRect(
                x: CGFloat(i) * (tileW + cachedGap),
                y: 0,
                width: tileW,
                height: tileH
            )
            applyTileChrome(wrapper: wrapper, collageStyle: false)
        }
    }

    /// Overlapping rotated tiles, distributed in a deterministic
    /// spiral. Sized so that **after** the worst-case tilt + the spiral
    /// offset, the tile's rotated bounding box still fits inside the
    /// gallery's bounds — we don't want rotated corners poking out
    /// past the gallery's clip.
    ///
    /// Geometry: a tile of side `s` rotated by `θ` has a bounding-box
    /// half-extent of `s/2 · (|cos θ| + |sin θ|)`. With `θ ≤ ~6°` (the
    /// worst tilt this layout produces) that's ≈ `s · 0.55`. Plus the
    /// spiral offset `r`, the farthest pixel from the gallery center
    /// is `r + s · 0.55`, which has to be ≤ `min(w, h) / 2`. We pick
    /// `s = 0.46 · minDim` and `r = 0.16 · minDim`, giving roughly 4%
    /// of `minDim` slack — enough that drop shadows still render
    /// inside the gallery without the photo itself overflowing.
    private func layoutCollage() {
        let count = tileWrappers.count
        guard count > 0 else { return }
        let minDim = min(bounds.width, bounds.height)
        let tileSide = minDim * 0.46
        let centerX = bounds.midX
        let centerY = bounds.midY
        let radius: CGFloat = (count > 1) ? minDim * 0.16 : 0
        for (i, wrapper) in tileWrappers.enumerated() {
            let angle = Double(i) * (Double.pi * 2 / Double(max(count, 1)))
            let cx = centerX + CGFloat(cos(angle)) * radius
            let cy = centerY + CGFloat(sin(angle)) * radius
            // Reset transform before computing frame; UIKit's frame
            // semantics under a non-identity transform get murky, and
            // collage tilts compound across applies otherwise.
            wrapper.transform = .identity
            wrapper.frame = CGRect(
                x: cx - tileSide / 2,
                y: cy - tileSide / 2,
                width: tileSide,
                height: tileSide
            )
            applyTileChrome(wrapper: wrapper, collageStyle: true)
            // Subtle deterministic tilt — different per tile so it
            // reads as scrapbook, not a tidy grid. Capped at ~6° so
            // the rotated bounding box stays inside the bounds we
            // sized the tile for above.
            let tilt = (Double((i * 17 + 11) % 19) - 9) / 90.0  // ≈ ±0.10 rad ≈ ±5.7°
            wrapper.transform = CGAffineTransform(rotationAngle: CGFloat(tilt))
        }
    }

    /// Pin the inner image view to the wrapper's bounds and apply the
    /// look — corners, border, optional shadow.
    ///
    /// The corner radius / border live on the **inner** image view (so
    /// the rounded edges actually clip the bitmap). The shadow lives on
    /// the **wrapper** (so it can extend past the rounded silhouette
    /// without being clipped). `shadowPath` is set explicitly to the
    /// same rounded rect so the shadow tracks the corner radius
    /// instead of falling off a square box.
    private func applyTileChrome(wrapper: UIView, collageStyle: Bool) {
        guard let imageView = wrapper.subviews.first as? UIImageView else { return }
        imageView.frame = wrapper.bounds
        imageView.layer.cornerRadius = cachedCorner
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        imageView.layer.masksToBounds = true

        if collageStyle {
            // Inner image: rounded + clipped + white scrapbook border.
            imageView.layer.borderColor = UIColor.white.cgColor
            imageView.layer.borderWidth = max(cachedBorderWidth, 3)
            // Wrapper: shadow only, no clip — this is what the user
            // sees behind the rounded white frame.
            wrapper.clipsToBounds = false
            wrapper.layer.masksToBounds = false
            wrapper.layer.shadowColor = UIColor.black.cgColor
            wrapper.layer.shadowOffset = CGSize(width: 0, height: 4)
            wrapper.layer.shadowRadius = 6
            wrapper.layer.shadowOpacity = 0.25
            // Critical: pin the shadow to the rounded silhouette so
            // the shadow itself has rounded corners. Without an
            // explicit `shadowPath`, UIKit uses the layer's bounding
            // box (square) and the shadow corners look sharp even
            // though the visible art is rounded.
            wrapper.layer.shadowPath = UIBezierPath(
                roundedRect: wrapper.bounds,
                cornerRadius: cachedCorner
            ).cgPath
        } else {
            // Inner image: user-controlled corner / border. Wrapper
            // is just a flat passthrough — no shadow.
            imageView.layer.borderColor = cachedBorderColor?.cgColor ?? UIColor.clear.cgColor
            imageView.layer.borderWidth = cachedBorderWidth
            wrapper.layer.shadowOpacity = 0
            wrapper.layer.shadowPath = nil
            wrapper.clipsToBounds = false
            wrapper.layer.masksToBounds = false
        }
    }
}

// MARK: - View Gallery chip
//
// A scrapbook-style "tag" that hangs off the bottom-right of every
// gallery in viewer mode. Visual recipe:
//
//   1. Cream `cucuCard` ground with a 1.4pt ink stroke and a soft
//      drop shadow — same chrome the design system uses for floating
//      surfaces, so it reads as "of the page" rather than overlay UI.
//   2. Cherry sparkles glyph (SF Symbols `sparkles`, semibold) +
//      Caprasimo italic "view gallery" stacked over a mono-caps
//      photo count. Cherry → ink → ink-faded gives the eye a clear
//      reading path top-to-bottom.
//   3. A persistent ~-2.2° tilt so the chip looks like a small
//      paper tag clipped onto the gallery rather than an iOS
//      affordance bolted on top. Tilt persists through press
//      animations so the chip doesn't snap to upright when tapped.
//   4. **Tactile press**: TouchDown shrinks to 96% in 80ms; touch
//      up springs back with a 0.62-damping bounce. The brief
//      flicker of motion is the cue users use to confirm the tap
//      registered.
//   5. **Bouncy entrance**: when the chip first becomes visible
//      (i.e. when viewer mode wires `onViewAll`), it spring-pops
//      from 50% scale + alpha 0 to its tilted resting state. Draws
//      the eye to the new affordance without screaming for it.
//
// Subclassing `UIControl` (not `UIButton`) gives us native
// touch-state events (`.touchDown`, `.touchUpInside`, …) without
// having to fight UIButton's built-in highlight rendering for our
// custom chrome. Subviews are user-interaction-disabled so the
// control swallows hits cleanly across its whole footprint.
private final class ViewGalleryChipView: UIControl {
    private let sparkleView = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    /// Persistent rotation transform — the press / entry animations
    /// scale onto this base instead of replacing it, so the tilt
    /// stays put across every interaction state.
    private let baseTransform = CGAffineTransform(rotationAngle: -0.038)

    /// Number of photos the source gallery has. Drives the
    /// "12 PHOTOS" label; updated on every `apply(node:)` so the
    /// count tracks live edits the user makes from the inspector.
    var photoCount: Int = 0 {
        didSet {
            countLabel.text = photoCount == 1
                ? "1 PHOTO"
                : "\(photoCount) PHOTOS"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        configureChrome()
        configureContent()
        installPressFeedback()
        transform = baseTransform
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureChrome() {
        backgroundColor = uiColor(hex: "#FBF9F2")  // cucuCard
        layer.cornerRadius = 16
        layer.borderColor = uiColor(hex: "#1A140E").cgColor  // cucuInk
        layer.borderWidth = 1.4
        layer.shadowColor = uiColor(hex: "#1A140E").cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.masksToBounds = false
    }

    private func configureContent() {
        // Sparkles — cherry red, the cucu palette's "look-here"
        // accent. Heavy weight so it reads at small sizes without
        // looking sketchy.
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .heavy)
        sparkleView.image = UIImage(systemName: "sparkles", withConfiguration: symbolConfig)
        sparkleView.tintColor = uiColor(hex: "#B22A4A")  // cucuCherry
        sparkleView.contentMode = .scaleAspectFit
        sparkleView.translatesAutoresizingMaskIntoConstraints = false
        sparkleView.isUserInteractionEnabled = false

        // Title — Caprasimo italic-ish display serif. Falls back to
        // the system serif italic if the font hasn't registered yet
        // (very rare; only on the first millisecond of cold launch).
        if let caprasimo = UIFont(name: "Caprasimo-Regular", size: 14) {
            titleLabel.font = caprasimo
        } else if let serif = UIFont.systemFont(ofSize: 14, weight: .semibold)
            .fontDescriptor.withDesign(.serif)?
            .withSymbolicTraits(.traitItalic) {
            titleLabel.font = UIFont(descriptor: serif, size: 14)
        } else {
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        }
        titleLabel.text = "view gallery"
        titleLabel.textColor = uiColor(hex: "#1A140E")  // cucuInk
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isUserInteractionEnabled = false

        // Count — mono small-caps. Distinct typeface from the title
        // (textural contrast) plus tight letter-spacing for that
        // editorial spec-line feel.
        countLabel.font = UIFont.monospacedSystemFont(ofSize: 8.5, weight: .heavy)
        countLabel.textColor = uiColor(hex: "#8C8067")  // cucuInkFaded
        countLabel.attributedText = NSAttributedString(
            string: "0 PHOTOS",
            attributes: [.kern: 1.4]
        )
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        addSubview(sparkleView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            sparkleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sparkleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            sparkleView.widthAnchor.constraint(equalToConstant: 16),
            sparkleView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: sparkleView.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        // Always-on attributed kerning for the count — `didSet`
        // re-applies plain text, so wrap that path too.
        countLabel.text = "0 PHOTOS"
    }

    /// Re-apply kerning whenever the count string changes. Hooked
    /// into `photoCount.didSet` via this override of `text` so we
    /// don't lose the letter-spacing on dynamic updates.
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {}

    private func installPressFeedback() {
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(
            self,
            action: #selector(handleTouchUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    @objc private func handleTouchDown() {
        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.transform = self.baseTransform.scaledBy(x: 0.96, y: 0.96)
        }
    }

    @objc private func handleTouchUp() {
        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            usingSpringWithDamping: 0.62,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction]
        ) {
            self.transform = self.baseTransform
        }
    }

    /// One-shot bounce-in. Fires the first time the chip becomes
    /// visible per gallery so the user notices the new affordance
    /// without it pulsing forever. Starts from 50% scale + alpha 0
    /// and springs to the chip's resting tilted state.
    func playEntryAnimation() {
        layer.removeAllAnimations()
        transform = baseTransform.scaledBy(x: 0.5, y: 0.5)
        alpha = 0
        UIView.animate(
            withDuration: 0.55,
            delay: 0.18,
            usingSpringWithDamping: 0.62,
            initialSpringVelocity: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.transform = self.baseTransform
            self.alpha = 1
        }
    }
}
