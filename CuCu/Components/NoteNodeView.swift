import UIKit

/// Marker subclass so `CanvasEditorView`'s tap handler can detect that
/// a touch landed on the see-more affordance and skip its
/// selection/edit routing — the button has its own action and the
/// canvas would otherwise also fire on the same tap.
///
/// Visual character: cream pill with a 1px ink hairline + soft shadow
/// (matches the editorial chrome of the note card itself), italic
/// Lexend "see more" + trailing arrow that nudges on press. The pill
/// presses + springs back with a haptic blip; first appearance fades
/// + scales in so the affordance feels "discovered" the moment a
/// note overflows, not just rendered.
final class NoteSeeMoreButton: UIButton {
    private let arrowImageView = UIImageView()
    private let titleLbl = UILabel()
    private var hasFiredFirstAppearance = false
    private static let pressFeedback = UIImpactFeedbackGenerator(style: .soft)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configure() {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 4
        layer.cornerRadius = 12
        layer.borderWidth = 0.8
        // The label + arrow live in their own stack so we can animate
        // them independently — the arrow nudges on press while the
        // label keeps its position.
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        arrowImageView.translatesAutoresizingMaskIntoConstraints = false
        arrowImageView.contentMode = .scaleAspectFit
        let stack = UIStackView(arrangedSubviews: [titleLbl, arrowImageView])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    /// Apply theme-driven styling. Called from `apply(node:)` so
    /// per-note text color / font / fill flows through to the pill
    /// and it always reads as part of the note's chrome rather than
    /// generic system UI.
    func applyStyle(font: UIFont, ink: UIColor, fill: UIColor) {
        // Italic variant of the body font for editorial character —
        // marks the pill as a "voice change" from regular body copy.
        let italicDescriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        )
        let italicFont: UIFont = italicDescriptor.map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        titleLbl.text = "see more"
        titleLbl.font = italicFont
        titleLbl.textColor = ink
        titleLbl.numberOfLines = 1

        // Arrow tracks the body font size + ink color so a theme swap
        // (light↔dark, cherry vs ink) reads consistently.
        let arrowConfig = UIImage.SymbolConfiguration(
            pointSize: max(11, italicFont.pointSize - 1),
            weight: .semibold
        )
        arrowImageView.image = UIImage(systemName: "arrow.right", withConfiguration: arrowConfig)?
            .withTintColor(ink, renderingMode: .alwaysOriginal)

        backgroundColor = fill
        layer.borderColor = ink.withAlphaComponent(0.65).cgColor
    }

    /// First-appearance animation. Plays once per pill so a note that
    /// flickers in/out of overflow doesn't keep popping the pill —
    /// only the initial reveal feels like a discovery moment.
    func playFirstAppearanceIfNeeded() {
        guard !hasFiredFirstAppearance else { return }
        hasFiredFirstAppearance = true
        transform = CGAffineTransform(scaleX: 0.6, y: 0.6).rotated(by: -0.04)
        alpha = 0
        UIView.animate(withDuration: 0.42,
                       delay: 0.04,
                       usingSpringWithDamping: 0.62,
                       initialSpringVelocity: 0.5,
                       options: [.allowUserInteraction]) {
            self.transform = .identity
            self.alpha = 1
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            if isHighlighted {
                Self.pressFeedback.prepare()
            } else {
                Self.pressFeedback.impactOccurred(intensity: 0.6)
            }
            UIView.animate(withDuration: 0.22,
                           delay: 0,
                           usingSpringWithDamping: 0.68,
                           initialSpringVelocity: 0.4,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.94, y: 0.94)
                    : .identity
                self.arrowImageView.transform = self.isHighlighted
                    ? CGAffineTransform(translationX: 3, y: 0)
                    : .identity
            }
        }
    }
}

