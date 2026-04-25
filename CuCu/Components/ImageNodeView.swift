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

        if let path = node.content.localImagePath,
           let image = LocalCanvasAssetStore.loadUIImage(path) {
            imageView.image = image
            imageView.tintColor = nil
            imageView.backgroundColor = .clear
            hasImage = true
        } else {
            // Placeholder: gray fill + centered system photo symbol so users
            // can still see/select/resize the node when the file is gone or
            // hasn't been written yet.
            imageView.image = UIImage(systemName: "photo")
            imageView.tintColor = .tertiaryLabel
            imageView.backgroundColor = .secondarySystemFill
            hasImage = false
        }

        applyFit(node.style.imageFit ?? .fill)
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
