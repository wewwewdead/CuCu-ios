import UIKit

/// Renders an image node. Loads the bytes from `LocalCanvasAssetStore` using
/// the relative path stored in `NodeContent.localImagePath`. Falls back to a
/// placeholder UIImageView (system symbol) when the file is missing or the
/// path is empty so the canvas never goes blank or crashes mid-edit.
///
/// Clip shape, corner radius, border, opacity, and background are all
/// inherited from `NodeRenderView` — image nodes use exactly the same
/// shape rules as containers, so a circular image and a circular container
/// behave identically.
final class ImageNodeView: NodeRenderView {
    private let imageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()

    private var hasImage = false
    /// Tracks the path/URL we last attempted to render. The async
    /// remote-fetch callback compares against this to drop stale
    /// completions when the user has since pointed the node at a
    /// different image.
    private var currentPath: String?

    override init(nodeID: UUID) {
        super.init(nodeID: nodeID)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func apply(node: CanvasNode) {
        super.apply(node: node)

        let path = node.content.localImagePath
        currentPath = path
        let fit = node.style.imageFit ?? .fill

        if let path, let image = CanvasImageLoader.loadSync(path) {
            // Local file or remote cache hit — paint immediately.
            renderImage(image, fit: fit)
        } else if let path, !path.isEmpty, CanvasImageLoader.isRemote(path) {
            // Remote miss — show placeholder while bytes fetch, swap
            // in when ready (only if the path is still current).
            renderPlaceholder(fit: fit)
            CanvasImageLoader.loadAsync(path) { [weak self] image in
                guard let self,
                      let image,
                      self.currentPath == path
                else { return }
                self.renderImage(image, fit: fit)
            }
        } else {
            renderPlaceholder(fit: fit)
        }
    }

    private func renderImage(_ image: UIImage, fit: NodeImageFit) {
        imageView.image = image
        imageView.tintColor = nil
        imageView.backgroundColor = .clear
        hasImage = true
        applyFit(fit)
    }

    private func renderPlaceholder(fit: NodeImageFit) {
        // Placeholder: gray fill + centered system photo symbol so users
        // can still see/select/resize the node when the file is gone or
        // hasn't been written yet.
        imageView.image = UIImage(systemName: "photo")
        imageView.tintColor = .tertiaryLabel
        imageView.backgroundColor = .secondarySystemFill
        hasImage = false
        applyFit(fit)
    }

    private func applyFit(_ fit: NodeImageFit) {
        // Placeholder symbol always renders centered for clarity, regardless
        // of the user's chosen fit — it isn't meaningful content.
        if !hasImage {
            imageView.contentMode = .center
            return
        }
        switch fit {
        case .fill: imageView.contentMode = .scaleAspectFill
        case .fit:  imageView.contentMode = .scaleAspectFit
        }
    }
}
