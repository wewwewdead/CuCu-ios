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

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        textView.delegate = self
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        // While the user is actively typing, don't overwrite their
        // in-flight string with the document version (we'd clobber
        // unsaved keystrokes the moment SwiftUI re-renders for any
        // unrelated reason).
        let incoming = node.content.text ?? ""
        if !textView.isFirstResponder, textView.text != incoming {
            textView.text = incoming
        }

        let size = CGFloat(node.style.fontSize ?? 17)
        switch node.style.fontFamily ?? .system {
        case .system:
            textView.font = .systemFont(ofSize: size)
        case .serif:
            if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
                textView.font = UIFont(descriptor: descriptor, size: size)
            } else {
                textView.font = .systemFont(ofSize: size)
            }
        case .rounded:
            if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded) {
                textView.font = UIFont(descriptor: descriptor, size: size)
            } else {
                textView.font = .systemFont(ofSize: size)
            }
        case .monospaced:
            textView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        if let hex = node.style.textColorHex {
            textView.textColor = uiColor(hex: hex)
        } else {
            textView.textColor = .label
        }

        switch node.style.textAlignment ?? .leading {
        case .leading: textView.textAlignment = .left
        case .center: textView.textAlignment = .center
        case .trailing: textView.textAlignment = .right
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
