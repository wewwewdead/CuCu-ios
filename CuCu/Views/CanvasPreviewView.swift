import SwiftUI

/// Local preview of the user's draft — the same `CanvasEditorContainer`
/// the editor uses, but mounted in viewer mode (`isInteractive: false`)
/// so taps / drags / long-presses on nodes do nothing. The user can
/// flip into preview, see what the page reads as for a visitor, then
/// dismiss back to editing without round-tripping through publish.
///
/// Visual contract:
///   - Same scale-to-fit transform as `PublishedProfileView` so the
///     page renders edge-to-edge regardless of the device size.
///   - Clean editorial chrome: Done left, "preview · fig. 02" centered
///     spec title, Publish button right (paperplane).
///   - Link taps still work (route through `openURL`); gallery taps
///     and journal cards are intentionally disabled in preview to
///     avoid the modal-on-modal stack — the user is one tap from
///     editing or publishing instead.
struct CanvasPreviewView: View {
    let document: ProfileDocument
    let onClose: () -> Void
    let onPublish: () -> Void

    @State private var sinkSelectedID: UUID?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cucuPaper.ignoresSafeArea()
                adaptiveCanvas
            }
            .navigationTitle("")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.cucuPaper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .tint(Color.cucuInk)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                        .font(.cucuSerif(16, weight: .semibold))
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("preview")
                            .font(.cucuSerif(18, weight: .bold))
                            .foregroundStyle(Color.cucuInk)
                        Text("FIG. 02 · YOUR PAGE")
                            .font(.cucuMono(9, weight: .medium))
                            .tracking(2)
                            .foregroundStyle(Color.cucuInkFaded)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onPublish()
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .accessibilityLabel("Publish")
                }
            }
        }
    }

    /// Mirror of `PublishedProfileView.singlePageCanvas` — render the
    /// canvas edge-to-edge at the previewer's screen width and let the
    /// inner `CanvasEditorContainer` apply the same
    /// `max(viewportWidth, pageWidth)` rule the editor uses. That
    /// guarantees 100% pixel parity with the editing surface — what
    /// the author dragged into place on this device will render at the
    /// exact same size in the preview and in the published viewer.
    @ViewBuilder
    private var adaptiveCanvas: some View {
        GeometryReader { geo in
            let availableWidth = max(1, geo.size.width)

            CanvasEditorContainer(
                document: .constant(document),
                selectedID: $sinkSelectedID,
                onCommit: { _ in /* preview is read-only */ },
                isInteractive: false,
                onOpenURL: { url in openURL(url) }
            )
            .frame(width: availableWidth, height: geo.size.height)
        }
    }
}
