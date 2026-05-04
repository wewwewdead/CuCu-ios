import SwiftUI

/// Style payload mirroring the source `.note` node's `NodeStyle` so
/// the expand modal renders as the *same* card the user designed,
/// scaled up. Hex strings + raw enums travel rather than `Color` /
/// `Font` so this stays `Sendable` (and animates cleanly through
/// SwiftUI state diffs).
struct NoteStylePayload: Equatable, Sendable {
    var backgroundHex: String
    var textHex: String
    var borderHex: String?
    var borderWidth: Double
    var cornerRadius: Double
    var fontFamily: NodeFontFamily
    var fontWeight: NodeFontWeight
    /// The note's body base size — title / timestamp scale off this
    /// via the same ratios the canvas renderer uses (×1.4 / ×0.8).
    var baseFontSize: Double
    var textAlignment: NodeTextAlignment
    var padding: Double

    static var fallback: NoteStylePayload {
        NoteStylePayload(
            backgroundHex: "#FFFFFF",
            textHex: "#1A140E",
            borderHex: "#1A140E",
            borderWidth: 1.2,
            cornerRadius: 24,
            fontFamily: .system,
            fontWeight: .regular,
            baseFontSize: 15,
            textAlignment: .leading,
            padding: 16
        )
    }
}

/// Captured note content for the published-profile expand sheet.
/// Built from a `.note` node's `content.noteTitle / noteTimestamp /
/// text` fields plus the node's `style` so the modal mirrors the
/// user's customization (fill, border, typography) instead of
/// rendering as a generic dialog.
struct NoteContent: Identifiable, Equatable, Sendable {
    /// The source node id — also keys SwiftUI sheet re-presentation
    /// so opening a different note dismisses + re-presents cleanly.
    let id: UUID
    let title: String
    let timestamp: String
    let body: String
    let style: NoteStylePayload
}

extension ProfileDocument {
    /// Build the published-view payload for a `.note` node. Returns
    /// `nil` when the id doesn't resolve or the node is the wrong
    /// type — the published view treats that as "swallow the tap".
    func noteContent(for nodeID: UUID) -> NoteContent? {
        guard let node = nodes[nodeID], node.type == .note else { return nil }
        let style = node.style
        let payload = NoteStylePayload(
            backgroundHex: style.backgroundColorHex ?? "#FFFFFF",
            textHex: style.textColorHex ?? "#1A140E",
            borderHex: style.borderColorHex,
            borderWidth: style.borderWidth,
            cornerRadius: max(style.cornerRadius, 14),
            fontFamily: style.fontFamily ?? .system,
            fontWeight: style.fontWeight ?? .regular,
            baseFontSize: style.fontSize ?? 15,
            textAlignment: style.textAlignment ?? .leading,
            padding: style.padding ?? 16
        )
        return NoteContent(
            id: nodeID,
            title: node.content.noteTitle ?? "",
            timestamp: node.content.noteTimestamp ?? "",
            body: node.content.text ?? "",
            style: payload
        )
    }
}

/// Full-bleed sheet that opens when a viewer taps a note card on a
/// published profile, when a viewer taps "see more" on a note, or
/// from the editor's preview / live mode. The card mirrors the
/// source note's style — fill, border, radius, fonts, ink color
/// all carry through — so the modal feels like the note itself
/// expanded rather than a separate dialog.
///
/// Entry animation — orchestrated, not flat:
///   1. Backdrop fades in.
///   2. Card lifts in from below + slight clockwise tilt with a
///      bouncy spring overshoot — postcard-on-a-table feel.
///   3. Title slides down a few pt + fades.
///   4. Timestamp fades in (delayed).
///   5. Body fades + offsets up (delayed further).
///   6. Close button rotates + scales into place.
struct NoteModalView: View {
    let content: NoteContent
    let onClose: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var dragProgress: CGFloat = 0

    @State private var cardLanded: Bool = false
    @State private var titleRevealed: Bool = false
    @State private var timestampRevealed: Bool = false
    @State private var bodyRevealed: Bool = false
    @State private var chromeRevealed: Bool = false
    @State private var backdropRevealed: Bool = false

    /// Modal font sizes scale up from the source note's authored
    /// `baseFontSize` so a note authored at 15pt reads at 22pt
    /// title / 12pt timestamp / 16pt body in the modal — the user's
    /// proportional intent preserved, just zoomed.
    private var modalBaseSize: CGFloat {
        max(15, CGFloat(content.style.baseFontSize) * 1.05)
    }

    // MARK: - Resolved styling