/// Renders a note card. Three stacked rows — title (with a corner expand
/// glyph), timestamp (with a leading clock symbol), and a multi-line body
/// — sit inside the chrome (fill / border / radius) drawn by
/// `NodeRenderView`.
///
/// Body is a `UITextView` so the canvas can drop the user directly into
/// in-place editing on a tap (same lifecycle as `TextNodeView`):
/// `isUserInteractionEnabled = false` by default lets touches fall
/// through to the canvas; `beginBodyEditing()` flips it on, grabs first
/// responder, and drives `onBodyTextChanged` / `onBodyEditingEnded` so
/// the host can mirror keystrokes and commit.
///
/// Title and timestamp stay as labels — they're edited from the
/// inspector panel, since they're short enough that a free-form
/// keyboard surface would be more friction than help.
///
/// Typography: a single `style.fontSize` drives derived sizes for all
/// three rows so the inspector stays simple — title at ×1.4 (bold),
/// timestamp at ×0.8 (regular, dimmed), body at ×1.0. The same
/// `style.textColorHex` colors all three; timestamp gets a fixed alpha
/// reduction so users only ever pick one ink color for the card.
final class NoteNodeView: NodeRenderView, UITextViewDelegate {
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 1
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.6
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private let expandGlyph: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        return v
    }()

    private let clockGlyph: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.image = UIImage(systemName: "clock")
        return v
    }()

    private let timestampLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    /// Body lives in a `UITextView` (not a `UILabel`) so the canvas can
    /// drop the user directly into in-place editing on a second tap —
    /// same trick `TextNodeView` uses. See `beginBodyEditing(at:)`.
    private let bodyTextView: UITextView = {
        let t = UITextView()
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isScrollEnabled = false
        t.isEditable = true
        t.isSelectable = true
        // Touches pass through until the canvas calls `beginBodyEditing`,
        // matching `TextNodeView`'s gating. Without this, a tap on the
        // body would land on the textView and the canvas's tap recognizer
        // (selection / chip presentation) would never fire.
        t.isUserInteractionEnabled = false
        t.backgroundColor = .clear
        t.textContainerInset = .zero
        t.textContainer.lineFragmentPadding = 0
        return t
    }()

    private let stack: UIStackView = {
        let s = UIStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.alignment = .fill
        s.distribution = .fill
        return s
    }()

    /// "see more" pill that appears at the body's bottom-right corner
    /// when the body's content overflows its visible bounds and the
    /// user isn't actively editing. Background matches the card fill
    /// so it masks any text the truncation cuts through underneath.
    private let seeMoreButton: NoteSeeMoreButton = {
        let b = NoteSeeMoreButton(frame: .zero)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.alpha = 0
        b.isHidden = true
        return b
    }()

    private var paddingConstraints: [NSLayoutConstraint] = []
    private var seeMorePositionConstraints: [NSLayoutConstraint] = []
    /// Cached so `layoutSubviews` knows what fill color to mask the
    /// truncation seam with when typography / theme changes.
    private var cachedFillColor: UIColor = .white
    private var cachedBodyFont: UIFont = .systemFont(ofSize: 15)
    private var cachedInkColor: UIColor = .label

    /// Wired only in the published profile (viewer mode). When non-nil,
    /// a tap on the card asks the host to present the full note body
    /// in a sheet — same shape as `GalleryNodeView.onViewAll`.
    var onTap: (() -> Void)?

    /// Wired in both editor and viewer modes. Fires when the user taps
    /// the inline "see more" pill that surfaces when body text is
    /// truncated. Same destination as `onTap` in the viewer (the full
    /// expand modal) — keeps overflow discoverable while editing too,
    /// since `apply(node:)` re-runs after every keystroke can hide a
    /// chunk of body that would otherwise scroll out of view.
    var onSeeMoreTapped: (() -> Void)?

    /// Live keystroke mirror — fires on every change to the body text.
    /// Wired by `CanvasEditorView.makeRenderView` so the in-memory
    /// document stays in sync without a SwiftData write per keystroke.
    var onBodyTextChanged: ((String) -> Void)?

    /// Fires once when body editing finishes (resign first responder).
    /// Host uses this to persist.
    var onBodyEditingEnded: (() -> Void)?

    /// Tap recognizer used in viewer mode for the expand sheet. Held so
    /// we can disable it during editing (where it would otherwise steal
    /// the cursor-placement tap).
    private var publishedTapRecognizer: UITapGestureRecognizer?

    /// Mirrors `CanvasEditorView.editMode`. The see-more pill is
    /// suppressed while edit mode is on — the dashed chrome + chips
    /// already convey that the card is editable, and a competing
    /// affordance there reads as noise. Set by the host when the
    /// edit-mode toggle flips.
    var isCanvasEditMode: Bool = false {
        didSet {
            guard oldValue != isCanvasEditMode else { return }
            setNeedsLayout()
        }
    }

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)

        let titleRow = UIStackView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 6
        titleRow.addArrangedSubview(titleLabel)
        let titleSpacer = UIView()
        titleSpacer.translatesAutoresizingMaskIntoConstraints = false
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(titleSpacer)
        titleRow.addArrangedSubview(expandGlyph)

        let timestampRow = UIStackView()
        timestampRow.translatesAutoresizingMaskIntoConstraints = false
        timestampRow.axis = .horizontal
        timestampRow.alignment = .center
        timestampRow.spacing = 6
        timestampRow.addArrangedSubview(clockGlyph)
        timestampRow.addArrangedSubview(timestampLabel)
        let tsSpacer = UIView()
        tsSpacer.translatesAutoresizingMaskIntoConstraints = false
        tsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timestampRow.addArrangedSubview(tsSpacer)

        stack.addArrangedSubview(titleRow)
        stack.setCustomSpacing(6, after: titleRow)
        stack.addArrangedSubview(timestampRow)
        stack.setCustomSpacing(8, after: timestampRow)
        stack.addArrangedSubview(bodyTextView)

        // Title + timestamp keep their intrinsic heights; the body
        // absorbs the slack so when content is short it stretches and
        // when content is long it can scroll within fixed bounds. Without
        // these priorities the stack ambiguously distributes the extra
        // space and the title row drifts off the card's top edge mid-
        // edit (autolayout breaking the top anchor to satisfy a bottom
        // constraint).
        titleRow.setContentHuggingPriority(.required, for: .vertical)
        timestampRow.setContentHuggingPriority(.required, for: .vertical)
        bodyTextView.setContentHuggingPriority(.defaultLow, for: .vertical)
        bodyTextView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addSubview(stack)
        applyPadding(16)

        // See-more is a sibling of the body inside `self`, NOT a
        // subview of `bodyTextView`. Two reasons:
        //   1. `bodyTextView.isUserInteractionEnabled = false` while
        //      idle — a button nested inside it would never receive
        //      taps. The body's gating is what lets canvas selection
        //      / drag work, so we can't just flip it on.
        //   2. UITextView is a UIScrollView under the hood; subviews
        //      track contentSize, not visible bounds, so the pill
        //      would scroll out of view as soon as content overflowed.
        // Pinning to the body's anchors via Auto Layout still places
        // the pill at the visible bottom-right corner of the body row.
        addSubview(seeMoreButton)
        seeMoreButton.addTarget(self, action: #selector(handleSeeMore), for: .touchUpInside)
        seeMorePositionConstraints = [
            seeMoreButton.trailingAnchor.constraint(equalTo: bodyTextView.trailingAnchor),
            seeMoreButton.bottomAnchor.constraint(equalTo: bodyTextView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(seeMorePositionConstraints)

        bodyTextView.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        // CRITICAL: leave touches alive in the touched view. Default
        // `cancelsTouchesInView = true` would cancel the see-more
        // button's touch sequence the moment the gesture recognizer
        // detected a tap, so UIControl's `.touchUpInside` would never
        // fire — the button would look tappable but do nothing.
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        publishedTapRecognizer = tap
    }

    @objc private func handleSeeMore() {
        onSeeMoreTapped?()
    }

    @objc private func handleTap() {
        onTap?()
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        let inkHex = node.style.textColorHex ?? "#1A140E"
        let inkColor = uiColor(hex: inkHex)
        let baseSize = CGFloat(node.style.fontSize ?? 15)
        let family = node.style.fontFamily ?? .system

        titleLabel.text = node.content.noteTitle ?? "Notes"
        titleLabel.textColor = inkColor
        titleLabel.font = family.uiFont(size: baseSize * 1.4, weight: .bold)

        timestampLabel.text = node.content.noteTimestamp ?? ""
        timestampLabel.textColor = inkColor.withAlphaComponent(0.6)
        timestampLabel.font = family.uiFont(size: max(11, baseSize * 0.8))

        clockGlyph.tintColor = inkColor.withAlphaComponent(0.6)
        clockGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: max(11, baseSize * 0.8),
            weight: .regular
        )

        expandGlyph.tintColor = inkColor
        expandGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: max(12, baseSize * 0.9),
            weight: .semibold
        )

        let body = node.content.text ?? ""
        let bodyFont = family.uiFont(size: baseSize)
        // Avoid clobbering the live `UITextView` text while the user is
        // typing — `apply(node:)` re-runs on every document update, and
        // overwriting `text` mid-edit would yank the cursor and replace
        // each freshly-typed character. Same guard `TextNodeView` applies.
        if !bodyTextView.isFirstResponder, bodyTextView.text != body {
            bodyTextView.text = body
        }
        bodyTextView.font = bodyFont
        bodyTextView.textColor = inkColor
        bodyTextView.typingAttributes = [
            .font: bodyFont,
            .foregroundColor: inkColor,
        ]

        // See-more pill: italic display variant of the body font for
        // editorial character. Background tracks the card's fill so
        // the pill reads as part of the chrome (and cleanly masks any
        // wrapped word the truncation slices through underneath).
        cachedBodyFont = bodyFont
        cachedInkColor = inkColor
        cachedFillColor = node.style.backgroundColorHex.map(uiColor(hex:)) ?? .white
        seeMoreButton.applyStyle(font: bodyFont, ink: inkColor, fill: cachedFillColor)

        applyPadding(CGFloat(node.style.padding ?? 16))
        setNeedsLayout()
        // Belt-and-braces overflow probe: viewer mode fires only a
        // handful of layout passes after mount, so a stale `bounds == 0`
        // read on the first pass would leave the pill hidden forever.
        // Deferring to the next runloop tick guarantees the textView
        // has finished its own internal layout before we measure.
        DispatchQueue.main.async { [weak self] in
            self?.updateSeeMoreVisibility()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSeeMoreVisibility()
    }

    /// Show the pill when the body's natural content is taller than
    /// the visible body height, and the user isn't actively editing
    /// (where the cursor + inline scroll already convey overflow).
    private func updateSeeMoreVisibility() {
        // Force the textView's own layout to settle before we read
        // its bounds — without this, `bounds.height` can still be 0
        // on the first pass under viewer-mode rendering.
        bodyTextView.layoutIfNeeded()
        let visibleHeight = bodyTextView.bounds.height
        guard visibleHeight > 0 else { return }
        // `sizeThatFits` computes the natural height authoritatively;
        // `contentSize` can be stale during the first layout pass and
        // would leave the pill hidden on a freshly-decoded note.
        let fittingSize = bodyTextView.sizeThatFits(CGSize(
            width: bodyTextView.bounds.width,
            height: .greatestFiniteMagnitude
        ))
        let hasOverflow = fittingSize.height > visibleHeight + 1
        // Hide while the canvas is in edit mode (the per-node chrome is
        // already telling the user the card is editable), or while the
        // body itself is being typed into (cursor + inline scroll
        // already convey overflow).
        let shouldShow = hasOverflow && !bodyTextView.isFirstResponder && !isCanvasEditMode
        if shouldShow {
            let wasHidden = seeMoreButton.isHidden || seeMoreButton.alpha < 0.99
            seeMoreButton.isHidden = false
            seeMoreButton.alpha = 1
            bringSubviewToFront(seeMoreButton)
            // Spring + fade in the pill the first time overflow is
            // detected. Subsequent edit ↔ idle flips skip the animation
            // (the pill already lives there) — only the discovery
            // moment gets the delight.
            if wasHidden {
                seeMoreButton.playFirstAppearanceIfNeeded()
            }
        } else {
            seeMoreButton.alpha = 0
            seeMoreButton.isHidden = true
        }
    }

    private func applyPadding(_ pad: CGFloat) {
        if !paddingConstraints.isEmpty {
            NSLayoutConstraint.deactivate(paddingConstraints)
        }
        // All four edges pinned with equal-to so the stack always fills
        // the card. The body's lower vertical hugging / compression
        // priority means it's the row that gets resized when the card
        // changes height — title + timestamp keep their intrinsic
        // heights, the body absorbs slack or compresses + scrolls.
        paddingConstraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ]
        NSLayoutConstraint.activate(paddingConstraints)
    }

    // MARK: - Edit lifecycle (body only)

    /// Drop the user into in-place body editing. Mirrors
    /// `TextNodeView.beginEditing(at:)` — flips the textView to
    /// interactive, grabs first responder, and places the cursor at
    /// the tap point (or end-of-text when no point is given).
    func beginBodyEditing(at point: CGPoint? = nil) {
        bodyTextView.isUserInteractionEnabled = true
        bodyTextView.isScrollEnabled = true
        // Suspend the published-mode tap so it doesn't steal cursor
        // placement / selection drags while editing. Re-enabled on end.
        publishedTapRecognizer?.isEnabled = false
        bodyTextView.becomeFirstResponder()
        if let point {
            let textPoint = convert(point, to: bodyTextView)
            if let position = bodyTextView.closestPosition(to: textPoint) {
                let offset = bodyTextView.offset(from: bodyTextView.beginningOfDocument, to: position)
                let length = (bodyTextView.text as NSString).length
                let clamped = max(0, min(offset, length))
                bodyTextView.selectedRange = NSRange(location: clamped, length: 0)
            }
        } else {
            let end = (bodyTextView.text as NSString).length
            bodyTextView.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func endBodyEditing() {
        bodyTextView.resignFirstResponder()
    }

    var isBodyEditing: Bool { bodyTextView.isFirstResponder }

    /// In-flight body text from the live UITextView while editing. Same
    /// shape as `TextNodeView.liveText` so the host can merge unsaved
    /// keystrokes when a stale document push arrives mid-edit.
    var liveBodyText: String { bodyTextView.text ?? "" }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        onBodyTextChanged?(textView.text)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isUserInteractionEnabled = false
        textView.isScrollEnabled = false
        publishedTapRecognizer?.isEnabled = true
        onBodyEditingEnded?()
        // Re-probe overflow now that the body is back to its
        // non-scrolling display state — the see-more pill should
        // reappear if the post-edit content still overflows.
        setNeedsLayout()
    }
}
