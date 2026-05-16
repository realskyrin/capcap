import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?
    private var countdownActive = false

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
        ImageEditLauncher.clearTempDir()

        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in self?.handleTrigger() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        statusBarController.setMenuBarVisible(Defaults.showMenuBar)

        keyMonitor = KeyMonitor(
            onTrigger: { [weak self] in self?.handleTrigger() },
            onCountdownTrigger: { [weak self] in self?.handleCountdownTrigger() }
        )

        NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHotkeyState()
        }
        applyHotkeyState()

        // Quietly look for a newer release (throttled to once per 24h). A hit
        // surfaces only in the menu bar item and the About pane — no popup.
        UpdateChecker.shared.checkOnLaunchIfDue()
    }

    private func applyHotkeyState() {
        if HotkeyManager.shared.isRecording {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterCountdown()
            keyMonitor?.isEnabled = false
            return
        }
        keyMonitor?.isEnabled = true
        if Defaults.hasCustomScreenshotHotkey {
            HotkeyManager.shared.register { [weak self] in
                self?.handleTrigger()
            }
            HotkeyManager.shared.registerCountdown { [weak self] in
                self?.handleCountdownTrigger()
            }
            // Custom hotkey owns plain ⌘ + key; double-tap ⌘ steps aside to
            // avoid two ways to fire the same regular capture.
            keyMonitor?.isRegularDoubleTapEnabled = false
        } else {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterCountdown()
            keyMonitor?.isRegularDoubleTapEnabled = true
        }
    }

    func handleTrigger() {
        guard overlayController == nil else { return }

        // Image-edit shortcut: if Finder has exactly one image selected, edit
        // that file directly. Any failure (no permission, load error, no
        // selection) falls through to the normal screenshot flow.
        if let url = FinderSelection.currentImageFileURL(),
           let controller = ImageEditLauncher.launch(
               sourceURL: url,
               onComplete: { [weak self] finalImage in
                   self?.handleEditCompletion(finalImage)
               }
           )
        {
            overlayController = controller
            return
        }

        startCapture()
    }

    /// Countdown-triggered capture. Skips the Finder image-edit shortcut on
    /// purpose — the user explicitly asked for a delayed screen capture.
    func handleCountdownTrigger() {
        guard overlayController == nil, !countdownActive else { return }
        countdownActive = true
        CountdownWindow.start(
            seconds: Defaults.countdownSeconds,
            onFinish: { [weak self] in
                self?.countdownActive = false
                self?.startCapture()
            },
            onCancel: { [weak self] in
                self?.countdownActive = false
            }
        )
    }

    func startCapture() {
        guard overlayController == nil else { return }
        overlayController = OverlayWindowController { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }
        overlayController?.activate()
    }

    private func handleEditCompletion(_ finalImage: NSImage?) {
        if let finalImage = finalImage {
            ClipboardManager.copyToClipboard(image: finalImage)
            HistoryManager.shared.add(image: finalImage)
            ToastWindow.show()
        }
        overlayController = nil
    }

    private func openSettings() {
        SettingsWindowController.shared.showAsSettings()
    }
}
