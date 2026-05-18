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
            dismissClearingSource()
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

    func dismissClearingSource() {
        clearSource()
        dismiss()
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
        window.isMovableByWindowBackground = false
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
        window.makeFirstResponder(contentView)
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

// MARK: - Pin Content View (zoomable image with floating controls)

private enum PinZoom {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 5.0
    static let buttonStep: CGFloat = 0.1
    static let wheelSensitivity: CGFloat = 0.002
    static let compactTopGap: CGFloat = 8
}

final class PinContentView: NSView {
    var image: NSImage? {
        didSet {
            zoomScale = 1.0
            panOffset = .zero
            needsDisplay = true
        }
    }
    weak var pinWindow: PinWindow?

    private let toolbar = PinToolbarView()
    private var zoomScale: CGFloat = 1.0 {
        didSet {
            toolbar.zoomScale = zoomScale
            needsDisplay = true
        }
    }
    private var panOffset: NSPoint = .zero {
        didSet { needsDisplay = true }
    }
    private var panStartPoint: NSPoint?
    private var panStartOffset: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupToolbar() {
        toolbar.onMoveMouseDown = { [weak self] event in
            self?.pinWindow?.performDrag(with: event)
        }
        toolbar.onZoomOut = { [weak self] in
            self?.adjustZoom(by: -PinZoom.buttonStep)
        }
        toolbar.onZoomIn = { [weak self] in
            self?.adjustZoom(by: PinZoom.buttonStep)
        }
        toolbar.onClose = { [weak self] in
            self?.pinWindow?.dismiss()
        }
        addSubview(toolbar)
    }

    override func layout() {
        super.layout()
        let toolbarWidth = min(PinToolbarView.preferredWidth, max(PinToolbarView.minimumWidth, bounds.width - 12))
        let toolbarHeight = PinToolbarView.preferredHeight
        toolbar.frame = NSRect(
            x: (bounds.width - toolbarWidth) / 2,
            y: max(4, bounds.height - toolbarHeight - 8),
            width: toolbarWidth,
            height: toolbarHeight
        )
        panOffset = clampedPanOffset(panOffset, scale: zoomScale)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            pinWindow?.dismissClearingSource()
        case 53: // Esc — close only.
            pinWindow?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        panStartPoint = convert(event.locationInWindow, from: nil)
        panStartOffset = panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = panStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let proposed = NSPoint(
            x: panStartOffset.x + point.x - start.x,
            y: panStartOffset.y + point.y - start.y
        )
        panOffset = clampedPanOffset(proposed, scale: zoomScale)
    }

    override func mouseUp(with event: NSEvent) {
        panStartPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }

        let normalizedDelta = event.hasPreciseScrollingDeltas ? delta : delta * 10
        let factor = pow(1 + PinZoom.wheelSensitivity, normalizedDelta)
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(zoomScale * factor, anchor: anchor)
    }

    override func magnify(with event: NSEvent) {
        let factor = max(0.1, 1 + event.magnification)
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(zoomScale * factor, anchor: anchor)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let context = NSGraphicsContext.current
        let oldInterpolation = context?.imageInterpolation
        context?.imageInterpolation = .high
        image.draw(in: imageRect())
        if let oldInterpolation {
            context?.imageInterpolation = oldInterpolation
        }
    }

    private func adjustZoom(by delta: CGFloat) {
        setZoom(zoomScale + delta, anchor: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    private func setZoom(_ proposedScale: CGFloat, anchor: NSPoint) {
        let newScale = min(max(proposedScale, PinZoom.minScale), PinZoom.maxScale)
        guard abs(newScale - zoomScale) > 0.001 else { return }

        let oldScale = zoomScale
        let oldBaseRect = baseImageRect(scale: oldScale)
        let newBaseRect = baseImageRect(scale: newScale)
        let oldBaseCenter = NSPoint(x: oldBaseRect.midX, y: oldBaseRect.midY)
        let newBaseCenter = NSPoint(x: newBaseRect.midX, y: newBaseRect.midY)
        let anchorFromImageCenter = NSPoint(
            x: anchor.x - oldBaseCenter.x - panOffset.x,
            y: anchor.y - oldBaseCenter.y - panOffset.y
        )
        let ratio = newScale / oldScale

        zoomScale = newScale
        panOffset = clampedPanOffset(
            NSPoint(
                x: anchor.x - newBaseCenter.x - anchorFromImageCenter.x * ratio,
                y: anchor.y - newBaseCenter.y - anchorFromImageCenter.y * ratio
            ),
            scale: newScale
        )
    }

    private func imageRect() -> NSRect {
        baseImageRect(scale: zoomScale).offsetBy(dx: panOffset.x, dy: panOffset.y)
    }

    private func baseImageRect(scale: CGFloat) -> NSRect {
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        if scale < 1 {
            let topY = toolbar.frame.minY - PinZoom.compactTopGap
            return NSRect(
                x: bounds.midX - size.width / 2,
                y: topY - size.height,
                width: size.width,
                height: size.height
            )
        }

        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clampedPanOffset(_ offset: NSPoint, scale: CGFloat) -> NSPoint {
        let maxX = max(0, (bounds.width * scale - bounds.width) / 2)
        let maxY = max(0, (bounds.height * scale - bounds.height) / 2)
        return NSPoint(
            x: min(max(offset.x, -maxX), maxX),
            y: min(max(offset.y, -maxY), maxY)
        )
    }
}

// MARK: - Pin Toolbar

private final class PinToolbarView: NSView {
    static let preferredWidth: CGFloat = 186
    static let minimumWidth: CGFloat = 142
    static let preferredHeight: CGFloat = 34

    var onMoveMouseDown: ((NSEvent) -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onClose: (() -> Void)?

    var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomLabel.stringValue = "\(Int(round(zoomScale * 100)))%"
        }
    }

    private let moveButton = PinToolbarMoveButton(symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                                  accessibilityLabel: "Move pinned image")
    private let zoomOutButton = PinToolbarIconButton(symbolName: "minus", accessibilityLabel: "Zoom out")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let zoomInButton = PinToolbarIconButton(symbolName: "plus", accessibilityLabel: "Zoom in")
    private let closeButton = PinToolbarIconButton(symbolName: "xmark",
                                                   accessibilityLabel: "Close pinned image")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        moveButton.onMouseDown = { [weak self] event in
            self?.onMoveMouseDown?(event)
        }

        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTapped)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        zoomLabel.alignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        zoomLabel.backgroundColor = .clear
        zoomLabel.isBezeled = false
        zoomLabel.isEditable = false
        zoomLabel.isSelectable = false

        addSubview(moveButton)
        addSubview(zoomOutButton)
        addSubview(zoomLabel)
        addSubview(zoomInButton)
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()

        let buttonSide = min(28, max(22, bounds.height - 6))
        let buttonY = (bounds.height - buttonSide) / 2
        let horizontalInset: CGFloat = 4
        let gap: CGFloat = 8

        moveButton.frame = NSRect(x: horizontalInset, y: buttonY, width: buttonSide, height: buttonSide)
        closeButton.frame = NSRect(
            x: bounds.width - horizontalInset - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )

        let centerX = moveButton.frame.maxX + gap
        let centerWidth = max(72, closeButton.frame.minX - gap - centerX)
        let stepWidth = min(24, max(20, centerWidth * 0.22))
        let labelWidth = max(36, centerWidth - stepWidth * 2)

        zoomOutButton.frame = NSRect(x: centerX, y: buttonY, width: stepWidth, height: buttonSide)
        zoomLabel.frame = NSRect(x: zoomOutButton.frame.maxX, y: buttonY + 5,
                                 width: labelWidth, height: buttonSide - 10)
        zoomInButton.frame = NSRect(x: zoomLabel.frame.maxX, y: buttonY,
                                    width: stepWidth, height: buttonSide)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        NSColor(white: 0.08, alpha: 0.78).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    @objc private func zoomOutTapped() {
        onZoomOut?()
    }

    @objc private func zoomInTapped() {
        onZoomIn?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

private class PinToolbarIconButton: NSButton {
    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        focusRingType = .none
        contentTintColor = NSColor.white.withAlphaComponent(0.88)
        setAccessibilityLabel(accessibilityLabel)

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            self.image = image.withSymbolConfiguration(config)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }
}

private final class PinToolbarMoveButton: PinToolbarIconButton {
    var onMouseDown: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
}
