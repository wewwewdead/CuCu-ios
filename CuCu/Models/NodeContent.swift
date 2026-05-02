import Foundation

/// Inline styling for a UTF-16 range inside a text node's `content.text`.
///
/// Ranges intentionally use UTF-16 offsets/lengths because UIKit's
/// `UITextView.selectedRange` speaks `NSRange`, not Swift `String.Index`.
/// The canvas stores plain JSON values only; renderers turn these spans into
/// attributed-string attributes at paint time.
struct TextStyleSpan: Codable, Hashable, Identifiable {
    var id: UUID
    var start: Int
    var length: Int
    var textColorHex: String?
    var highlightColorHex: String?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?

    init(id: UUID = UUID(),
         start: Int,
         length: Int,
         textColorHex: String? = nil,
         highlightColorHex: String? = nil,
         bold: Bool? = nil,
         italic: Bool? = nil,
         underline: Bool? = nil) {
        self.id = id
        self.start = start
        self.length = length
        self.textColorHex = textColorHex
        self.highlightColorHex = highlightColorHex
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

/// Per-type payload for a node. All fields optional so old drafts decode
/// cleanly when a new field is added (no migration needed).
///
/// Currently meaningful fields per type:
/// - `.text`     → `text`, optional `textStyleSpans`
/// - `.image`    → `localImagePath` (relative path under `LocalCanvasAssetStore`)
/// - `.container`→ none
/// - `.icon`     → `iconName` (SF Symbol identifier), optional `text` (label)
/// - `.divider`  → none (style only)
/// - `.link`     → `text` (visible title), `url` (destination)
/// - `.gallery`  → `imagePaths` (ordered list of relative paths)
struct NodeContent: Codable, Hashable {
    var text: String?
    var textStyleSpans: [TextStyleSpan]?

    /// Relative path resolvable via `LocalCanvasAssetStore.resolveURL`.
    /// Stored relative (not absolute) so the JSON stays portable across
    /// app reinstalls / backup restores.
    var localImagePath: String?

    /// SF Symbol identifier rendered by `IconNodeView`. The actual visual
    /// treatment (colors, weight, background plate) is driven by
    /// `NodeStyle.iconStyleFamily`. `nil` = "no icon picked yet" — the
    /// renderer falls back to a star placeholder.
    var iconName: String?

    /// Destination URL for `.link` nodes. Free-form string so users can
    /// type partial values mid-edit; the renderer never tries to open
    /// the URL in this phase, so a malformed value is harmless.
    var url: String?

    /// Ordered list of relative image paths for `.gallery` nodes. Each
    /// path resolves via `LocalCanvasAssetStore.resolveURL`. Stored
    /// outside `localImagePath` so a single gallery can host many
    /// images without conflicting with the single-image schema used
    /// by `.image` nodes.
    var imagePaths: [String]?

    init(text: String? = nil,
         localImagePath: String? = nil,
         iconName: String? = nil,
         url: String? = nil,
         imagePaths: [String]? = nil,
         textStyleSpans: [TextStyleSpan]? = nil) {
        self.text = text
        self.localImagePath = localImagePath
        self.iconName = iconName
        self.url = url
        self.imagePaths = imagePaths
        self.textStyleSpans = textStyleSpans
    }
}

extension NodeContent {
    private enum CodingKeys: String, CodingKey {
        case text
        case textStyleSpans
        case localImagePath
        case iconName
        case url
        case imagePaths
    }

    /// Custom decoder so old drafts (which don't include the four
    /// post-Phase-1 fields) decode cleanly. Synthesised encoders would
    /// also work since every field is optional, but spelling the
    /// `decodeIfPresent` path out makes the backward-compatibility
    /// contract explicit and matches the pattern used by
    /// `ProfileDocument` and `ProfileTheme`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.textStyleSpans = try c.decodeIfPresent([TextStyleSpan].self, forKey: .textStyleSpans)
        self.localImagePath = try c.decodeIfPresent(String.self, forKey: .localImagePath)
        self.iconName = try c.decodeIfPresent(String.self, forKey: .iconName)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths)
    }
}

