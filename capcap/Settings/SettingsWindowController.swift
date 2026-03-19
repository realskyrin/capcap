import AppKit

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "capcap Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let settingsView = SettingsView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        window.contentView = settingsView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
