import SwiftUI

/// Pulled-out title + body text for one Journal Card. Built from a
/// container node's text descendants — the first text the document
/// walk hits becomes the title, every subsequent text node is
/// joined into the body.
struct JournalContent: Identifiable, Equatable, Sendable {
    /// The source container's node ID — also drives SwiftUI sheet
    /// re-presentation, so two consecutive opens of different cards
    /// dismiss + re-present cleanly instead of mutating in place.
    let id: UUID
    let title: String
    let body: String
    let dateLabel: String?
}

extension ProfileDocument {
    /// Walks the children of a "Journal Card" container and returns
    /// its text content as a typed `JournalContent`. The walk is
    /// recursive so deeply-nested layouts (a card with text inside a
    /// child container) still produce sensible content.
    ///
    /// First text → title. Everything after → body, paragraphs
    /// separated by a blank line so multi-paragraph journals read
    /// naturally in the modal.
    func journalContent(for nodeID: UUID) -> JournalContent? {
        guard let container = nodes[nodeID] else { return nil }

        var title: String?
        var bodyParts: [String] = []

        func collect(_ id: UUID) {
            guard let node = nodes[id] else { return }
            if node.type == .text,
               let raw = node.content.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                if title == nil {
                    title = raw
                } else {
                    bodyParts.append(raw)
                }
            }
            for childID in node.childrenIDs {
                collect(childID)
            }
        }

        for childID in container.childrenIDs {
            collect(childID)
        }

        return JournalContent(
            id: nodeID,
            title: title ?? "",
            body: bodyParts.joined(separator: "\n\n"),
            dateLabel: nil
        )
    }
}

/// Cute / artsy modal that opens when a viewer taps a `Journal Card`
/// container on a published profile.
///
/// Visual recipe — three things make it feel hand-crafted:
///
/// 1. **Notebook paper backing**: cream cucu paper with subtle ruled
///    lines drawn via `Canvas` and a single rose-tinted vertical
///    margin line on the left, like school stationery.
/// 2. **Type pairing**: chunky serif (`Caprasimo`) for the title +
///    handwritten (`Caveat`) for the body. Mono micro-caps for the
///    spec / date stamps.
/// 3. **Entry/exit animation**: opacity + scale spring with mild
///    overshoot, plus a drag-down-to-dismiss with rubber-band that
///    follows the finger and falls away past threshold.
struct JournalModalView: View {
    let content: JournalContent
    let onClose: () -> Void

    /// Live drag state — tracked for both the visual offset (the
    /// page tilts and slides as the user pulls down) and the
    /// background dim opacity (lifts the veil so the canvas peeks
    /// through during the drag).
    @State private var dragOffset: CGSize = .zero
    @State private var dragProgress: CGFloat = 0
    /// Toggles after first paint so the body content can stagger in
    /// after the page has settled — gives the modal a "page being
    /// turned" feel instead of everything appearing at once.
    @State private var hasAppeared: Bool = false

    var body: some View {
        ZStack {
            // Backdrop dim. Fades inversely with `dragProgress` so
            // the canvas behind the modal peeks through as the user
            // pulls down — immediate visual feedback that the
            // gesture is doing something.
            Color.black
                .opacity(0.45 * (1 - dragProgress))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            journalPage
                .padding(.horizontal, 16)
                .padding(.vertical, 56)
                .offset(y: max(0, dragOffset.height))
                .scaleEffect(1 - dragProgress * 0.08)
                .gesture(dragToDismiss)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.08)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Journal page

    @ViewBuilder
    private var journalPage: some View {
        ZStack {
            paperBackground
            VStack(alignment: .leading, spacing: 0) {
                header
                titleBlock
                CucuFleuronDivider()
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                bodyBlock
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1.5)
        )
        .shadow(color: Color.cucuInk.opacity(0.28), radius: 22, x: 0, y: 12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("✦")
                        .font(.cucuSerif(13, weight: .regular))
                        .foregroundStyle(Color.cucuRoseStroke)
                    Text("journal entry")
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.cucuInkSoft)
                }
                if let date = content.dateLabel {
                    Text(date)
                        .font(.cucuMono(10, weight: .medium))
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.cucuInkFaded)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.cucuCard))
                    .overlay(Circle().strokeBorder(Color.cucuInk, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close journal")
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var titleBlock: some View {
        Text(content.title.isEmpty ? "Untitled Entry" : content.title)
            .font(.custom("Caprasimo-Regular", size: 30))
            .foregroundStyle(Color.cucuInk)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 6)
    }

    private var bodyBlock: some View {
        ScrollView {
            Text(content.body.isEmpty ? "(this entry is empty)" : content.body)
                .font(.custom("Caveat-Regular", size: 24))
                .foregroundStyle(Color.cucuInkSoft)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Paper backdrop
    //
    // Cream `Color.cucuCard` base + faint ruled horizontal lines
    // drawn with `Canvas` (vector, scales with the modal) + a single
    // rose vertical margin line at ~60pt from the leading edge to
    // sell the school-notebook feel. Hit-testing disabled so the
    // decorations don't intercept drag-to-dismiss.

    @ViewBuilder
    private var paperBackground: some View {
        ZStack {
            Color.cucuCard
            Canvas { ctx, size in
                let firstRule: CGFloat = 132
                let spacing: CGFloat = 30
                var y = firstRule
                while y < size.height - 24 {
                    var path = Path()
                    path.move(to: CGPoint(x: 22, y: y))
                    path.addLine(to: CGPoint(x: size.width - 22, y: y))
                    ctx.stroke(
                        path,
                        with: .color(Color.cucuInkRule.opacity(0.55)),
                        lineWidth: 0.5
                    )
                    y += spacing
                }
            }
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                Spacer().frame(width: 56)
                Rectangle()
                    .fill(Color.cucuRoseStroke.opacity(0.7))
                    .frame(width: 0.8)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Drag-to-dismiss
    //
    // Standard iOS swipe-down dismiss with rubber-band:
    //   - As `translation.height` grows (downward), the page slides
    //     and shrinks slightly (max 8% scale-down).
    //   - Past 110pt OR with high downward velocity, the page
    //     continues its trajectory to ~600pt while the dim fades to
    //     zero, then `onClose` fires.
    //   - Below threshold, a snappy spring returns it to identity.

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
