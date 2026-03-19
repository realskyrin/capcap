import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?
    private var editController: EditWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in self?.startCapture() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        keyMonitor = KeyMonitor { [weak self] in
            self?.startCapture()
        }

        checkPermissions()
    }

    func startCapture() {
        guard overlayController == nil else { return }
        overlayController = OverlayWindowController { [weak self] result in
            self?.handleCaptureResult(result)
            self?.overlayController = nil
        }
        overlayController?.activate()
    }

    private func handleCaptureResult(_ result: CaptureResult?) {
        guard let result = result else { return }

        switch Defaults.captureMode {
        case .direct:
            if let image = ScreenCapturer.capture(rect: result.rect, screen: result.screen) {
                ClipboardManager.copyToClipboard(image: image)
            }
        case .edit:
            if let image = ScreenCapturer.capture(rect: result.rect, screen: result.screen) {
                showEditor(image: image, selectionRect: result.screenRect)
            }
        }
    }

    private func showEditor(image: NSImage, selectionRect: NSRect) {
        editController = EditWindowController(image: image, selectionRect: selectionRect) { [weak self] finalImage in
            if let finalImage = finalImage {
                ClipboardManager.copyToClipboard(image: finalImage)
            }
            self?.editController = nil
        }
        editController?.show()
    }

    private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate()
    }

    private func checkPermissions() {
        // Check Accessibility permission for global key monitoring
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Check Screen Recording permission — only prompt if not already granted
        if #available(macOS 15.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
        }
    }
}
