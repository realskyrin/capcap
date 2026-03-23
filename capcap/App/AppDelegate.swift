import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showStartupDialog()
    }

    private func showStartupDialog() {
        let settingsController = SettingsWindowController.shared

        settingsController.onMenuBarToggle = { [weak self] visible in
            self?.statusBarController?.setMenuBarVisible(visible)
        }

        settingsController.onLaunch = { [weak self] in
            self?.initializeApp()
        }

        settingsController.showAsStartupDialog()
    }

    private func initializeApp() {
        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in self?.startCapture() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        statusBarController.setMenuBarVisible(Defaults.showMenuBar)

        keyMonitor = KeyMonitor { [weak self] in
            self?.startCapture()
        }
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
        SettingsWindowController.shared.showAsSettings()
    }
}
