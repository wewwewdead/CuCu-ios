import SwiftUI

/// Renders a single image block from its data.
///
/// Layout rules:
/// - `widthStyle == .fill` expands to the parent's width; otherwise the block
///   caps at a tasteful 320pt so compact images don't dominate the page.
/// - `aspectRatio == .auto` lets the image use its intrinsic shape;
///   `square/portrait/landscape` clip the image into a fixed-shape frame and
///   `imageFit` then decides fill (zoom & crop) vs fit (letterbox).
/// - A missing or unreadable file falls back to a calm placeholder so a draft
///   never crashes when an asset has been deleted out from under it.
struct ImageBlockView: View {
    let data: ImageBlockData

    var body: some View {
        Group {
            if let img = LocalAssetStore.loadImage(relativePath: data.localImagePath) {
                imageWithAspect(img.resizable())
            } else {
                placeholder
            }
        }
        .padding(data.padding)
        .background(
            RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous)
                .fill(Color(hex: data.backgroundColorHex))
        )
    }

    @ViewBuilder
    private func imageWithAspect(_ img: Image) -> some View {
        let widthCap: CGFloat = data.widthStyle == .fill ? .infinity : 320

        if data.aspectRatio == .auto {
            img.aspectRatio(contentMode: .fit)
                .frame(maxWidth: widthCap)
                .clipShape(RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous))
        } else {
            Color.clear
                .aspectRatio(data.aspectRatio.numericRatio, contentMode: .fit)
                .overlay(img.aspectRatio(contentMode: data.imageFit.contentMode))
                .frame(maxWidth: widthCap)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous))
        }
    }

    private var placeholder: some View {
        let widthCap: CGFloat = data.widthStyle == .fill ? .infinity : 320
        let ratio = data.aspectRatio == .auto ? 16.0 / 9.0 : data.aspectRatio.numericRatio
        return ZStack {
            RoundedRectangle(cornerRadius: data.cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 36, weight: .light))
                Text(data.localImagePath.isEmpty ? "No image yet" : "Image unavailable")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: widthCap)
    }
}
