import AppKit

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    var onMenuBarToggle: ((Bool) -> Void)?
    var onLaunch: (() -> Void)?

    private var settingsView: SettingsView!
    private var isStartup = true

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settingsTitle
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal

        super.init(window: window)

        NotificationCenter.default.addObserver(forName: .languageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.window?.title = L10n.settingsTitle
        }

        settingsView = SettingsView(frame: NSRect(x: 0, y: 0, width: 420, height: 460), isStartup: true)
        settingsView.onMenuBarToggle = { [weak self] visible in
            self?.onMenuBarToggle?(visible)
        }
        settingsView.onLaunch = { [weak self] in
            self?.isStartup = false
            self?.settingsView.setStartupMode(false)
            self?.resizeWindow(height: 380)
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
        isStartup = true
        settingsView.setStartupMode(true)
        resizeWindow(height: 460)
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAsSettings() {
        isStartup = false
        settingsView.setStartupMode(false)
        resizeWindow(height: 380)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizeWindow(height: CGFloat) {
        guard let window = window else { return }
        var frame = window.frame
        let delta = height - frame.size.height
        frame.size.height = height
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: false)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard isStartup else { return }
        let accessibilityGranted = AXIsProcessTrusted()
        let screenRecordingGranted = settingsView.checkScreenRecordingPermission()
        if !accessibilityGranted || !screenRecordingGranted {
            NSApp.terminate(nil)
        }
    }
}