extension NodeContent {
    mutating func removeInvalidTextStyleSpans(afterTextChange text: String) {
        let textLength = (text as NSString).length
        guard textLength > 0 else {
            textStyleSpans = nil
            return
        }

        let normalized = (textStyleSpans ?? []).compactMap { span -> TextStyleSpan? in
            guard span.start >= 0, span.length > 0, span.start < textLength else {
                return nil
            }
            let (rawEnd, overflow) = span.start.addingReportingOverflow(span.length)
            let clampedEnd = min(textLength, overflow ? textLength : rawEnd)
            let clampedLength = max(0, clampedEnd - span.start)
            guard clampedLength > 0,
                  span.hasInlineStyle else {
                return nil
            }
            var next = span
            next.length = clampedLength
            return next
        }

        textStyleSpans = normalized.isEmpty ? nil : normalized
    }

    mutating func reconcileTextStyleSpans(oldText: String, newText: String) {
        guard !(textStyleSpans ?? []).isEmpty else { return }
        guard oldText != newText else {
            removeInvalidTextStyleSpans(afterTextChange: newText)
            return
        }

        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        let oldLength = oldUnits.count
        let newLength = newUnits.count

        var prefix = 0
        while prefix < oldLength,
              prefix < newLength,
              oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldLength - prefix,
              suffix < newLength - prefix,
              oldUnits[oldLength - 1 - suffix] == newUnits[newLength - 1 - suffix] {
            suffix += 1
        }

        let oldChangedLength = oldLength - prefix - suffix
        let newChangedLength = newLength - prefix - suffix
        let delta = newChangedLength - oldChangedLength
        let oldChangeStart = prefix
        let oldChangeEnd = prefix + oldChangedLength

        let adjusted = (textStyleSpans ?? []).compactMap { span -> TextStyleSpan? in
            adjustedSpan(
                span,
                oldChangeStart: oldChangeStart,
                oldChangeEnd: oldChangeEnd,
                oldChangedLength: oldChangedLength,
                newChangedLength: newChangedLength,
                delta: delta
            )
        }
        textStyleSpans = adjusted.isEmpty ? nil : adjusted
        removeInvalidTextStyleSpans(afterTextChange: newText)
    }

    private func adjustedSpan(_ span: TextStyleSpan,
                              oldChangeStart: Int,
                              oldChangeEnd: Int,
                              oldChangedLength: Int,
                              newChangedLength: Int,
                              delta: Int) -> TextStyleSpan? {
        let spanStart = span.start
        let spanEnd = span.start + span.length
        var next = span

        if oldChangedLength == 0 {
            if spanStart > oldChangeStart {
                next.start += delta
            } else if spanStart <= oldChangeStart, oldChangeStart <= spanEnd {
                next.length += delta
            }
            return next.length > 0 ? next : nil
        }

        if spanEnd <= oldChangeStart {
            return next
        }
        if spanStart >= oldChangeEnd {
            next.start += delta
            return next.length > 0 ? next : nil
        }

        let remainingLeft = max(0, oldChangeStart - spanStart)
        let remainingRight = max(0, spanEnd - oldChangeEnd)
        switch (remainingLeft > 0, remainingRight > 0, newChangedLength > 0) {
        case (false, false, false):
            return nil
        case (false, false, true):
            next.start = oldChangeStart
            next.length = newChangedLength
        case (true, false, _):
            next.length = remainingLeft
        case (false, true, _):
            next.start = oldChangeStart + newChangedLength
            next.length = remainingRight
        case (true, true, _):
            next.length = remainingLeft + newChangedLength + remainingRight
        }
        return next.length > 0 ? next : nil
    }
}

/// Returns a UTF-16 range suitable for applying a text-style action.
/// `nil` or collapsed selections intentionally normalize to the whole string
/// so inspector actions have the requested no-selection fallback.
func normalizedRange(selection: NSRange?, text: String) -> NSRange {
    let textLength = (text as NSString).length
    guard textLength > 0 else {
        return NSRange(location: 0, length: 0)
    }
    guard let selection,
          selection.location != NSNotFound,
          selection.length > 0 else {
        return NSRange(location: 0, length: textLength)
    }

    let start = max(0, selection.location)
    guard start < textLength else {
        return NSRange(location: 0, length: textLength)
    }
    let selectedLength = max(0, selection.length)
    let (rawEnd, overflow) = start.addingReportingOverflow(selectedLength)
    let end = min(textLength, overflow ? textLength : rawEnd)
    let length = max(0, end - start)
    return length > 0
        ? NSRange(location: start, length: length)
        : NSRange(location: 0, length: textLength)
}

