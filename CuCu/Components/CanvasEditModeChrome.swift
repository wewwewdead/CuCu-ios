import SwiftUI

/// Visual chrome for the toggle-based "Edit Canvas" mode.
///
/// Two SwiftUI overlays here (`EditCanvasToggleButton`, `CanvasModeStatusLabel`)
/// are placed on top of the SwiftUI editor. The dashed outlines and per-node
/// chips live as UIKit subviews inside `CanvasEditorView` because that is the
/// coordinate space the node frames are authored in — drawing them in SwiftUI
/// would mean smuggling scroll offsets and per-page origins back through the
/// representable wrapper. The pencil glyph is shared between both surfaces via
/// `PencilSquareShape`.

// MARK: Pencil glyph

/// Pencil-in-square glyph drawn as three Path segments — top bar, L-shape body,
/// diagonal pencil head pointing into the bottom-right corner. Stroke width is
/// derived from the glyph's box so the same shape reads at 11pt on the chip
/// and at 12pt on the toggle without re-tuning.
struct PencilSquareShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Authoring grid is 16x16 (matches the JSX viewBox).
        let unit = min(rect.width, rect.height) / 16
        let p = { (x: CGFloat, y: CGFloat) in
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        // Horizontal top bar of the page/square.
        path.move(to: p(3, 3))
        path.addLine(to: p(9, 3))
        // L-shape body.
        path.move(to: p(3, 3))
        path.addLine(to: p(3, 13))
        path.addLine(to: p(13, 13))
        path.addLine(to: p(13, 8))
        // Pencil tip diving into the bottom-right.
        path.move(to: p(9.5, 12.5))
        path.addLine(to: p(13, 9))
        path.addLine(to: p(14.5, 10.5))
        path.addLine(to: p(11, 14))
        path.addLine(to: p(9.5, 14))
        path.closeSubpath()
        return path
    }
}

private struct PencilGlyph: View {
    var size: CGFloat
    var color: Color

    var body: some View {
        PencilSquareShape()
            .stroke(color,
                    style: StrokeStyle(lineWidth: size * 0.135,
                                       lineCap: .round,
                                       lineJoin: .round))
            .frame(width: size, height: size)
    }
}

// MARK: Top-left toggle

/// Capsule "Edit / Done" button that morphs in place — background fills, the
/// glyph color inverts, the label crossfades. Tap is a single state flip;
/// the host clears the inspector when leaving edit mode.
///
/// Reads its surface from `AppChromeStore.shared.theme` so a user who set
/// the room to a dark stock gets a dark elevated chip on top of their
/// (potentially light) canvas — same coherence the feed cards now use.
struct EditCanvasToggleButton: View {
    let editMode: Bool
    let action: () -> Void

    @State private var isPressed: Bool = false
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                PencilGlyph(size: 12,
                            color: editMode ? chrome.theme.cardColor : chrome.theme.cardInkPrimary)
                    .rotationEffect(.degrees(editMode ? -8 : 0))
                Text(editMode ? "Done" : "Edit")
                    .font(.cucuSans(12.5, weight: .semibold))
                    .foregroundStyle(editMode ? chrome.theme.cardColor : chrome.theme.cardInkPrimary)
                    .contentTransition(.opacity)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(
                Capsule(style: .continuous)
                    .fill(editMode ? chrome.theme.cardInkPrimary : chrome.theme.cardColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(chrome.theme.cardInkPrimary.opacity(editMode ? 0 : 0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 4)
            .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(editMode ? "Done editing canvas" : "Edit canvas")
        .accessibilityAddTraits(editMode ? [.isSelected] : [])
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.7)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                        isPressed = false
                    }
                }
        )
    }
}

// MARK: Top-right mode label

/// Mono-cap "Live" / "Editing" label, crossfading between the two states.
/// The dot pulse is a slow ambient cue that the canvas is "armed" — it hugs
/// the cherry accent in edit mode and the moss live-tone otherwise.
///
/// The pill surface follows the chrome theme so a dark room paints a dark
/// chip with light text — the cherry/moss dots stay the same so the
/// "armed" / "live" semantic colour stays legible across themes.
struct CanvasModeStatusLabel: View {
    let editMode: Bool

    @State private var pulse: CGFloat = 1.0
    @State private var chrome = AppChromeStore.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(editMode ? Color.cucuCherry : Color.cucuMoss)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse)
                .opacity(0.9)
            Text(editMode ? "Editing" : "Live")
                .font(.cucuMono(9, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(editMode
                                 ? Color.cucuCherry
                                 : chrome.theme.cardInkPrimary.opacity(0.65))
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(chrome.theme.cardColor.opacity(0.92))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(chrome.theme.cardInkPrimary.opacity(0.10), lineWidth: 1)
        )
        .onAppear {
            // Slow heartbeat — only kicks in on edit mode so live state
            // reads as a calm, non-pulsing dot.
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = editMode ? 1.18 : 1.0
            }
        }
        .onChange(of: editMode) { _, newValue in
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = newValue ? 1.18 : 1.0
            }
        }
    }
}

// MARK: Previews

#Preview("Toggle button — live") {
    HStack(spacing: 24) {
        EditCanvasToggleButton(editMode: false, action: {})
        EditCanvasToggleButton(editMode: true, action: {})
    }
    .padding(40)
    .background(Color.cucuPaper)
}

#Preview("Mode label") {
    HStack(spacing: 24) {
        CanvasModeStatusLabel(editMode: false)
        CanvasModeStatusLabel(editMode: true)
    }
    .padding(40)
    .background(Color.cucuPaper)
}
