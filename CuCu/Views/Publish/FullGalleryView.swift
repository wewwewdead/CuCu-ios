import SwiftUI

/// Fullscreen grid view of every image in a gallery node, opened from
/// the "View Gallery" chip on the published canvas.
///
/// Two optimisations matter here:
///
/// 1. **`LazyVGrid`** — only the visible row of tiles is materialised;
///    a 60-image gallery doesn't decode 60 bitmaps up front. Off-
///    screen tiles never fire their `onAppear`, so they never even
///    request the URL.
/// 2. **`CachedRemoteImage`** — every fetch routes through
///    `RemoteImageCache`, the same cache the gallery node and the
///    lightbox already use. A tile the user has seen on the canvas
///    paints instantly when it scrolls into the grid; the disk-cache
///    in `URLSessionConfiguration.default` covers cold launches.
///
/// Aesthetic continues the editorial-paper direction: cream paper
/// page floats over a dimmed canvas, fleuron divider, mono spec
/// line at the top, ink-stroked tile borders. Drag-down to dismiss
/// rubber-bands the page and falls away past threshold.
struct FullGalleryView: View {
    let urls: [URL]
    /// Fired with the tapped tile's index so the host can present
    /// the lightbox on top of (or instead of) the grid.
    let onSelectTile: (Int) -> Void
    let onClose: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var dragProgress: CGFloat = 0
    @State private var hasAppeared = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )

    var body: some View {
        ZStack {
            // Backdrop dim — fades inversely with drag progress so
            // the page peeks through as the user pulls down.
            Color.black
                .opacity(0.45 * (1 - dragProgress))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            galleryPage
                .padding(.horizontal, 12)
                .padding(.vertical, 56)
                .offset(y: max(0, dragOffset.height))
                .scaleEffect(1 - dragProgress * 0.06)
                .gesture(dragToDismiss)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.08)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Page

    private var galleryPage: some View {
        VStack(spacing: 0) {
            header
            CucuFleuronDivider()
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            grid
        }
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.cucuPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.cucuInk, lineWidth: 1.4)
        )
        .shadow(color: Color.cucuInk.opacity(0.26), radius: 22, x: 0, y: 12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(urls.count) photo\(urls.count == 1 ? "" : "s")")
                    .font(.cucuSerif(22, weight: .bold))
                    .foregroundStyle(Color.cucuInk)
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
            .accessibilityLabel("Close gallery")
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    Button {
                        onSelectTile(index)
                    } label: {
                        tile(url: url, index: index)
                    }
                    .buttonStyle(CucuPressableButtonStyle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 28)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 6)
        }
        .scrollIndicators(.hidden)
    }

    private func tile(url: URL, index: Int) -> some View {
        // Square tiles via `aspectRatio(1, contentMode: .fit)` on the
        // outer frame — `CachedRemoteImage` fills with the photo
        // (`.fill` content mode), and the rounded clip masks the
        // overflow so each tile reads as a clean cream-bordered card.
        Color.cucuCardSoft
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CachedRemoteImage(url: url, contentMode: .fill) {
                    ZStack {
                        Color.cucuCardSoft
                        Image(systemName: "photo")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color.cucuInkFaded)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.cucuInk.opacity(0.22), lineWidth: 0.7)
            )
    }

    // MARK: - Drag dismiss

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