func applyTextColor(hex: String, range: NSRange, to node: inout CanvasNode) {
    appendTextStyleSpan(
        TextStyleSpan(start: range.location, length: range.length, textColorHex: hex),
        replacing: .textColor,
        to: &node
    )
}

func applyHighlight(hex: String, range: NSRange, to node: inout CanvasNode) {
    appendTextStyleSpan(
        TextStyleSpan(start: range.location, length: range.length, highlightColorHex: hex),
        replacing: .highlight,
        to: &node
    )
}

func applyBold(range: NSRange, to node: inout CanvasNode) {
    appendTextStyleSpan(
        TextStyleSpan(start: range.location, length: range.length, bold: true),
        replacing: .bold,
        to: &node
    )
}

func applyItalic(range: NSRange, to node: inout CanvasNode) {
    appendTextStyleSpan(
        TextStyleSpan(start: range.location, length: range.length, italic: true),
        replacing: .italic,
        to: &node
    )
}

func applyUnderline(range: NSRange, to node: inout CanvasNode) {
    appendTextStyleSpan(
        TextStyleSpan(start: range.location, length: range.length, underline: true),
        replacing: .underline,
        to: &node
    )
}

func clearHighlight(range: NSRange, from node: inout CanvasNode) {
    clearInlineStyle(.highlight, range: range, from: &node)
}

func clearTextColor(range: NSRange, from node: inout CanvasNode) {
    clearInlineStyle(.textColor, range: range, from: &node)
}

func clearInlineStyles(range: NSRange?, from node: inout CanvasNode) {
    let range = normalizedRange(selection: range, text: node.content.text ?? "")
    clearInlineStyle(.all, range: range, from: &node)
}

func removeInvalidSpans(afterTextChange node: inout CanvasNode) {
    node.content.removeInvalidTextStyleSpans(afterTextChange: node.content.text ?? "")
}

func reconcileTextStyleSpans(afterTextChangeFrom oldText: String, to newText: String, in node: inout CanvasNode) {
    node.content.reconcileTextStyleSpans(oldText: oldText, newText: newText)
}

func inlineTextColorHex(in node: CanvasNode, range: NSRange) -> String? {
    lastInlineHex(in: node, range: range, keyPath: \.textColorHex)
}

func inlineHighlightHex(in node: CanvasNode, range: NSRange) -> String? {
    lastInlineHex(in: node, range: range, keyPath: \.highlightColorHex)
}

func inlineBold(in node: CanvasNode, range: NSRange) -> Bool? {
    lastInlineBool(in: node, range: range, keyPath: \.bold)
}

func inlineItalic(in node: CanvasNode, range: NSRange) -> Bool? {
    lastInlineBool(in: node, range: range, keyPath: \.italic)
}

func inlineUnderline(in node: CanvasNode, range: NSRange) -> Bool? {
    lastInlineBool(in: node, range: range, keyPath: \.underline)
}

private enum InlineTextStyleProperty {
    case textColor
    case highlight
    case bold
    case italic
    case underline
    case all
}

private func appendTextStyleSpan(_ span: TextStyleSpan,
                                 replacing property: InlineTextStyleProperty,
                                 to node: inout CanvasNode) {
    guard node.type == .text,
          let range = clampedRange(span.nsRange, text: node.content.text ?? "") else {
        return
    }

    var spans = node.content.textStyleSpans ?? []
    for index in spans.indices where spans[index].start == range.location && spans[index].length == range.length {
        switch property {
        case .textColor:
            spans[index].textColorHex = nil
        case .highlight:
            spans[index].highlightColorHex = nil
        case .bold:
            spans[index].bold = nil
        case .italic:
            spans[index].italic = nil
        case .underline:
            spans[index].underline = nil
        case .all:
            spans[index].clearInlineStyles()
        }
    }
    spans.removeAll { !$0.hasInlineStyle }

    var next = span
    next.start = range.location
    next.length = range.length
    spans.append(next)
    node.content.textStyleSpans = spans
    removeInvalidSpans(afterTextChange: &node)
}

