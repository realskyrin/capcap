import AppKit

/// Where a pinned image was loaded from — drives the X-key "close and clear
/// source" behavior so a stale Finder selection or clipboard image won't keep
/// re-pinning on the next hotkey press.
enum PinSource {
    case finder
    case clipboard
}

/// A borderless, always-on-top window that holds a pinned image. Unlike a plain
/// borderless `NSWindow` it can become key, so it receives keystrokes: Esc
/// closes it, X closes it and clears the source it came from.
final class PinWindow: NSWindow {
    /// Set when the pin came from a hotkey press. nil for editor-created pins,
    /// which have no external source to clear.
    var pinSource: PinSource?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            clearSource()
            dismiss()
        case 53: // Esc — close only.
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    /// Tears the window down and drops it from the manager so it deallocates.
    func dismiss() {
        orderOut(nil)
        contentView = nil
        PinWindowManager.shared.remove(self)
    }

    private func clearSource() {
        switch pinSource {
        case .finder:
            FinderSelection.clearSelection()
        case .clipboard:
            ClipboardImageSource.clear()
        case nil:
            break
        }
    }
}

/// Builds pinned-image windows. Used both by the editor's pin button and by the
/// global pin hotkey.
enum PinLauncher {
    /// Pins the image currently selected in Finder, or — failing that — the
    /// image on the clipboard, onto the screen. Shows a toast on success or
    /// when neither source has an image. Returns true if something was pinned.
    @discardableResult
    static func pinFromSourcesIfAvailable() -> Bool {
        if let url = FinderSelection.currentImageFileURL(),
           let image = NSImage(contentsOf: url),
           image.size.width > 0, image.size.height > 0 {
            pin(image: image, source: .finder)
            ToastWindow.show(message: L10n.pinFromFinderHint)
            return true
        }

        if let image = ClipboardImageSource.currentImage() {
            pin(image: image, source: .clipboard)
            ToastWindow.show(message: L10n.pinFromClipboardHint)
            return true
        }

        ToastWindow.show(message: L10n.pinNoImage)
        return false
    }

    /// Creates a floating pinned window for `image`. When `origin` is nil the
    /// window is centered on the screen under the cursor. Oversized images are
    /// scaled down to fit the screen.
    static func pin(image: NSImage, at origin: NSPoint? = nil, source: PinSource? = nil) {
        let size = fittedSize(for: image.size)
        let frameOrigin = origin ?? centeredOrigin(for: size)

        let window = PinWindow(
            contentRect: NSRect(origin: frameOrigin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.pinSource = source

        let contentView = PinContentView(frame: NSRect(origin: .zero, size: size))
        contentView.image = image
        contentView.pinWindow = window
        window.contentView = contentView

        PinWindowManager.shared.add(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    private static func activeScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Scales `size` down to fit within the active screen (with a margin),
    /// keeping the aspect ratio. Returns it unchanged when it already fits.
    private static func fittedSize(for size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let frame = activeScreen().visibleFrame
        let maxWidth = max(200, frame.width - 80)
        let maxHeight = max(200, frame.height - 80)
        let ratio = min(1.0, min(maxWidth / size.width, maxHeight / size.height))
        if ratio >= 1.0 { return size }
        return NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private static func centeredOrigin(for size: NSSize) -> NSPoint {
        let frame = activeScreen().visibleFrame
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
    }
}

// MARK: - Pin Window Manager (retains all pinned windows)

final class PinWindowManager {
    static let shared = PinWindowManager()
    private var windows: [NSWindow] = []

    func add(_ window: NSWindow) {
        windows.append(window)
    }

    func remove(_ window: NSWindow) {
        windows.removeAll { $0 === window }
    }
}

// MARK: - Pin Content View (draggable image with hover close button)

final class PinContentView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    weak var pinWindow: PinWindow?

    private var closeButton: NSButton?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupCloseButton()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCloseButton() {
        let btn = NSButton(frame: NSRect(x: 4, y: bounds.height - 24, width: 20, height: 20))
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 10
        btn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            btn.image = img.withSymbolConfiguration(config)
        }
        btn.contentTintColor = .white
        btn.target = self
        btn.action = #selector(closeTapped)
        btn.isHidden = true
        btn.autoresizingMask = [.minYMargin]
        addSubview(btn)
        closeButton = btn
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton?.isHidden = true
    }

    @objc private func closeTapped() {
        pinWindow?.dismiss()
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }

    // Allow window dragging by background.
    override func mouseDown(with event: NSEvent) {
        pinWindow?.performDrag(with: event)
    }
}
