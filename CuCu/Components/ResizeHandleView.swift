import UIKit

/// One of four corner resize handles. Owns its own `UIPanGestureRecognizer`
/// and reports gesture translation up via a closure. The selection overlay
/// owns the four handles and converts pan deltas into node-frame mutations.
final class ResizeHandleView: UIView {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight, bottomCenter }

    let corner: Corner

    /// Called on every gesture state change. Listener decides what to do
    /// (begin / mutate frame / commit). Translation is in the
    /// `referenceView` coordinate space the listener supplies.
    var onPan: ((UIPanGestureRecognizer.State, CGPoint) -> Void)?

    init(corner: Corner) {
        self.corner = corner
        super.init(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        backgroundColor = .systemBackground
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 1.5
        layer.cornerRadius = 3

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let reference = referenceView else { return }
        let translation = gesture.translation(in: reference)
        onPan?(gesture.state, translation)
    }

    /// View whose coordinate space pan translations are reported in. The
    /// selection overlay sets this to the canvas root so the listener gets
    /// stable, shared-space deltas regardless of how nested the selected
    /// node is.
    weak var referenceView: UIView?
}
