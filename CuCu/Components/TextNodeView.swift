import UIKit

private struct TextRenderSignature: Equatable {
    var text: String
    var spans: [TextStyleSpan]?
    var fontFamily: NodeFontFamily
    var fontWeight: NodeFontWeight
    var fontSize: Double
    var textColorHex: String?
    var textAlignment: NodeTextAlignment
    var textUnderlined: Bool
    var textItalic: Bool
    var textStrikethrough: Bool
    var letterSpacing: Double?
    var lineSpacing: Double
}

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
        // no scroll, transparent background.
        //
        // `isEditable` and `isSelectable` stay TRUE for the life of the
        // view. Toggling them off→on is what causes UIKit to internally
        // call `setText` over its `textStorage` using the view's own
        // `textColor` / `font` properties, which destructively flattens
        // any range-level foregroundColor / backgroundColor attributes
        // (the inline color + highlight spans). Keeping the editor in
        // "editable" mode permanently means UIKit never runs that
        // transition, so the spans survive across editing sessions.
        //
        // Touch routing is controlled by `isUserInteractionEnabled`
        // instead: false in the static display state so taps fall
        // through to the canvas (which handles tap-to-edit), true once
        // the canvas escalates to inline editing via `beginEditing`.
        t.isScrollEnabled = false
        t.isEditable = true
        t.isSelectable = true
        t.isUserInteractionEnabled = false
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
    /// Reports the current UTF-16 selection range while the text view
    /// owns editing. Collapsed selections are still reported; the SwiftUI
    /// host decides whether to treat them as "no selected text".
    var onSelectionRangeChanged: ((NSRange) -> Void)?

    /// Snapshot of the node's base typing attributes (font, base color,
    /// paragraph style). Re-asserted on selection / text change so the
    /// caret never inherits the inline `.foregroundColor` /
    /// `.backgroundColor` of an adjacent styled span — newly typed
    /// characters always start in the node's base style. Inline color
    /// or highlight is only ever applied through an explicit user span,
    /// never as a typing carry-over.
    private var baseTypingAttributes: [NSAttributedString.Key: Any] = [:]
    private var lastTextRenderSignature: TextRenderSignature?

    #if DEBUG
    nonisolated(unsafe) static var attributedTextRebuildCount: Int = 0
    static func resetAttributedTextRebuildCount() {
        attributedTextRebuildCount = 0
    }
    #endif

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

        // 1. Apply the attributed text. Source-of-truth for the string
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
        let signature = textRenderSignature(node: node, text: incoming)
        if signature != lastTextRenderSignature {
            rebuildAttributedText(node: node, text: incoming, savedSelection: savedSelection)
            lastTextRenderSignature = signature
        }

        // 2. Apply padding. `nil` falls back to the historical
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

        // 3. Backdrop blur. Quadratic alpha ramp matches the
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
    func beginEditing(at point: CGPoint? = nil, selectingWord: Bool = false) {
        // Light up touch routing on the text view so the user's
        // subsequent taps land on UITextView (cursor placement, word
        // select, drag-select) instead of falling through to the
        // canvas. `becomeFirstResponder` only succeeds when
        // interaction is enabled, so the order matters.
        textView.isUserInteractionEnabled = true
        // Scroll on while editing so the cursor stays visible if the
        // user types past the node's visible bounds. Off again on end
        // so the static display matches a label.
        textView.isScrollEnabled = true
        textView.becomeFirstResponder()
        if let point {
            updateSelection(at: point, selectingWord: selectingWord)
        } else {
            // Place cursor at the end so a quick tap-and-type adds rather
            // than overwrites.
            let end = ((textView.text ?? "") as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
            onSelectionRangeChanged?(textView.selectedRange)
        }
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
        // After every keystroke, force the next-character attributes
        // back to the node's base style. UIKit otherwise leaves the
        // inline color / highlight from the just-typed character on
        // `typingAttributes`, which made the formatting "stick" on
        // every subsequent keystroke.
        if !baseTypingAttributes.isEmpty {
            textView.typingAttributes = baseTypingAttributes
        }
        onTextChanged?(textView.text)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // When the caret is collapsed (cursor only, no selection), strip
        // the auto-inherited attributes UIKit copies from the surrounding
        // glyphs. This is what stops a cursor placed at the end of (or
        // inside) a colored / highlighted span from carrying that style
        // into the next typed character. Non-empty selections are left
        // alone so a "type to replace" still inherits sensibly.
        if textView.selectedRange.length == 0,
           !baseTypingAttributes.isEmpty {
            textView.typingAttributes = baseTypingAttributes
        }
        onSelectionRangeChanged?(textView.selectedRange)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        // Hand touches back to the canvas so the next tap can route
        // through the canvas's tap recognizer (selection / chip / etc.).
        // `isEditable` / `isSelectable` deliberately stay true — see
        // the textView initializer comment for why we don't toggle
        // those.
        textView.isUserInteractionEnabled = false
        textView.isScrollEnabled = false
        onEditingEnded?()
    }

    private func updateSelection(at point: CGPoint, selectingWord: Bool) {
        let textPoint = convert(point, to: textView)
        guard let position = textView.closestPosition(to: textPoint) else {
            let end = ((textView.text ?? "") as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
            onSelectionRangeChanged?(textView.selectedRange)
            return
        }

        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        let textLength = ((textView.text ?? "") as NSString).length
        let clampedOffset = max(0, min(offset, textLength))
        if selectingWord,
           let wordRange = wordRange(containing: clampedOffset) {
            textView.selectedRange = wordRange
        } else {
            textView.selectedRange = NSRange(location: clampedOffset, length: 0)
        }
        onSelectionRangeChanged?(textView.selectedRange)
    }

    private func wordRange(containing utf16Offset: Int) -> NSRange? {
        let nsText = (textView.text ?? "") as NSString
        let length = nsText.length
        guard length > 0 else { return nil }

        let separators = CharacterSet.whitespacesAndNewlines
        let seed = max(0, min(utf16Offset, length - 1))
        guard !isSeparator(at: seed, in: nsText, separators: separators) else {
            return nil
        }

        var start = seed
        while start > 0,
              !isSeparator(at: start - 1, in: nsText, separators: separators) {
            start -= 1
        }

        var end = seed
        while end < length,
              !isSeparator(at: end, in: nsText, separators: separators) {
            end += 1
        }

        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func isSeparator(at index: Int, in text: NSString, separators: CharacterSet) -> Bool {
        guard index >= 0, index < text.length,
              let scalar = UnicodeScalar(UInt32(text.character(at: index))) else {
            return false
        }
        return separators.contains(scalar)
    }

    private func textRenderSignature(node: CanvasNode, text: String) -> TextRenderSignature {
        TextRenderSignature(
            text: text,
            spans: node.content.textStyleSpans,
            fontFamily: node.style.fontFamily ?? .system,
            fontWeight: node.style.fontWeight ?? .regular,
            fontSize: node.style.fontSize ?? 17,
            textColorHex: node.style.textColorHex,
            textAlignment: node.style.textAlignment ?? .leading,
            textUnderlined: node.style.textUnderlined == true,
            textItalic: node.style.textItalic == true,
            textStrikethrough: node.style.textStrikethrough == true,
            letterSpacing: node.style.letterSpacing,
            lineSpacing: max(node.style.lineSpacing ?? 0, 0)
        )
    }

    private func rebuildAttributedText(node: CanvasNode,
                                       text incoming: String,
                                       savedSelection: NSRange?) {
        let size = CGFloat(node.style.fontSize ?? 17)
        let baseWeight = node.style.fontWeight ?? .regular
        let family = node.style.fontFamily ?? .system
        let italicEnabled = node.style.textItalic == true
        let fontResolution = family.cachedUIFont(
            size: size,
            weight: baseWeight.uiFontWeight,
            italic: italicEnabled
        )
        let font = fontResolution.font
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
        if fontResolution.obliqueness != 0 {
            attrs[.obliqueness] = fontResolution.obliqueness
        }

        // Keep these UIKit properties in sync for empty-text editing
        // and system insertion behavior, but set them before assigning
        // `attributedText`. Setting `textColor` / `font` afterwards can
        // cause UITextView to restyle the full string and visually wipe
        // range-level foreground-color spans.
        textView.font = font
        textView.textColor = textColor
        textView.textAlignment = alignment

        let attributed = NSMutableAttributedString(string: incoming, attributes: attrs)
        applyInlineSpans(
            node.content.textStyleSpans,
            family: family,
            size: size,
            baseWeight: baseWeight,
            baseItalic: italicEnabled,
            to: attributed
        )
        textView.attributedText = attributed
        if let savedSelection {
            textView.selectedRange = savedSelection
        }
        baseTypingAttributes = attrs
        textView.typingAttributes = attrs
        #if DEBUG
        Self.attributedTextRebuildCount &+= 1
        #endif
    }

    private func applyInlineSpans(_ spans: [TextStyleSpan]?,
                                  family: NodeFontFamily,
                                  size: CGFloat,
                                  baseWeight: NodeFontWeight,
                                  baseItalic: Bool,
                                  to attributed: NSMutableAttributedString) {
        let textLength = attributed.length
        guard textLength > 0 else { return }

        for span in spans ?? [] {
            guard let range = clampedRange(for: span, textLength: textLength) else {
                continue
            }
            if let hex = span.textColorHex,
               let color = uiColorIfValid(hex: hex) {
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            }
            if let hex = span.highlightColorHex,
               let color = uiColorIfValid(hex: hex) {
                attributed.addAttribute(.backgroundColor, value: color, range: range)
            }
            // A span re-emits the font when ANY of bold / italic /
            // fontFamily is set on it, because the resolved UIFont
            // mixes all three. The unset axes fall back to the
            // node-level base (`baseWeight`, `baseItalic`, `family`)
            // so a span that only changes fontFamily keeps the
            // surrounding bold/italic state.
            if span.bold == true || span.italic == true || span.fontFamily != nil {
                attributed.addAttributes(
                    fontAttributes(
                        family: span.fontFamily ?? family,
                        size: size,
                        weight: span.bold == true ? .bold : baseWeight,
                        italic: baseItalic || span.italic == true
                    ),
                    range: range
                )
            }
            if span.underline == true {
                attributed.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }
    }

    private func fontAttributes(family: NodeFontFamily,
                                size: CGFloat,
                                weight: NodeFontWeight,
                                italic: Bool) -> [NSAttributedString.Key: Any] {
        let resolved = family.cachedUIFont(
            size: size,
            weight: weight.uiFontWeight,
            italic: italic
        )
        guard resolved.obliqueness != 0 else { return [.font: resolved.font] }
        return [.font: resolved.font, .obliqueness: resolved.obliqueness]
    }

    private func clampedRange(for span: TextStyleSpan, textLength: Int) -> NSRange? {
        guard span.start >= 0,
              span.length > 0,
              span.start < textLength else {
            return nil
        }
        let (rawEnd, overflow) = span.start.addingReportingOverflow(span.length)
        let end = min(textLength, overflow ? textLength : rawEnd)
        let length = max(0, end - span.start)
        guard length > 0 else { return nil }
        return NSRange(location: span.start, length: length)
    }

    private func uiColorIfValid(hex: String) -> UIColor? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard [3, 6, 8].contains(cleaned.count),
              UInt64(cleaned, radix: 16) != nil else {
            return nil
        }
        return uiColor(hex: hex)
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
