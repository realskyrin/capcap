import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?

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
        overlayController = OverlayWindowController { [weak self] finalImage in
            if let finalImage = finalImage {
                ClipboardManager.copyToClipboard(image: finalImage)
                ToastWindow.show()
            }
            self?.overlayController = nil
        }
        overlayController?.activate()
    }

    private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate()
    }

    private func checkPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        if #available(macOS 15.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
            }
        }
    }
}
