import AppKit

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    var onMenuBarToggle: ((Bool) -> Void)?
    var onLaunch: (() -> Void)?

    private var settingsView: SettingsView!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "capcap Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        super.init(window: window)

        settingsView = SettingsView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        settingsView.onMenuBarToggle = { [weak self] visible in
            self?.onMenuBarToggle?(visible)
        }
        settingsView.onLaunch = { [weak self] in
            self?.window?.close()
            self?.onLaunch?()
        }
        window.contentView = settingsView
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAsStartupDialog() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let accessibilityGranted = AXIsProcessTrusted()
        let screenRecordingGranted = settingsView.checkScreenRecordingPermission()
        if !accessibilityGranted || !screenRecordingGranted {
            NSApp.terminate(nil)
        }
    }
}
