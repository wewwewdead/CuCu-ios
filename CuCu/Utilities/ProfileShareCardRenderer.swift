import UIKit

@MainActor
enum ProfileShareCardRenderer {
    static let targetWidth: CGFloat = 1080
    static let maxOutputHeight: CGFloat = 4320
    private static let imagePreloadTimeout: TimeInterval = 4
    private static let renderSettleDelayNanoseconds: UInt64 = 300_000_000

    static func render(username: String,
                       profileLink: String,
                       document: ProfileDocument?) async throws -> UIImage {
        await Task.yield()
        guard let document, !document.pages.isEmpty else {
            throw ProfileShareCardRenderingError.missingDocument
        }

        // Product scope for this phase: share the first authored page only.
        // Multi-page carousel or stitched exports can build on this without
        // changing the source renderer.
        let pageIndex = 0
        await preloadImages(in: document)
        let pageImage = try await renderOriginalPage(document: document, pageIndex: pageIndex)
        return normalize(pageImage)
    }

    private static func renderOriginalPage(document: ProfileDocument, pageIndex: Int) async throws -> UIImage {
        let page = document.pages[pageIndex]
        let designWidth = max(
            1,
            CGFloat(document.contentDesignWidth(forPageAt: pageIndex))
        )
        let pageHeight = max(1, CGFloat(page.height))

        let canvas = CanvasEditorView()
        canvas.isInteractive = false
        canvas.viewerPageIndex = pageIndex
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: designWidth, height: pageHeight))
        canvas.bounds = CGRect(origin: .zero, size: canvas.frame.size)
        canvas.apply(document: document, selectedID: nil)
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()

        // Give UIKit and any background-image effect renders one short,
        // non-blocking settle window. Image bytes are prewarmed above, so
        // this is mainly for layout, Core Animation, and filtered bg swaps.
        try? await Task.sleep(nanoseconds: renderSettleDelayNanoseconds)
        canvas.layoutIfNeeded()

        guard let image = canvas.snapshotRenderedPage(at: pageIndex, scale: exportScale(for: document, pageIndex: pageIndex)) else {
            throw ProfileShareCardRenderingError.renderingFailed
        }
        return image
    }

    private static func normalize(_ image: UIImage) -> UIImage {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return image }

        let widthScale = targetWidth / imageSize.width
        let heightCap = maxOutputHeight / imageSize.height
        let scale = min(widthScale, heightCap)
        let finalSize = CGSize(
            width: ceil(imageSize.width * scale),
            height: ceil(imageSize.height * scale)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: finalSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: finalSize))
        }
    }

    private static func exportScale(for document: ProfileDocument, pageIndex: Int) -> CGFloat {
        guard document.pages.indices.contains(pageIndex) else { return 1 }
        let width = max(1, CGFloat(document.contentDesignWidth(forPageAt: pageIndex)))
        return min(3, max(1, targetWidth / width))
    }

    private static func preloadImages(in document: ProfileDocument) async {
        let paths = imagePaths(in: document)
        guard !paths.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var pending = 0
            var didResume = false

            func resumeOnce() {
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }

            func finishOne() {
                pending -= 1
                if pending <= 0 {
                    resumeOnce()
                }
            }

            for path in paths {
                if CanvasImageLoader.loadSync(path) != nil {
                    continue
                }
                pending += 1
                CanvasImageLoader.loadAsync(path) { _ in
                    finishOne()
                }
            }

            guard pending > 0 else {
                resumeOnce()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + imagePreloadTimeout) {
                resumeOnce()
            }
        }
    }

    private static func imagePaths(in document: ProfileDocument) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        func append(_ path: String?) {
            guard let path, !path.isEmpty, seen.insert(path).inserted else { return }
            paths.append(path)
        }

        for page in document.pages {
            append(page.backgroundImagePath)
        }
        append(document.pageBackgroundImagePath)

        for node in document.nodes.values {
            append(node.style.backgroundImagePath)
            append(node.content.localImagePath)
            for path in node.content.imagePaths ?? [] {
                append(path)
            }
        }

        return paths
    }

}

enum ProfileShareCardRenderingError: LocalizedError {
    case missingDocument
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .missingDocument:
            return "There's no profile design to export yet."
        case .renderingFailed:
            return "Couldn't make the profile card right now."
        }
    }
}
