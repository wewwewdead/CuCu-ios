import UIKit

/// Renders (and edits) a text node. Uses a `UITextView` so the same view
/// can both display the formatted string and become the editing surface
/// when the user taps the already-selected node — no swapping subviews,
/// no reflow.
///
/// Editing flow:
/// 1. `isEditable` / `isSelectable` are `false` by default so the view
///    doesn't intercept touches and the canvas's pan / tap recognizers
///    work as normal.
/// 2. `beginEditing()` flips both to `true` and grabs first responder —
///    keyboard appears with the cursor placed at the tap location.
/// 3. As the user types, `textViewDidChange` fires `onTextChanged` so
///    `CanvasEditorView` can mirror keystrokes into the document
///    (without persisting to SwiftData on every character).
/// 4. `endEditing()` (or losing first responder for any reason)
///    resigns the keyboard, restores the non-editable state, and fires
///    `onEditingEnded` so the host can commit once.
final class TextNodeView: NodeRenderView, UITextViewDelegate {
    private let textView: UITextView = {
        let t = UITextView()
        t.translatesAutoresizingMaskIntoConstraints = false
        // Defaults match a UILabel-style display: no internal padding,
        // no scroll, transparent background, not editable.
        t.isScrollEnabled = false
        t.isEditable = false
        t.isSelectable = false
        t.backgroundColor = .clear
        t.textContainerInset = .zero
        t.textContainer.lineFragmentPadding = 0
        return t
    }()

    /// Backdrop-filter blur drawn behind the text glyphs. Mirrors the
    /// pattern in `ContainerNodeView` — a `UIVisualEffectView` with
    /// `.systemUltraThinMaterial` sits at the back of this view's
    /// subview stack and samples whatever is rendered behind the node
    /// on the canvas. Alpha ramps in from `style.textBackdropBlur`.
    /// `isUserInteractionEnabled = false` so taps still fall through
    /// to the textView (and its single-tap-to-edit behavior) on top.
    private let blurOverlay: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()

    /// Fired on every keystroke so the document can stay in sync with
    /// the textView's content. The host must NOT trigger SwiftData
    /// commits here — that's what `onEditingEnded` is for.
    var onTextChanged: ((String) -> Void)?
    /// Fired once when editing finishes (return key, lose focus,
    /// programmatic `endEditing()`). Host persists here.
    var onEditingEnded: (() -> Void)?

