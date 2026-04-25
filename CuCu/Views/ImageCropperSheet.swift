import SwiftUI
import UIKit

/// "Position the image" sheet shown after the user picks a photo for a
/// canvas / container background but before the bytes are saved. The
/// image is scaled to fill a fixed-aspect crop window; the user pans
/// and pinches to choose which part of the photo ends up visible. On
/// Done the visible region is rendered at a high (3×) scale and
/// returned as PNG `Data` — lossless out of the cropper so the next
/// stage (`LocalCanvasAssetStore` → `ImageNormalizer`) can encode JPEG
/// **once**, avoiding the double-JPEG quality loss the previous
/// free-form cropper introduced.
///
/// The target aspect ratio matches what the image will actually occupy
/// on the canvas:
/// - Page background → screen aspect ratio.
/// - Container background → that container's `frame.width / frame.height`.
struct ImageCropperSheet: View {
    let sourceData: Data
    let targetAspect: CGFloat
    var onCrop: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var cropFrameSize: CGSize = .zero

    @State private var committedScale: CGFloat = 1.0
    @State private var committedOffset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize = .zero

    init(sourceData: Data,
         targetAspect: CGFloat = 9.0 / 19.5,
         onCrop: @escaping (Data) -> Void) {
        self.sourceData = sourceData
        // Clamp to a sane range so a malformed aspect doesn't produce
        // a 0-width crop window.
        self.targetAspect = max(0.2, min(targetAspect, 5.0))
        self.onCrop = onCrop
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = computeFrameSize(in: geo.size)
                ZStack {
                    Color.black.ignoresSafeArea()

                    if let image {
                        // Image lives inside the crop frame, scale-aspect-fill
                        // so by default it covers the frame edge to edge. The
                        // user's transforms are layered on top.
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(currentScale)
                            .offset(currentOffset)
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                            .gesture(
                                SimultaneousGesture(panGesture, magnifyGesture)
                            )
                            .onAppear { cropFrameSize = frame }
                            .onChange(of: frame) { _, newFrame in
                                cropFrameSize = newFrame
                            }
                    } else {
                        ProgressView().tint(.white)
                    }

                    // Crisp white border around the crop window so the
                    // user can see exactly what will be saved.
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    Text("Drag to move • Pinch to zoom")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 18)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Position Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .tint(.white)
                        .disabled(image == nil)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                image = UIImage(data: sourceData)
            }
        }
    }

    // MARK: - Live transforms

    private var currentScale: CGFloat {
        max(1.0, committedScale * gestureScale)
    }

    private var currentOffset: CGSize {
        CGSize(
            width: committedOffset.width + gestureOffset.width,
            height: committedOffset.height + gestureOffset.height
        )
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($gestureOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let proposed = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
                committedOffset = clampedOffset(proposed, forScale: committedScale)
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let newScale = max(1.0, committedScale * value)
                committedScale = newScale
                // Re-clamp the offset against the new scale so the
                // image still fully covers the crop window.
                committedOffset = clampedOffset(committedOffset, forScale: newScale)
            }
    }

    /// Limit the offset so the image always covers the crop frame —
    /// you can never expose empty space behind the photo.
    private func clampedOffset(_ proposed: CGSize, forScale scale: CGFloat) -> CGSize {
        guard let image, cropFrameSize.width > 0 else { return proposed }
        let imgSize = image.size
        let baseScale = max(
            cropFrameSize.width / imgSize.width,
            cropFrameSize.height / imgSize.height
        )
        let drawnWidth = imgSize.width * baseScale * scale
        let drawnHeight = imgSize.height * baseScale * scale
        let maxOffsetX = max(0, (drawnWidth - cropFrameSize.width) / 2)
        let maxOffsetY = max(0, (drawnHeight - cropFrameSize.height) / 2)
        return CGSize(
            width: max(-maxOffsetX, min(proposed.width, maxOffsetX)),
            height: max(-maxOffsetY, min(proposed.height, maxOffsetY))
        )
    }

    private func computeFrameSize(in container: CGSize) -> CGSize {
        let horizontalPadding: CGFloat = 24
        let verticalPadding: CGFloat = 80  // leave room for hint label
        let availW = max(0, container.width - horizontalPadding * 2)
        let availH = max(0, container.height - verticalPadding * 2)
        guard availW > 0, availH > 0 else { return .zero }
        if availW / availH > targetAspect {
            return CGSize(width: availH * targetAspect, height: availH)
        } else {
            return CGSize(width: availW, height: availW / targetAspect)
        }
    }

    // MARK: - Render

    private func finish() {
        guard let image, cropFrameSize.width > 0 else {
            dismiss()
            return
        }

        // Render the visible region at 3× the displayed size so the
        // saved bitmap has retina-quality detail. Encoded as PNG so
        // there's no JPEG generation here — `LocalCanvasAssetStore`
        // does the single JPEG encode downstream.
        let outputScale: CGFloat = 3.0
        let outputSize = CGSize(
            width: cropFrameSize.width * outputScale,
            height: cropFrameSize.height * outputScale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // pixel-accurate with `outputSize`
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)

        let rendered = renderer.image { ctx in
            let c = ctx.cgContext
            // Origin at top-left; move to center to apply transforms.
            c.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            // Map points → output pixels.
            c.scaleBy(x: outputScale, y: outputScale)
            // Apply the user's pan + zoom (in points, since the
            // `outputScale` above already accounts for retina).
            c.translateBy(x: currentOffset.width, y: currentOffset.height)
            c.scaleBy(x: currentScale, y: currentScale)
            // Draw the image at its base scale-aspect-fill size,
            // centered on origin.
            let imgSize = image.size
            let baseScale = max(
                cropFrameSize.width / imgSize.width,
                cropFrameSize.height / imgSize.height
            )
            let drawSize = CGSize(
                width: imgSize.width * baseScale,
                height: imgSize.height * baseScale
            )
            image.draw(in: CGRect(
                x: -drawSize.width / 2,
                y: -drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        }

        guard let data = rendered.pngData() else {
            dismiss()
            return
        }
        onCrop(data)
        dismiss()
    }
}
