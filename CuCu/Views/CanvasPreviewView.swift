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

    /// Mirror of `PublishedProfileView.adaptiveCanvas` — the document
    /// renders at its authored width internally, then SwiftUI scales
    /// it down (cap at 1.0) so a profile authored on a Pro Max stays
    /// readable on an iPhone SE and a profile authored on an SE
    /// doesn't get stretched on an iPad.
    @ViewBuilder
    private var adaptiveCanvas: some View {
        GeometryReader { geo in
            let documentWidth = max(1, CGFloat(document.pageWidth))
            let availableWidth = max(1, geo.size.width)
            let scale = min(1.0, availableWidth / documentWidth)
            let scaledWidth = documentWidth * scale
            let scaledHeight = geo.size.height

            CanvasEditorContainer(
                document: .constant(document),
                selectedID: $sinkSelectedID,
                onCommit: { _ in /* preview is read-only */ },
                isInteractive: false,
                onOpenURL: { url in openURL(url) }
            )
            .frame(width: documentWidth, height: scaledHeight / max(scale, 0.001))
            .scaleEffect(scale, anchor: .top)
            .frame(width: scaledWidth, height: scaledHeight)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
