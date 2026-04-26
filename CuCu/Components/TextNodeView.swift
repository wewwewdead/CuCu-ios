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
        addSubview(textView)
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
        let font = family.uiFont(size: size, weight: weight)
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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]

        // 2. Apply the attributed text. Skipped while the user is
        //    actively editing the in-place text view so we don't
        //    clobber an in-flight string. New keystrokes pick up the
        //    current attributes via `typingAttributes` below — that's
        //    the standard UITextView pattern for "the inspector
        //    changed font / line spacing while the keyboard is up".
        let incoming = node.content.text ?? ""
        if !textView.isFirstResponder {
            textView.attributedText = NSAttributedString(string: incoming, attributes: attrs)
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
