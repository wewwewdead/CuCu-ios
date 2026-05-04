import UIKit

/// Coordinates async page-background effect rendering for `CanvasEditorView`.
/// It owns the per-page version tokens so stale blur/vignette renders cannot
/// overwrite the latest slider value after the CoreImage work returns.
final class CanvasBackgroundRenderer {
    private var versions: [UUID: Int] = [:]

    func invalidate(pageID: UUID) {
        versions.removeValue(forKey: pageID)
    }

    func render(image: UIImage,
                blur: Double,
                vignette: Double,
                pageID: UUID,
                imageView: UIImageView) {
        let version = (versions[pageID] ?? 0) + 1
        versions[pageID] = version
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak imageView] in
            let result = PageBackgroundEffects.apply(to: image, blur: blur, vignette: vignette)
            DispatchQueue.main.async { [weak self, weak imageView] in
                guard let self, self.versions[pageID] == version else { return }
                imageView?.image = result
            }
        }
    }
}
