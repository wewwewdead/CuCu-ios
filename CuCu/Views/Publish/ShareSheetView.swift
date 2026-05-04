import SwiftUI
import UIKit

struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> ShareSheetHostController {
        ShareSheetHostController(
            activityItems: activityItems,
            applicationActivities: applicationActivities,
            onComplete: onComplete
        )
    }

    func updateUIViewController(_ uiViewController: ShareSheetHostController, context: Context) {
        uiViewController.onComplete = onComplete
    }
}

final class ShareSheetHostController: UIViewController {
    private let activityItems: [Any]
    private let applicationActivities: [UIActivity]?
    var onComplete: (() -> Void)?
    private var didPresent = false

    init(activityItems: [Any],
         applicationActivities: [UIActivity]?,
         onComplete: (() -> Void)?) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent else { return }
        didPresent = true

        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.onComplete?()
        }

        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        present(controller, animated: true)
    }
}
