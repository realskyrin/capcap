import AppKit

final class ImageMergeLauncher {
    static let shared = ImageMergeLauncher()

    var onContinueEditing: ((NSImage) -> Void)?

    private var windowController: ImageMergeWindowController?

    var isWorkbenchActive: Bool {
        windowController?.window?.isVisible == true
    }

    private init() {}

    func openEmpty() {
        if let windowController, windowController.window?.isVisible == true {
            windowController.show()
            return
        }
        present(document: ImageMergeDocument())
    }

    func openFromFinderSelection() {
        if let windowController, windowController.window?.isVisible == true {
            windowController.show()
            return
        }

        let urls = FinderSelection.currentImageFileURLs()
        guard urls.count >= 2 else {
            ToastWindow.show(message: L10n.imageMergeNeedTwoImages)
            return
        }
        open(urls: urls)
    }

    func open(urls: [URL]) {
        if let windowController, windowController.window?.isVisible == true {
            windowController.appendImages(from: urls)
            windowController.show()
            return
        }

        let result = ImageMergeDocument.loadItems(from: urls)
        let document = ImageMergeDocument(items: result.items)
        present(document: document)
        if result.failedCount > 0 {
            ToastWindow.show(message: L10n.imageMergeSomeImagesSkipped)
        }
    }

    private func present(document: ImageMergeDocument) {
        let controller = ImageMergeWindowController(
            document: document,
            onContinueEditing: { [weak self] image in
                self?.onContinueEditing?(image)
            },
            onClose: { [weak self] in
                self?.windowController = nil
            }
        )
        windowController = controller
        controller.show()
    }
}