private func clearInlineStyle(_ property: InlineTextStyleProperty,
                              range: NSRange,
                              from node: inout CanvasNode) {
    guard node.type == .text,
          let clearRange = clampedRange(range, text: node.content.text ?? "") else {
        return
    }

    let spans = node.content.textStyleSpans ?? []
    let rewritten = spans.flatMap { span -> [TextStyleSpan] in
        guard let spanRange = clampedRange(span.nsRange, text: node.content.text ?? ""),
              let intersection = spanRange.textStyleOverlap(with: clearRange) else {
            return [span]
        }

        var pieces: [TextStyleSpan] = []
        if spanRange.location < intersection.location {
            var left = span
            left.id = UUID()
            left.start = spanRange.location
            left.length = intersection.location - spanRange.location
            pieces.append(left)
        }

        var middle = span
        middle.id = UUID()
        middle.start = intersection.location
        middle.length = intersection.length
        switch property {
        case .textColor:
            middle.textColorHex = nil
        case .highlight:
            middle.highlightColorHex = nil
        case .bold:
            middle.bold = nil
        case .italic:
            middle.italic = nil
        case .underline:
            middle.underline = nil
        case .all:
            middle.clearInlineStyles()
        }
        if middle.hasInlineStyle {
            pieces.append(middle)
        }

        let spanEnd = spanRange.location + spanRange.length
        let intersectionEnd = intersection.location + intersection.length
        if intersectionEnd < spanEnd {
            var right = span
            right.id = UUID()
            right.start = intersectionEnd
            right.length = spanEnd - intersectionEnd
            pieces.append(right)
        }
        return pieces
    }

    node.content.textStyleSpans = rewritten.isEmpty ? nil : rewritten
    removeInvalidSpans(afterTextChange: &node)
}

private func lastInlineHex(in node: CanvasNode,
                           range: NSRange,
                           keyPath: KeyPath<TextStyleSpan, String?>) -> String? {
    guard let clamped = clampedRange(range, text: node.content.text ?? "") else {
        return nil
    }
    return (node.content.textStyleSpans ?? [])
        .filter { span in
            guard let spanRange = clampedRange(span.nsRange, text: node.content.text ?? "") else {
                return false
            }
            return spanRange.textStyleOverlap(with: clamped) != nil
        }
        .compactMap { $0[keyPath: keyPath] }
        .last
}

private func lastInlineBool(in node: CanvasNode,
                            range: NSRange,
                            keyPath: KeyPath<TextStyleSpan, Bool?>) -> Bool? {
    guard let clamped = clampedRange(range, text: node.content.text ?? "") else {
        return nil
    }
    return (node.content.textStyleSpans ?? [])
        .filter { span in
            guard let spanRange = clampedRange(span.nsRange, text: node.content.text ?? "") else {
                return false
            }
            return spanRange.textStyleOverlap(with: clamped) != nil
        }
        .compactMap { $0[keyPath: keyPath] }
        .last
}

private func clampedRange(_ range: NSRange, text: String) -> NSRange? {
    let textLength = (text as NSString).length
    guard textLength > 0,
          range.location != NSNotFound,
          range.location >= 0,
          range.length > 0,
          range.location < textLength else {
        return nil
    }
    let (rawEnd, overflow) = range.location.addingReportingOverflow(range.length)
    let end = min(textLength, overflow ? textLength : rawEnd)
    let length = max(0, end - range.location)
    guard length > 0 else { return nil }
    return NSRange(location: range.location, length: length)
}

private extension TextStyleSpan {
    var nsRange: NSRange {
        NSRange(location: start, length: length)
    }

    var hasInlineStyle: Bool {
        textColorHex != nil
            || highlightColorHex != nil
            || bold == true
            || italic == true
            || underline == true
    }

    mutating func clearInlineStyles() {
        textColorHex = nil
        highlightColorHex = nil
        bold = nil
        italic = nil
        underline = nil
    }
}

private extension NSRange {
    func textStyleOverlap(with other: NSRange) -> NSRange? {
        let lower = max(location, other.location)
        let upper = min(location + length, other.location + other.length)
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}