    /// Padding constraints stored as members so `apply(node:)` can
    /// drive their constants from `node.style.padding`. Initial
    /// values match the historical defaults (4pt horizontal /
    /// 2pt vertical) which keeps drafts that predate the inspector
    /// "Padding" slider visually unchanged.
    private var leadingPadding: NSLayoutConstraint!
    private var trailingPadding: NSLayoutConstraint!
    private var topPadding: NSLayoutConstraint!
    private var bottomPadding: NSLayoutConstraint!

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        textView.delegate = self
        // Blur sits at the back of the subview stack so the text
        // renders sharp on top of the frosted backdrop. Pinned to the
        // node's bounds so the layer's corner radius / clip
        // (configured by the base class) crops the blur correctly.
        addSubview(blurOverlay)
        addSubview(textView)
        NSLayoutConstraint.activate([
            blurOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurOverlay.topAnchor.constraint(equalTo: topAnchor),
            blurOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        leadingPadding = textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        trailingPadding = textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        topPadding = textView.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        bottomPadding = textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        NSLayoutConstraint.activate([leadingPadding, trailingPadding, topPadding, bottomPadding])
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        // 1. Resolve every styling input up front so the attributed
        //    string + the typingAttributes path agree on the same
        //    values. Resolution lives in `NodeFontFamilyResolver` so
        //    every text site (canvas + viewer + previews) speaks the
        //    same family→UIFont logic.
        let size = CGFloat(node.style.fontSize ?? 17)
        let weight = (node.style.fontWeight ?? .regular).uiFontWeight
        let family = node.style.fontFamily ?? .system
        let baseFont = family.uiFont(size: size, weight: weight)
        // Italic toggle: prefer the family's real italic face (looks
        // hand-drawn, kerning baked in). Fall back to obliqueness so
        // pixel-retro / bungee-style families that ship without an
        // italic face still slant — the inspector toggle never reads
        // as a no-op.
        let italicEnabled = node.style.textItalic == true
        let font: UIFont
        var fallbackObliqueness: CGFloat = 0
        if italicEnabled,
           let italicDescriptor = baseFont.fontDescriptor.withSymbolicTraits(
               baseFont.fontDescriptor.symbolicTraits.union(.traitItalic)
           ) {
            font = UIFont(descriptor: italicDescriptor, size: size)
        } else {
            font = baseFont
            if italicEnabled { fallbackObliqueness = 0.18 }
        }
        let textColor: UIColor = node.style.textColorHex.map(uiColor(hex:)) ?? .label

        let alignment: NSTextAlignment
        switch node.style.textAlignment ?? .leading {
        case .leading:  alignment = .left
        case .center:   alignment = .center
        case .trailing: alignment = .right
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = max(CGFloat(node.style.lineSpacing ?? 0), 0)

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        if node.style.textUnderlined == true {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if node.style.textStrikethrough == true {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = textColor
        }
        if let kern = node.style.letterSpacing, kern != 0 {
            attrs[.kern] = CGFloat(kern)
        }
        if fallbackObliqueness != 0 {
            attrs[.obliqueness] = fallbackObliqueness
        }

        // 2. Apply the attributed text. Source-of-truth for the string
        //    differs by edit state:
        //    - Not editing: pull `node.content.text` (last committed).
        //    - Editing: pull `textView.text` (in-flight keystrokes), so
        //      we re-style the user's typed glyphs without overwriting
        //      them with a stale committed value. The cursor/selection
        //      is preserved so the keyboard interaction stays smooth.
        //    Either way the attributes are re-applied, which is what
        //    makes inspector toggles (underline, font, color, alignment,
        //    line spacing) update live while the keyboard is up.
        let incoming: String
        let savedSelection: NSRange?
        if textView.isFirstResponder {
            incoming = textView.text ?? ""
            savedSelection = textView.selectedRange
        } else {
            incoming = node.content.text ?? ""
            savedSelection = nil
        }
        textView.attributedText = NSAttributedString(string: incoming, attributes: attrs)
        if let savedSelection {
            textView.selectedRange = savedSelection
        }
        textView.typingAttributes = attrs

        // The legacy property setters still matter for empty-text
        // placeholder rendering, focus rings, and the few UIKit
        // surfaces that read these directly instead of attributedText.
        textView.font = font
        textView.textColor = textColor
        textView.textAlignment = alignment

        // 3. Apply padding. `nil` falls back to the historical
        //    4pt-horizontal / 2pt-vertical split so drafts that
        //    predate the inspector slider keep their look. A set
        //    value (including 0) drives uniform padding on all four
        //    sides.
        if let p = node.style.padding {
            let pad = CGFloat(p)
            leadingPadding.constant = pad
            trailingPadding.constant = -pad
            topPadding.constant = pad
            bottomPadding.constant = -pad
        } else {
            leadingPadding.constant = 4
            trailingPadding.constant = -4
            topPadding.constant = 2
            bottomPadding.constant = -2
        }

        // 4. Backdrop blur. Quadratic alpha ramp matches the
        //    container path so the slider has the same gentle low-end
        //    feel — slider 0.1 → alpha 0.01, 0.5 → 0.25, 1.0 → 1.0.
        //    When blur > 0 we clear the node's own background fill
        //    (which `super.apply` just set from `backgroundColorHex`)
        //    so the frosted glass actually shows through instead of
        //    being painted over by an opaque color. The bg color is
        //    re-applied on the next pass when the slider is dialed
        //    back to 0 because `super.apply` runs every call.
        let textBlur = max(0, min(1, node.style.textBackdropBlur ?? 0))
        blurOverlay.alpha = CGFloat(textBlur * textBlur)
        if textBlur > 0.01 {
            backgroundColor = .clear
        }
        // Re-anchor at the back in case any subview reorder happened
        // outside this view's control. Cheap; a no-op if already at
        // index 0.
        sendSubviewToBack(blurOverlay)
    }

    // MARK: - Edit lifecycle

    /// Enter edit mode. The keyboard appears; UITextView starts
    /// claiming touches so the user can place the cursor / drag a
    /// selection inside its bounds (which means dragging the node is
    /// suspended for the duration — tap outside to commit and reclaim
    /// the move gesture).
    func beginEditing() {
        textView.isEditable = true
        textView.isSelectable = true
        // Scroll on while editing so the cursor stays visible if the
        // user types past the node's visible bounds. Off again on end
        // so the static display matches a label.
        textView.isScrollEnabled = true
        textView.becomeFirstResponder()
        // Place cursor at the end so a quick tap-and-type adds rather
        // than overwrites.
        let end = textView.text.count
        textView.selectedRange = NSRange(location: end, length: 0)
    }

    /// Leave edit mode programmatically. Safe to call when not
    /// editing — UITextView ignores the resign request.
    func endEditing() {
        textView.resignFirstResponder()
    }

    var isEditing: Bool { textView.isFirstResponder }

    /// In-flight text from the live `UITextView` while the keyboard is
    /// up. UIKit holds the source-of-truth string during edit; the
    /// in-memory document only receives keystrokes via `onTextChanged`.
    /// Exposed so the canvas host can re-merge unsaved keystrokes when
    /// a SwiftUI binding (e.g. the inspector panel) pushes a stale-text
    /// document back through `apply(document:)` mid-edit.
    var liveText: String { textView.text ?? "" }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        onTextChanged?(textView.text)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        onEditingEnded?()
    }
}

private extension NodeFontWeight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}