    private var backgroundColor: Color { Color(hex: content.style.backgroundHex) }
    private var inkColor: Color { Color(hex: content.style.textHex) }
    private var borderColor: Color {
        guard let hex = content.style.borderHex, !hex.isEmpty else {
            return inkColor
        }
        return Color(hex: hex)
    }
    private var horizontalAlignment: HorizontalAlignment {
        switch content.style.textAlignment {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
    private var textAlignment: TextAlignment {
        switch content.style.textAlignment {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
    private var titleFont: Font {
        content.style.fontFamily.swiftUIFont(
            size: modalBaseSize * 1.55,
            weight: .bold
        )
    }
    private var timestampFont: Font {
        content.style.fontFamily.swiftUIFont(
            size: max(11, modalBaseSize * 0.78),
            weight: .regular
        )
    }
    private var bodyFont: Font {
        content.style.fontFamily.swiftUIFont(
            size: modalBaseSize,
            weight: content.style.fontWeight.swiftUIWeight
        )
    }

    var body: some View {
        ZStack {
            backdrop
            card
                .padding(.horizontal, 16)
                .padding(.vertical, 56)
                .offset(y: max(0, dragOffset.height))
                .scaleEffect(1 - dragProgress * 0.08)
                .gesture(dragToDismiss)
        }
        .onAppear { runEntryChoreography() }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        Color.black
            .opacity((backdropRevealed ? 0.42 : 0) * (1 - dragProgress))
            .ignoresSafeArea()
            .onTapGesture { onClose() }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: horizontalAlignment, spacing: 14) {
            titleRow
            if !content.timestamp.isEmpty {
                timestampRow
            }
            bodyRow
        }
        .padding(max(16, CGFloat(content.style.padding) * 1.2))
        .frame(maxHeight: 560)
        .background(cardSurface)
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(cardLanded ? 0.22 : 0),
                radius: cardLanded ? 22 : 8,
                x: 0, y: cardLanded ? 12 : 4)
        .scaleEffect(cardLanded ? 1 : 0.84, anchor: .bottom)
        .rotationEffect(.degrees(cardLanded ? 0 : -2.4), anchor: .bottom)
        .offset(y: cardLanded ? 0 : 70)
        .opacity(cardLanded ? 1 : 0)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: CGFloat(content.style.cornerRadius), style: .continuous)
            .fill(backgroundColor)
    }

    @ViewBuilder
    private var cardBorder: some View {
        let width = max(0, CGFloat(content.style.borderWidth))
        if width > 0 {
            RoundedRectangle(cornerRadius: CGFloat(content.style.cornerRadius), style: .continuous)
                .strokeBorder(borderColor, lineWidth: width)
        }
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(content.title.isEmpty ? "Notes" : content.title)
                .font(titleFont)
                .foregroundStyle(inkColor)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .opacity(titleRevealed ? 1 : 0)
                .offset(y: titleRevealed ? 0 : -8)
            Spacer(minLength: 8)
            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(inkColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(closeButtonFill))
                .overlay(Circle().strokeBorder(inkColor.opacity(0.85), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close note")
        .opacity(chromeRevealed ? 1 : 0)
        .scaleEffect(chromeRevealed ? 1 : 0.6)
        .rotationEffect(.degrees(chromeRevealed ? 0 : -45))
    }

    /// Close-button plate: a faint cucu-card warmth on light cards;
    /// a soft black on dark cards. We can't measure luminance off the
    /// hex with full reliability here, so we lean on a quick
    /// `Color(hex:)` luminance approximation derived from the
    /// `backgroundHex`. Falls through to `cucuCard` on parsing
    /// trouble.
    private var closeButtonFill: Color {
        let lum = NoteStylePayload.luminance(of: content.style.backgroundHex)
        return lum < 0.5
            ? Color.white.opacity(0.18)
            : Color.cucuCard
    }

    private var timestampRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: max(11, modalBaseSize * 0.78), weight: .regular))
                .foregroundStyle(inkColor.opacity(0.6))
            Text(content.timestamp)
                .font(timestampFont)
                .foregroundStyle(inkColor.opacity(0.6))
                .multilineTextAlignment(textAlignment)
        }
        .opacity(timestampRevealed ? 1 : 0)
        .offset(x: timestampRevealed ? 0 : -6)
        .frame(maxWidth: .infinity, alignment: rowAlignment)
    }

    private var bodyRow: some View {
        ScrollView {
            Text(content.body.isEmpty ? "(this note is empty)" : content.body)
                .font(bodyFont)
                .foregroundStyle(inkColor)
                .multilineTextAlignment(textAlignment)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: rowAlignment)
                .padding(.bottom, 24)
                .opacity(bodyRevealed ? 1 : 0)
                .offset(y: bodyRevealed ? 0 : 14)
        }
        .scrollIndicators(.hidden)
    }

    private var rowAlignment: Alignment {
        switch content.style.textAlignment {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    // MARK: - Entry choreography

    private func runEntryChoreography() {
        withAnimation(.easeOut(duration: 0.28)) {
            backdropRevealed = true
        }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.66)) {
            cardLanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                titleRevealed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.easeOut(duration: 0.32)) {
                timestampRevealed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.easeOut(duration: 0.40)) {
                bodyRevealed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.62)) {
                chromeRevealed = true
            }
        }
    }

    // MARK: - Drag-to-dismiss

    private var dragToDismiss: some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragOffset = value.translation
                dragProgress = min(value.translation.height / 280, 1)
            }
            .onEnded { value in
                let h = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if h > 110 || predicted > 220 {
                    withAnimation(.easeOut(duration: 0.26)) {
                        dragOffset = CGSize(width: 0, height: 720)
                        dragProgress = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        onClose()
                    }
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                        dragOffset = .zero
                        dragProgress = 0
                    }
                }
            }
    }
}

// MARK: - Helpers

extension NoteStylePayload {
    /// Quick relative-luminance approximation used to pick a contrast-
    /// safe close-button plate. Mirrors the math in
    /// `PreviewBannerCard.hexLuminance` so the two surfaces agree on
    /// what reads as "dark".
    static func luminance(of hex: String) -> Double {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count >= 6,
              let value = UInt32(trimmed.prefix(6), radix: 16) else { return 1 }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
