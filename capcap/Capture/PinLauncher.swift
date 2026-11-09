import AppKit

/// Where a pinned image was loaded from — drives the X-key "close and clear
/// source" behavior so a stale Finder selection or clipboard image won't keep
/// re-pinning on the next hotkey press.
enum PinSource {
    case finder
    case clipboard
    case clipboardText
}

/// A borderless, always-on-top window that holds a pinned image. Unlike a plain
/// borderless `NSWindow` it can become key, so it receives keystrokes: Esc
/// closes it, X closes it and clears the source it came from.
final class PinWindow: NSWindow {
    /// Set when the pin came from a hotkey press. nil for editor-created pins,
    /// which have no external source to clear.
    var pinSource: PinSource?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        (contentView as? TextPinContentView)?.commitTextEditingIfNeeded()
    }

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
        case .clipboard, .clipboardText:
            ClipboardImageSource.clear()
        case nil:
            break
        }
    }
}

/// Builds pinned-image windows. Used by the editor's pin button and by the
/// source-specific global pin hotkeys.
enum PinLauncher {
    private static let stackOffset = NSSize(width: 28, height: -28)
    private static let maxDistinctStackOffsets = 8

    /// Pins images currently selected in Finder. This shortcut is intentionally
    /// source-specific: it does not fall back to the clipboard.
    @discardableResult
    static func pinSelectedImagesIfAvailable() -> Bool {
        let finderImages = FinderSelection.currentImageFileURLs().compactMap(loadImage)
        guard !finderImages.isEmpty else {
            ToastWindow.show(message: L10n.selectedImagePinNoImage)
            return false
        }

        pin(images: finderImages, source: .finder)
        ToastWindow.show(message: L10n.pinFromFinderHint)
        return true
    }

    /// Pins the image currently on the clipboard. This shortcut is
    /// source-specific: it does not check the Finder selection.
    @discardableResult
    static func pinClipboardImageIfAvailable() -> Bool {
        guard let image = ClipboardImageSource.currentImage() else {
            ToastWindow.show(message: L10n.clipboardImagePinNoImage)
            return false
        }

        pin(image: image, source: .clipboard)
        ToastWindow.show(message: L10n.pinFromClipboardHint)
        return true
    }

    /// Pins plain text currently on the clipboard as an editable text view.
    @discardableResult
    static func pinClipboardTextIfAvailable() -> Bool {
        guard let text = ClipboardTextSource.currentText() else {
            ToastWindow.show(message: L10n.clipboardTextPinNoText)
            return false
        }

        pin(text: text, source: .clipboardText)
        ToastWindow.show(message: L10n.pinFromClipboardTextHint)
        return true
    }

    /// Creates a floating pinned window for `image`. When `origin` is nil the
    /// window is centered on the screen under the cursor. Oversized images are
    /// scaled down to fit the screen. The original image is saved to history
    /// unless the caller is pinning an existing history entry.
    static func pin(
        image: NSImage,
        at origin: NSPoint? = nil,
        source: PinSource? = nil,
        saveToHistory: Bool = true
    ) {
        let screen = activeScreen()
        let size = fittedSize(for: image.size, on: screen)
        let frameOrigin = origin ?? centeredOrigin(for: size, on: screen)

        makeWindow(
            image: image,
            size: size,
            origin: frameOrigin,
            source: source,
            saveToHistory: saveToHistory
        )
    }

    /// Creates a floating editable text pin backed by a regular AppKit text view.
    static func pin(text: String, at origin: NSPoint? = nil, source: PinSource? = nil) {
        let previewText = TextPinLayout.previewText(text)
        guard !previewText.isEmpty else { return }
        let screen = activeScreen()
        let size = TextPinLayout.size(
            for: previewText,
            maxWidth: TextPinLayout.maxWidth(on: screen)
        )
        let fittedSize = fittedSize(for: size, on: screen)
        let frameOrigin = origin ?? centeredOrigin(for: fittedSize, on: screen)

        makeTextWindow(text: previewText, size: fittedSize, origin: frameOrigin, source: source)
    }

    private static func pin(images: [NSImage], source: PinSource) {
        let screen = activeScreen()
        let pins = images.compactMap { image -> (image: NSImage, size: NSSize)? in
            let size = fittedSize(for: image.size, on: screen)
            guard size.width > 0, size.height > 0 else { return nil }
            return (image, size)
        }
        guard let first = pins.first else { return }

        let baseOrigin = centeredOrigin(for: first.size, on: screen)
        for (index, pin) in pins.enumerated() {
            let origin = stackedOrigin(baseOrigin: baseOrigin, index: index, size: pin.size, on: screen)
            makeWindow(
                image: pin.image,
                size: pin.size,
                origin: origin,
                source: source,
                saveToHistory: true
            )
        }
    }

    private static func makeWindow(
        image: NSImage,
        size: NSSize,
        origin: NSPoint,
        source: PinSource?,
        saveToHistory: Bool
    ) {
        let window = PinWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        if Defaults.pinAcrossSpaces {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        // A transparent image already owns its visible silhouette (and window
        // captures commonly include their own soft shadow inside transparent
        // padding). Asking WindowServer for another shadow outlines the pin's
        // rectangular backing window, leaving a dark seam just outside the
        // image's original shadow. Keep the native lift for opaque screenshots
        // only; transparent pins must composite exactly as their pixels specify.
        window.hasShadow = shouldUseSystemWindowShadow(for: image)
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

        if saveToHistory {
            HistoryManager.shared.add(image: image)
        }
    }

    private static func makeTextWindow(
        text: String,
        size: NSSize,
        origin: NSPoint,
        source: PinSource?
    ) {
        let window = PinWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        if Defaults.pinAcrossSpaces {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.pinSource = source

        let contentView = TextPinContentView(
            text: text,
            frame: NSRect(origin: .zero, size: size)
        )
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

    private static func loadImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage.imagePreservingPixelDimensions(from: data),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
    }

    static func shouldUseSystemWindowShadow(for image: NSImage) -> Bool {
        guard let cgImage = image.cgImagePreservingBacking() else { return true }

        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }

        let maxX = cgImage.width - 1
        let maxY = cgImage.height - 1
        guard maxX >= 0, maxY >= 0 else { return true }

        let samplePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: maxX, y: 0),
            CGPoint(x: 0, y: maxY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: maxX / 2, y: 0),
            CGPoint(x: maxX / 2, y: maxY),
            CGPoint(x: 0, y: maxY / 2),
            CGPoint(x: maxX, y: maxY / 2),
        ]

        for point in samplePoints {
            guard let alpha = alphaValue(in: cgImage, at: point) else { return true }
            if alpha < 255 {
                return false
            }
        }
        return true
    }

    private static func alphaValue(in image: CGImage, at point: CGPoint) -> UInt8? {
        guard let pixelImage = image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))) else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        let didDraw = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return didDraw ? pixel[3] : nil
    }

    /// Scales `size` down to fit within the active screen (with a margin),
    /// keeping the aspect ratio. Returns it unchanged when it already fits.
    private static func fittedSize(for size: NSSize, on screen: NSScreen) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let frame = screen.visibleFrame
        let maxWidth = max(200, frame.width - 80)
        let maxHeight = max(200, frame.height - 80)
        let ratio = min(1.0, min(maxWidth / size.width, maxHeight / size.height))
        if ratio >= 1.0 { return size }
        return NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private static func centeredOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
    }

    private static func stackedOrigin(
        baseOrigin: NSPoint,
        index: Int,
        size: NSSize,
        on screen: NSScreen
    ) -> NSPoint {
        let distinctIndex = index % maxDistinctStackOffsets
        let wrapIndex = index / maxDistinctStackOffsets
        let proposed = NSPoint(
            x: baseOrigin.x + CGFloat(distinctIndex) * stackOffset.width + CGFloat(wrapIndex) * 10,
            y: baseOrigin.y + CGFloat(distinctIndex) * stackOffset.height - CGFloat(wrapIndex) * 10
        )
        return clampedOrigin(proposed, size: size, on: screen)
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let maxX = max(frame.minX, frame.maxX - size.width)
        let maxY = max(frame.minY, frame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
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

// MARK: - Text Pin

private enum TextPinLayout {
    static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let minWidth: CGFloat = 220
    private static let maxPreferredWidth: CGFloat = 560
    private static let minHeight: CGFloat = 72
    private static let contentInset: CGFloat = 17
    private static let padding = NSEdgeInsets(
        top: contentInset,
        left: contentInset,
        bottom: contentInset,
        right: contentInset
    )

    static func maxWidth(on screen: NSScreen) -> CGFloat {
        min(maxPreferredWidth, max(minWidth, screen.visibleFrame.width - 80))
    }

    static func size(for text: String, maxWidth: CGFloat) -> NSSize {
        let attributes = textAttributes()
        let normalized = normalizedText(text)
        let availableWidth = max(120, maxWidth - padding.left - padding.right)
        let measured = (normalized as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let contentWidth = min(availableWidth, max(1, ceil(measured.width)))
        let width = ceil(min(maxWidth, max(minWidth, contentWidth + padding.left + padding.right)))
        let wrappedWidth = max(120, width - padding.left - padding.right)
        let usedRect = textSystemUsedRect(for: normalized, width: wrappedWidth)
        let textHeight = max(1, ceil(usedRect.height))
        let height = ceil(max(minHeight, textHeight + padding.top + padding.bottom))
        return NSSize(width: width, height: height)
    }

    static func textFrame(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + padding.left,
            y: bounds.minY + padding.bottom,
            width: max(1, bounds.width - padding.left - padding.right),
            height: max(1, bounds.height - padding.top - padding.bottom)
        )
    }

    static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func previewText(_ text: String) -> String {
        var normalized = normalizedText(text)
        while normalized.last?.isWhitespace == true {
            normalized.removeLast()
        }
        return normalized
    }

    static func textAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        return [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
            .paragraphStyle: paragraph,
        ]
    }

    static func configure(_ textView: NSTextView, text: String) {
        let attributed = NSAttributedString(
            string: normalizedText(text),
            attributes: textAttributes()
        )
        textView.textStorage?.setAttributedString(attributed)
        textView.font = font
        textView.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        textView.typingAttributes = textAttributes()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(1, textView.bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    static func drawBackground(in bounds: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 10,
            yRadius: 10
        )
        NSColor(calibratedWhite: 0.98, alpha: 0.97).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.12, alpha: 0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func renderImage(for text: String, size: NSSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        drawBackground(in: bounds)
        (normalizedText(text) as NSString).draw(
            with: textFrame(in: bounds),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes()
        )
        image.unlockFocus()
        return image
    }

    private static func textSystemUsedRect(for text: String, width: CGFloat) -> NSRect {
        let storage = NSTextStorage(string: normalizedText(text), attributes: textAttributes())
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container)
    }
}

private final class TextPinContentView: NSView, NSTextViewDelegate {
    weak var pinWindow: PinWindow?

    private let toolbar = TextPinToolbarView()
    private let displayTextView = TextPinDisplayTextView()
    private var text: String
    private var trackingArea: NSTrackingArea?
    private var isToolbarVisible = false
    private var isEndingTextEditing = false
    private var committedTextDuringEditing = false

    override var acceptsFirstResponder: Bool { true }

    init(text: String, frame frameRect: NSRect) {
        self.text = text
        super.init(frame: frameRect)
        wantsLayer = true
        setupDisplayTextView()
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        TextPinLayout.drawBackground(in: bounds)
    }

    override func layout() {
        super.layout()
        layoutDisplayTextView()
        layoutToolbar()
        refreshToolbarVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isTextEditing else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        pinWindow?.performDrag(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolbarVisibility(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolbarVisibility(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateToolbarVisibility(for: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolbarVisibility()
    }

    private func setupDisplayTextView() {
        displayTextView.isEditable = false
        displayTextView.isSelectable = false
        displayTextView.isRichText = false
        displayTextView.importsGraphics = false
        displayTextView.drawsBackground = false
        displayTextView.insertionPointColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        displayTextView.textContainer?.widthTracksTextView = true
        displayTextView.textContainer?.containerSize = NSSize(
            width: max(1, bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        displayTextView.onMouseDown = { [weak self] event in
            self?.handleDisplayMouseDown(event)
        }
        displayTextView.onPointerEvent = { [weak self] event in
            self?.updateToolbarVisibility(for: event)
        }
        displayTextView.onCommit = { [weak self] in self?.commitTextEditingIfNeeded() }
        displayTextView.onCancel = { [weak self] in self?.cancelTextEditing() }
        displayTextView.delegate = self
        TextPinLayout.configure(displayTextView, text: text)
        addSubview(displayTextView)
    }

    private func layoutDisplayTextView() {
        displayTextView.frame = TextPinLayout.textFrame(in: bounds)
        displayTextView.textContainer?.containerSize = NSSize(
            width: max(1, displayTextView.bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func handleDisplayMouseDown(_ event: NSEvent) {
        if isTextEditing {
            return
        }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            beginTextEditing()
            displayTextView.forwardEditingMouseDown(with: event)
            return
        }
        pinWindow?.performDrag(with: event)
    }

    private func setupToolbar() {
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        toolbar.onClose = { [weak self] in
            self?.pinWindow?.dismissClearingSource()
        }
        toolbar.onEdit = { [weak self] in
            self?.editTextImage()
        }
        toolbar.onEditText = { [weak self] in
            self?.beginTextEditingFromToolbar()
        }
        toolbar.onPointerEvent = { [weak self] event in
            self?.updateToolbarVisibility(for: event)
        }
        addSubview(toolbar)
    }

    private func layoutToolbar() {
        toolbar.frame = NSRect(
            x: 8,
            y: max(8, bounds.height - TextPinToolbarView.preferredHeight - 8),
            width: TextPinToolbarView.preferredWidth,
            height: TextPinToolbarView.preferredHeight
        )
    }

    private var isTextEditing: Bool {
        displayTextView.isTextEditing
    }

    private func updateToolbarVisibility(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setToolbarVisible(bounds.contains(point))
    }

    private func refreshToolbarVisibility() {
        guard let window else {
            setToolbarVisible(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setToolbarVisible(bounds.contains(point))
    }

    private func setToolbarVisible(_ visible: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        toolbar.isHidden = !visible
        toolbar.alphaValue = visible ? 1 : 0
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7:
            pinWindow?.dismissClearingSource()
        case 53:
            pinWindow?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard isTextEditing, !isEndingTextEditing, !committedTextDuringEditing else { return }
        commitTextEditingIfNeeded()
    }

    func textDidChange(_ notification: Notification) {
        resizeForLiveTextEditing()
    }

    private func beginTextEditing() {
        guard !isTextEditing else { return }
        committedTextDuringEditing = false
        displayTextView.isTextEditing = true
        displayTextView.isEditable = true
        displayTextView.isSelectable = true
        window?.makeFirstResponder(displayTextView)
    }

    private func beginTextEditingFromToolbar() {
        beginTextEditing()
        displayTextView.setSelectedRange(NSRange(location: displayTextView.string.utf16.count, length: 0))
    }

    @discardableResult
    func commitTextEditingIfNeeded() -> Bool {
        guard isTextEditing else { return true }
        committedTextDuringEditing = true
        let updatedText = TextPinLayout.previewText(displayTextView.string)
        endTextEditing()

        guard !updatedText.isEmpty else {
            pinWindow?.dismissClearingSource()
            return false
        }

        text = updatedText
        updateDisplayTextAndResize()
        return true
    }

    private func cancelTextEditing() {
        guard isTextEditing else { return }
        TextPinLayout.configure(displayTextView, text: text)
        endTextEditing()
        updateDisplayTextAndResize()
    }

    private func endTextEditing() {
        isEndingTextEditing = true
        displayTextView.isTextEditing = false
        displayTextView.isEditable = false
        displayTextView.isSelectable = false
        window?.makeFirstResponder(self)
        isEndingTextEditing = false
    }

    private func updateDisplayTextAndResize() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let targetSize = targetTextSize(for: text, on: screen)
        resizeWindow(to: targetSize, on: screen)
        frame = NSRect(origin: .zero, size: targetSize)
        TextPinLayout.configure(displayTextView, text: text)
        layoutDisplayTextView()
        needsDisplay = true
    }

    private func resizeForLiveTextEditing() {
        guard isTextEditing else { return }
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let selection = displayTextView.selectedRange()
        let targetSize = targetTextSize(for: displayTextView.string, on: screen)
        let shouldResize = abs(targetSize.width - bounds.width) > 0.5 ||
            abs(targetSize.height - bounds.height) > 0.5

        if shouldResize {
            resizeWindow(to: targetSize, on: screen)
            frame = NSRect(origin: .zero, size: targetSize)
            layoutDisplayTextView()
            needsDisplay = true
        }

        displayTextView.setSelectedRange(selection)
        displayTextView.ensureSelectionVisible()
    }

    private func targetTextSize(for string: String, on screen: NSScreen) -> NSSize {
        fittedSize(
            for: TextPinLayout.size(
                for: string,
                maxWidth: TextPinLayout.maxWidth(on: screen)
            ),
            on: screen
        )
    }

    private func resizeWindow(to targetSize: NSSize, on screen: NSScreen) {
        guard let window else {
            setFrameSize(targetSize)
            return
        }

        let current = window.frame
        var targetFrame = NSRect(
            x: current.minX,
            y: current.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        targetFrame = clampedFrame(targetFrame, on: screen)
        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func fittedSize(for size: NSSize, on screen: NSScreen) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let frame = screen.visibleFrame
        let maxWidth = max(200, frame.width - 80)
        let maxHeight = max(200, frame.height - 80)
        let ratio = min(1.0, min(maxWidth / size.width, maxHeight / size.height))
        if ratio >= 1.0 { return size }
        return NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private func clampedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(result.minY, visible.minY), max(visible.minY, visible.maxY - result.height))
        return result
    }

    private func editTextImage() {
        guard commitTextEditingIfNeeded() else { return }
        guard let pinWindow,
              let appDelegate = NSApp.delegate as? AppDelegate,
              let image = TextPinLayout.renderImage(for: text, size: bounds.size)
        else { return }

        appDelegate.handlePinnedImageEditRequest(image) {
            pinWindow.dismiss()
        }
    }
}

private final class TextPinDisplayTextView: NSTextView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onPointerEvent: ((NSEvent) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var isTextEditing = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { isTextEditing }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent?(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerEvent?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent?(event)
    }

    override func mouseDown(with event: NSEvent) {
        onPointerEvent?(event)
        guard !isTextEditing else {
            super.mouseDown(with: event)
            return
        }
        onMouseDown?(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isTextEditing else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, modifiers.isEmpty {
            onCancel?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    func forwardEditingMouseDown(with event: NSEvent) {
        guard isTextEditing else { return }
        super.mouseDown(with: event)
    }

    func ensureSelectionVisible() {
        guard isTextEditing else { return }
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        scrollRangeToVisible(selectedRange())
    }
}

// MARK: - Pin Content View (zoomable image with floating controls)

private enum PinZoom {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 5.0
    static let wheelSensitivity: CGFloat = 0.002
    static let windowAnimationDuration: TimeInterval = 0.22
    static let windowAnimationFrameInterval: TimeInterval = 1.0 / 60.0
    static let interactivePreviewMaxPixelDimension = 1280
    static let interactivePreviewEndDelay: TimeInterval = 0.1
    static let toolbarAnimationDuration: TimeInterval = 0.16
    static let toolbarHoverDuration: TimeInterval = 2.0
}

enum PinImageLayout {
    static let fullNormalizedContentRect = NSRect(x: 0, y: 0, width: 1, height: 1)

    private static let contentAnalysisMaxPixelDimension = 1024
    private static let contentAlphaThreshold: UInt8 = 250
    private static let requiredOpaqueCoverage = 0.5

    static func scaledSize(baseSize: NSSize, scale: CGFloat) -> NSSize {
        guard baseSize.width > 0, baseSize.height > 0, scale > 0 else { return .zero }
        return NSSize(
            width: baseSize.width * scale,
            height: baseSize.height * scale
        )
    }

    static func resizedFrame(
        from currentFrame: NSRect,
        to targetSize: NSSize,
        focusing unitPoint: NSPoint? = nil
    ) -> NSRect {
        guard let unitPoint else {
            return NSRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - targetSize.height,
                width: targetSize.width,
                height: targetSize.height
            )
        }

        let focus = NSPoint(
            x: min(max(unitPoint.x, 0), 1),
            y: min(max(unitPoint.y, 0), 1)
        )
        let screenPoint = NSPoint(
            x: currentFrame.minX + focus.x * currentFrame.width,
            y: currentFrame.minY + focus.y * currentFrame.height
        )
        return NSRect(
            x: screenPoint.x - focus.x * targetSize.width,
            y: screenPoint.y - focus.y * targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    /// Finds the mostly opaque rectangular body of an image while ignoring
    /// transparent padding and soft screenshot shadows around its edges.
    /// The returned rect uses AppKit's bottom-left coordinate system.
    static func normalizedContentRect(for source: CGImage) -> NSRect {
        switch source.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return fullNormalizedContentRect
        default:
            break
        }

        let longestEdge = max(source.width, source.height)
        guard longestEdge > 0 else { return fullNormalizedContentRect }

        let analysisScale = min(
            1,
            CGFloat(contentAnalysisMaxPixelDimension) / CGFloat(longestEdge)
        )
        let width = max(1, Int((CGFloat(source.width) * analysisScale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * analysisScale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return fullNormalizedContentRect }

        var opaquePixelsByColumn = [Int](repeating: 0, count: width)
        var opaquePixelsByRow = [Int](repeating: 0, count: height)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                guard alpha >= contentAlphaThreshold else { continue }
                opaquePixelsByColumn[x] += 1
                opaquePixelsByRow[y] += 1
            }
        }

        // A screenshot body spans most of both axes; isolated opaque artwork
        // does not. This keeps transparent images from producing a misleading
        // toolbar anchor while reliably excluding rectangular window shadows.
        let requiredColumnCoverage = max(1, Int(ceil(CGFloat(height) * requiredOpaqueCoverage)))
        let requiredRowCoverage = max(1, Int(ceil(CGFloat(width) * requiredOpaqueCoverage)))
        guard let left = opaquePixelsByColumn.firstIndex(where: { $0 >= requiredColumnCoverage }),
              let right = opaquePixelsByColumn.lastIndex(where: { $0 >= requiredColumnCoverage }),
              let top = opaquePixelsByRow.firstIndex(where: { $0 >= requiredRowCoverage }),
              let bottom = opaquePixelsByRow.lastIndex(where: { $0 >= requiredRowCoverage })
        else {
            return fullNormalizedContentRect
        }

        return NSRect(
            x: CGFloat(left) / CGFloat(width),
            y: CGFloat(height - bottom - 1) / CGFloat(height),
            width: CGFloat(right - left + 1) / CGFloat(width),
            height: CGFloat(bottom - top + 1) / CGFloat(height)
        )
    }

    static func contentRect(
        in bounds: NSRect,
        normalizedContentRect: NSRect
    ) -> NSRect {
        let normalized = normalizedContentRect.standardized
            .intersection(fullNormalizedContentRect)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else {
            return bounds
        }

        return NSRect(
            x: bounds.minX + normalized.minX * bounds.width,
            y: bounds.minY + normalized.minY * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        )
    }

    static func toolbarFrame(
        in bounds: NSRect,
        preferredSize: NSSize,
        inset: CGFloat = 8
    ) -> NSRect {
        let width = min(preferredSize.width, bounds.width)
        let height = min(preferredSize.height, bounds.height)
        let x = bounds.width >= width + inset * 2 ? bounds.minX + inset : bounds.minX
        let yInset = bounds.height >= height + inset * 2 ? inset : 0
        return NSRect(
            x: x,
            y: max(bounds.minY, bounds.maxY - height - yInset),
            width: width,
            height: height
        )
    }
}

struct PinImageDragPayload {
    let pasteboardItem: NSPasteboardItem
    let temporaryFileURL: URL

    private static let defaultTemporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capcap-pin-drag", isDirectory: true)

    static func make(
        from image: NSImage,
        in directory: URL = defaultTemporaryDirectory
    ) -> PinImageDragPayload? {
        guard let pngData = image.pngDataPreservingBacking() else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fileURL = directory.appendingPathComponent(
                "capcap-pin-\(UUID().uuidString).png",
                isDirectory: false
            )
            try pngData.write(to: fileURL, options: .atomic)

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(fileURL.absoluteString, forType: .fileURL)
            pasteboardItem.setData(pngData, forType: .png)
            if let tiffData = image.tiffDataPreservingBacking() {
                pasteboardItem.setData(tiffData, forType: .tiff)
            }
            return PinImageDragPayload(
                pasteboardItem: pasteboardItem,
                temporaryFileURL: fileURL
            )
        } catch {
            return nil
        }
    }

    static func removeTemporaryFile(
        at fileURL: URL,
        after delay: TimeInterval = 600
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// Builds a small bitmap once so continuous zoom redraws do not repeatedly
/// resample the full-resolution source image on the main thread.
private enum PinInteractivePreviewRenderer {
    private static let queue = DispatchQueue(
        label: "capcap.pin.interactive-preview",
        qos: .userInitiated
    )

    static func makePreview(
        from source: CGImage,
        completion: @escaping (CGImage?) -> Void
    ) {
        let longestEdge = max(source.width, source.height)
        guard longestEdge > PinZoom.interactivePreviewMaxPixelDimension else {
            completion(source)
            return
        }

        let scale = CGFloat(PinZoom.interactivePreviewMaxPixelDimension) / CGFloat(longestEdge)
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))

        queue.async {
            let colorSpace = previewColorSpace(for: source)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            let preview = context.makeImage()
            DispatchQueue.main.async { completion(preview) }
        }
    }

    private static func previewColorSpace(for source: CGImage) -> CGColorSpace {
        guard let sourceColorSpace = source.colorSpace,
              sourceColorSpace.model == .rgb
        else {
            return CGColorSpaceCreateDeviceRGB()
        }

        guard CGColorSpaceUsesExtendedRange(sourceColorSpace) else {
            return sourceColorSpace
        }

        if sourceColorSpace.name == CGColorSpace.extendedDisplayP3 ||
           sourceColorSpace.name == CGColorSpace.extendedLinearDisplayP3 {
            return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}

final class PinContentView: NSView, NSDraggingSource {
    var image: NSImage? {
        didSet {
            prepareInteractivePreview(for: image)
            zoomScale = 1.0
            resetOCRSelection()
            needsDisplay = true
            needsLayout = true
            updateImageInteractionGeometry()
        }
    }
    weak var pinWindow: PinWindow?

    private let baseImageSize: NSSize
    private let toolbar = PinToolbarView()
    private let ocrOverlay: OCRLineSelectionOverlayView
    private var zoomScale: CGFloat = 1.0 {
        didSet {
            toolbar.zoomScale = zoomScale
            needsDisplay = true
        }
    }
    private var interactivePreviewImage: NSImage?
    private var interactivePreviewGeneration = UUID()
    private var interactiveZoomEndTimer: Timer?
    private var windowAnimationTimer: Timer?
    private var windowAnimationGeneration = UUID()
    private var windowAnimationTargetFrame: NSRect?
    private var isZoomingInteractively = false {
        didSet {
            guard isZoomingInteractively != oldValue else { return }
            refreshOCROverlayVisibility()
            needsDisplay = true
            refreshToolbarVisibility(animated: true)
        }
    }
    private var isWindowAnimating = false {
        didSet {
            guard isWindowAnimating != oldValue else { return }
            refreshOCROverlayVisibility()
            needsDisplay = true
            refreshToolbarVisibility(animated: true)
        }
    }
    private var usesLowResolutionPreview: Bool {
        isZoomingInteractively || isWindowAnimating
    }
    private var normalizedImageContentRect = PinImageLayout.fullNormalizedContentRect
    private var dragTemporaryFileURLs: [ObjectIdentifier: URL] = [:]
    private var imageTrackingArea: NSTrackingArea?
    private var isToolbarVisible = false
    private var toolbarAutoHideTimer: Timer?
    private var toolbarIsSuppressedAfterAutoHide = false
    private var isOCRSelectionEnabled = false {
        didSet {
            toolbar.isOCRActive = isOCRSelectionEnabled
            refreshOCROverlayVisibility()
        }
    }
    private var hasOCRResult = false
    private var ocrProviderKind: OCRProviderKind?
    private var ocrRunID = UUID()
    private var ocrRecognitionTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        baseImageSize = frame.size
        ocrOverlay = OCRLineSelectionOverlayView(imageSize: frame.size)
        super.init(frame: frame)
        setupOCROverlay()
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        interactiveZoomEndTimer?.invalidate()
        windowAnimationTimer?.invalidate()
        toolbarAutoHideTimer?.invalidate()
        ocrRecognitionTask?.cancel()
    }

    private func setupOCROverlay() {
        ocrOverlay.isHidden = true
        ocrOverlay.showsLineBoxes = false
        ocrOverlay.onSelectText = { text, lineIndices, isFinal in
            guard isFinal else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            ToastWindow.show(
                message: lineIndices.count == 1 ? L10n.ocrLineCopied : L10n.ocrCopied,
                duration: 0.9
            )
        }
        addSubview(ocrOverlay)
    }

    private func setupToolbar() {
        toolbar.alphaValue = 0
        toolbar.isHidden = true

        toolbar.onEdit = { [weak self] in
            self?.editPinnedImage()
        }
        toolbar.onOCR = { [weak self] in
            self?.toggleOCRSelection()
        }
        toolbar.onCopy = { [weak self] in
            self?.copyPinnedImage()
        }
        toolbar.onDrag = { [weak self] event in
            self?.beginPinnedImageDrag(with: event)
        }
        toolbar.onResetZoom = { [weak self] in
            self?.resetZoomTo100Percent()
        }
        toolbar.onClose = { [weak self] in
            self?.pinWindow?.dismiss()
        }
        toolbar.onPointerEvent = { [weak self] in
            self?.refreshToolbarVisibility(animated: true)
        }
        toolbar.onScrollWheel = { [weak self] event in
            self?.handleScrollWheel(event, focusesAtEventLocation: false)
        }
        toolbar.onMagnify = { [weak self] event in
            self?.handleMagnify(event, focusesAtEventLocation: false)
        }
        addSubview(toolbar)
    }

    private func copyPinnedImage() {
        guard let image else { return }
        ClipboardManager.copyToClipboard(image: image)
        if Defaults.showCopyToast {
            ToastWindow.show()
        }
    }

    private func beginPinnedImageDrag(with event: NSEvent) {
        guard !usesLowResolutionPreview,
              let image,
              let payload = PinImageDragPayload.make(from: image)
        else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let imageSize = image.size
        let previewScale: CGFloat
        if imageSize.width > 0, imageSize.height > 0 {
            previewScale = min(1, 180 / imageSize.width, 120 / imageSize.height)
        } else {
            previewScale = 1
        }
        let previewSize = NSSize(
            width: max(1, imageSize.width * previewScale),
            height: max(1, imageSize.height * previewScale)
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: payload.pasteboardItem)
        draggingItem.setDraggingFrame(
            NSRect(
                x: location.x - previewSize.width / 2,
                y: location.y - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: image
        )

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        dragTemporaryFileURLs[ObjectIdentifier(session)] = payload.temporaryFileURL
    }

    private func editPinnedImage() {
        guard let image,
              let pinWindow,
              let appDelegate = NSApp.delegate as? AppDelegate
        else {
            return
        }

        let imageForEditing = image.copy() as? NSImage ?? image
        appDelegate.handlePinnedImageEditRequest(imageForEditing) {
            pinWindow.dismiss()
        }
    }

    private func prepareInteractivePreview(for image: NSImage?) {
        let generation = UUID()
        interactivePreviewGeneration = generation
        interactivePreviewImage = nil
        normalizedImageContentRect = PinImageLayout.fullNormalizedContentRect

        guard let image,
              let source = image.cgImagePreservingBacking()
        else { return }

        normalizedImageContentRect = PinImageLayout.normalizedContentRect(for: source)
        let logicalSize = image.size
        PinInteractivePreviewRenderer.makePreview(from: source) { [weak self] preview in
            guard let self,
                  self.interactivePreviewGeneration == generation,
                  let preview
            else { return }

            let previewImage = NSImage(cgImage: preview, size: logicalSize)
            self.interactivePreviewImage = previewImage
            if self.usesLowResolutionPreview {
                self.needsDisplay = true
            }
        }
    }

    private func beginInteractiveZoom() {
        interactiveZoomEndTimer?.invalidate()
        interactiveZoomEndTimer = nil
        if isWindowAnimating {
            finishWindowAnimationImmediately()
        }
        guard !isZoomingInteractively else { return }
        isZoomingInteractively = true
    }

    private func scheduleInteractiveZoomEnd() {
        interactiveZoomEndTimer?.invalidate()
        let timer = Timer(timeInterval: PinZoom.interactivePreviewEndDelay, repeats: false) { [weak self] _ in
            self?.finishInteractiveZoom()
        }
        RunLoop.main.add(timer, forMode: .common)
        interactiveZoomEndTimer = timer
    }

    private func finishInteractiveZoom() {
        interactiveZoomEndTimer?.invalidate()
        interactiveZoomEndTimer = nil
        guard isZoomingInteractively else { return }

        isZoomingInteractively = false
        finishWindowUpdate()
    }

    private func finishWindowUpdate() {
        updateImageInteractionGeometry()
        needsDisplay = true
        window?.displayIfNeeded()
    }

    private func animateWindow(to targetFrame: NSRect) {
        guard let window else {
            setFrameSize(targetFrame.size)
            return
        }

        cancelWindowAnimation()
        let startFrame = window.frame
        let frameDidChange = abs(targetFrame.width - startFrame.width) > 0.5 ||
            abs(targetFrame.height - startFrame.height) > 0.5 ||
            abs(targetFrame.minX - startFrame.minX) > 0.5 ||
            abs(targetFrame.minY - startFrame.minY) > 0.5
        guard frameDidChange else {
            window.setFrame(targetFrame, display: true, animate: false)
            finishWindowUpdate()
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(targetFrame, display: true, animate: false)
            finishWindowUpdate()
            return
        }

        let generation = UUID()
        windowAnimationGeneration = generation
        windowAnimationTargetFrame = targetFrame
        let startTime = ProcessInfo.processInfo.systemUptime
        isWindowAnimating = true

        let timer = Timer(
            timeInterval: PinZoom.windowAnimationFrameInterval,
            repeats: true
        ) { [weak self, weak window] timer in
            guard let self,
                  let window,
                  self.windowAnimationGeneration == generation
            else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(max(elapsed / PinZoom.windowAnimationDuration, 0), 1)
            if progress >= 1 {
                timer.invalidate()
                self.windowAnimationTimer = nil
                self.windowAnimationTargetFrame = nil
                window.setFrame(targetFrame, display: false, animate: false)
                self.isWindowAnimating = false
                self.finishWindowUpdate()
                return
            }

            let easedProgress = progress * progress * (3 - 2 * progress)
            window.setFrame(
                Self.interpolate(
                    from: startFrame,
                    to: targetFrame,
                    progress: easedProgress
                ),
                display: false,
                animate: false
            )
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        windowAnimationTimer = timer
    }

    private func cancelWindowAnimation() {
        windowAnimationTimer?.invalidate()
        windowAnimationTimer = nil
        windowAnimationGeneration = UUID()
        windowAnimationTargetFrame = nil
        isWindowAnimating = false
    }

    private func finishWindowAnimationImmediately() {
        guard let targetFrame = windowAnimationTargetFrame,
              let window
        else {
            cancelWindowAnimation()
            return
        }

        windowAnimationTimer?.invalidate()
        windowAnimationTimer = nil
        windowAnimationGeneration = UUID()
        windowAnimationTargetFrame = nil
        window.setFrame(targetFrame, display: false, animate: false)
        isWindowAnimating = false
        finishWindowUpdate()
    }

    private static func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: Double
    ) -> CGFloat {
        start + (end - start) * CGFloat(progress)
    }

    private static func interpolate(
        from start: NSRect,
        to end: NSRect,
        progress: Double
    ) -> NSRect {
        NSRect(
            x: interpolate(from: start.minX, to: end.minX, progress: progress),
            y: interpolate(from: start.minY, to: end.minY, progress: progress),
            width: interpolate(from: start.width, to: end.width, progress: progress),
            height: interpolate(from: start.height, to: end.height, progress: progress)
        )
    }

    override func layout() {
        super.layout()
        updateToolbarFrame()
        updateOCROverlayFrame()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateImageTrackingArea()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolbarVisibility(animated: false)
    }

    private func updateOCROverlayFrame() {
        guard !usesLowResolutionPreview else { return }
        ocrOverlay.frame = imageRect()
        ocrOverlay.needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if handleOCRKeyEquivalent(event) {
            return
        }
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            pinWindow?.dismissClearingSource()
        case 53: // Esc — close only.
            pinWindow?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleOCRKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Let the activation click reach `mouseDown` so a PIN window can be
    /// dragged immediately after the pointer returns from another app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !usesLowResolutionPreview else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageHoverRect().contains(point) else { return }

        if event.clickCount >= 2 {
            pinWindow?.dismiss()
            return
        }

        performPinWindowDrag(with: event)
    }

    private func performPinWindowDrag(with event: NSEvent) {
        pinWindow?.performDrag(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let fileURL = dragTemporaryFileURLs.removeValue(
            forKey: ObjectIdentifier(session)
        ) else {
            return
        }
        PinImageDragPayload.removeTemporaryFile(at: fileURL)
    }

    override func scrollWheel(with event: NSEvent) {
        handleScrollWheel(event, focusesAtEventLocation: true)
    }

    private func handleScrollWheel(_ event: NSEvent, focusesAtEventLocation: Bool) {
        let shouldFinish = shouldFinishInteractiveZoom(for: event, includesMomentum: true)
        let delta = event.scrollingDeltaY
        guard delta != 0 else {
            if shouldFinish {
                finishInteractiveZoom()
            } else if isZoomingInteractively, event.phase.contains(.ended) {
                scheduleInteractiveZoomEnd()
            } else if isZoomingInteractively,
                      event.phase.contains(.stationary) ||
                      event.momentumPhase.contains(.began) ||
                      event.momentumPhase.contains(.changed) {
                beginInteractiveZoom()
            }
            super.scrollWheel(with: event)
            return
        }

        let normalizedDelta = event.hasPreciseScrollingDeltas ? delta : delta * 10
        let factor = pow(1 + PinZoom.wheelSensitivity, normalizedDelta)
        let proposedScale = zoomScale * factor
        if zoomScaleWillChange(to: proposedScale) {
            beginInteractiveZoom()
            if focusesAtEventLocation {
                zoomAtEventLocation(proposedScale, event: event)
            } else {
                setZoom(proposedScale)
            }
            if event.phase.isEmpty, event.momentumPhase.isEmpty {
                scheduleInteractiveZoomEnd()
            } else if event.phase.contains(.ended) {
                scheduleInteractiveZoomEnd()
            }
        } else if isZoomingInteractively, event.phase.contains(.stationary) {
            beginInteractiveZoom()
        }
        if shouldFinish {
            finishInteractiveZoom()
        }
    }

    override func magnify(with event: NSEvent) {
        handleMagnify(event, focusesAtEventLocation: true)
    }

    private func handleMagnify(_ event: NSEvent, focusesAtEventLocation: Bool) {
        let shouldFinish = shouldFinishInteractiveZoom(for: event, includesMomentum: false)
        let factor = max(0.1, 1 + event.magnification)
        let proposedScale = zoomScale * factor
        if zoomScaleWillChange(to: proposedScale) {
            beginInteractiveZoom()
            if focusesAtEventLocation {
                zoomAtEventLocation(proposedScale, event: event)
            } else {
                setZoom(proposedScale)
            }
            if event.phase.isEmpty {
                scheduleInteractiveZoomEnd()
            }
        } else if isZoomingInteractively, event.phase.contains(.stationary) {
            beginInteractiveZoom()
        }
        if shouldFinish {
            finishInteractiveZoom()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let context = NSGraphicsContext.current
        let oldInterpolation = context?.imageInterpolation
        context?.imageInterpolation = usesLowResolutionPreview ? .low : .high
        let displayImage = usesLowResolutionPreview ? (interactivePreviewImage ?? image) : image
        displayImage.draw(in: imageRect())
        if let oldInterpolation {
            context?.imageInterpolation = oldInterpolation
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolbarVisibility(for: event, animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolbarVisibility(for: event, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateToolbarVisibility(for: event, animated: true)
    }

    private func resetZoomTo100Percent() {
        guard zoomScale != 1 || isZoomingInteractively || isWindowAnimating else { return }

        interactiveZoomEndTimer?.invalidate()
        interactiveZoomEndTimer = nil
        cancelWindowAnimation()
        let currentAnchorFrame = window?.frame
        isZoomingInteractively = false
        zoomScale = 1

        if let window,
           let currentAnchorFrame {
            let targetScreen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
            let resetSize = windowSize(for: 1, on: targetScreen)
            var resetFrame = PinImageLayout.resizedFrame(
                from: currentAnchorFrame,
                to: resetSize
            )
            if let targetScreen {
                resetFrame = clampedWindowFrame(
                    resetFrame,
                    to: windowConstraintFrame(for: 1, on: targetScreen)
                )
            }
            animateWindow(to: resetFrame)
            return
        } else {
            setFrameSize(windowSize(for: 1))
        }

        finishWindowUpdate()
    }

    private func zoomScaleWillChange(to proposedScale: CGFloat) -> Bool {
        let clampedScale = min(max(proposedScale, PinZoom.minScale), PinZoom.maxScale)
        return abs(clampedScale - zoomScale) > 0.001
    }

    private func shouldFinishInteractiveZoom(
        for event: NSEvent,
        includesMomentum: Bool
    ) -> Bool {
        let gestureEnded = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        guard includesMomentum else { return gestureEnded }

        let momentumEnded = event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled)
        return momentumEnded || event.phase.contains(.cancelled)
    }

    private func toggleOCRSelection() {
        guard image != nil else { return }
        if ocrProviderKind != Defaults.ocrProviderKind {
            resetOCRSelection()
            ocrProviderKind = Defaults.ocrProviderKind
        }
        if isOCRSelectionEnabled {
            isOCRSelectionEnabled = false
            return
        }

        if hasOCRResult, ocrOverlay.lines.isEmpty {
            ToastWindow.show(message: L10n.ocrNoText, duration: 0.9)
            return
        }

        window?.makeFirstResponder(self)
        isOCRSelectionEnabled = true
        startOCRRecognitionIfNeeded()
    }

    private func startOCRRecognitionIfNeeded() {
        guard !hasOCRResult, ocrRecognitionTask == nil, let image else { return }

        ToastWindow.show(message: L10n.ocrRecognizing, duration: 0.8)
        let runID = UUID()
        ocrRunID = runID
        let imageForOCR = image.copy() as? NSImage ?? image

        ocrRecognitionTask = Task { @MainActor [weak self] in
            let result: OCRResult
            do {
                result = try await OCRService.recognizeResult(image: imageForOCR)
            } catch {
                guard !Task.isCancelled, let self, self.ocrRunID == runID else { return }
                self.ocrRecognitionTask = nil
                self.isOCRSelectionEnabled = false
                ToastWindow.show(message: error.localizedDescription, duration: 2.5)
                return
            }
            guard !Task.isCancelled, let self, self.ocrRunID == runID else { return }
            self.ocrRecognitionTask = nil
            let lines = result.lines
            if lines.isEmpty, !result.text.isEmpty, let window = self.window,
               let screen = window.screen ?? NSScreen.main {
                self.isOCRSelectionEnabled = false
                OCRTranslatePanel.presentTextRecognition(image: imageForOCR, anchorRect: window.frame,
                                                         screen: screen, initialResult: result)
                return
            }
            self.hasOCRResult = true
            self.ocrOverlay.lines = lines
            if lines.isEmpty {
                if self.isOCRSelectionEnabled {
                    self.isOCRSelectionEnabled = false
                    ToastWindow.show(message: L10n.ocrNoText, duration: 0.9)
                }
            } else {
                self.refreshOCROverlayVisibility()
            }
        }
    }

    private func resetOCRSelection() {
        ocrRunID = UUID()
        ocrRecognitionTask?.cancel()
        ocrRecognitionTask = nil
        hasOCRResult = false
        isOCRSelectionEnabled = false
        ocrOverlay.lines = []
        refreshOCROverlayVisibility()
    }

    private func refreshOCROverlayVisibility() {
        if usesLowResolutionPreview {
            ocrOverlay.isHidden = true
            return
        }

        updateOCROverlayFrame()
        let showOverlay = isOCRSelectionEnabled && !ocrOverlay.lines.isEmpty
        ocrOverlay.showsLineBoxes = showOverlay
        ocrOverlay.isHidden = !showOverlay
    }

    private func handleOCRKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isOCRSelectionEnabled,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return false
        }

        switch event.charactersIgnoringModifiers {
        case "a":
            return ocrOverlay.selectAllText()
        case "c":
            guard ocrOverlay.copySelectedTextToClipboard() else { return false }
            ToastWindow.show(message: L10n.ocrCopied, duration: 0.9)
            return true
        default:
            return false
        }
    }

    private func zoomAtEventLocation(_ proposedScale: CGFloat, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let unitPoint = imageUnitPoint(for: point) else {
            setZoom(proposedScale)
            return
        }

        setZoom(proposedScale, focusing: unitPoint)
    }

    private func setZoom(
        _ proposedScale: CGFloat,
        focusing unitPoint: NSPoint? = nil
    ) {
        let newScale = min(max(proposedScale, PinZoom.minScale), PinZoom.maxScale)
        guard abs(newScale - zoomScale) > 0.001 else { return }

        zoomScale = newScale
        resizeWindow(
            for: newScale,
            focusing: unitPoint
        )
        updateImageInteractionGeometry()
    }

    private func imageUnitPoint(for point: NSPoint) -> NSPoint? {
        let frame = imageRect()
        guard frame.width > 0,
              frame.height > 0,
              frame.contains(point)
        else { return nil }

        return NSPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    private func imageRect() -> NSRect {
        bounds
    }

    private func scaledImageSize(for scale: CGFloat) -> NSSize {
        PinImageLayout.scaledSize(baseSize: baseImageSize, scale: scale)
    }

    private func windowSize(for scale: CGFloat, on _: NSScreen? = nil) -> NSSize {
        scaledImageSize(for: scale)
    }

    private func windowConstraintFrame(for _: CGFloat, on screen: NSScreen) -> NSRect {
        screen.visibleFrame
    }

    private func clampedWindowFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var clamped = frame
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - clamped.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - clamped.height)
        clamped.origin.x = min(max(clamped.minX, visibleFrame.minX), maxX)
        clamped.origin.y = min(max(clamped.minY, visibleFrame.minY), maxY)
        return clamped
    }

    /// The image always fills the window. Trackpad zoom keeps the image point
    /// under the pointer stable; zooms without a pointer focus keep the
    /// window's top-left corner stable.
    private func resizeWindow(
        for scale: CGFloat,
        focusing unitPoint: NSPoint?
    ) {
        guard let window else {
            let targetSize = windowSize(for: scale)
            setFrameSize(targetSize)
            return
        }

        let targetSize = windowSize(for: scale, on: window.screen)
        window.setFrame(
            PinImageLayout.resizedFrame(
                from: window.frame,
                to: targetSize,
                focusing: unitPoint
            ),
            display: true,
            animate: false
        )
    }

    private func imageHoverRect() -> NSRect {
        guard image != nil else { return .zero }
        let rect = imageRect().intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .zero }
        return rect
    }

    private func updateToolbarFrame() {
        let contentRect = PinImageLayout.contentRect(
            in: bounds,
            normalizedContentRect: normalizedImageContentRect
        )
        toolbar.frame = PinImageLayout.toolbarFrame(
            in: contentRect,
            preferredSize: NSSize(
                width: PinToolbarView.preferredWidth,
                height: PinToolbarView.preferredHeight
            )
        )
    }

    private func updateImageInteractionGeometry() {
        updateToolbarFrame()
        updateOCROverlayFrame()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: true)
    }

    private func updateImageTrackingArea() {
        if let imageTrackingArea {
            removeTrackingArea(imageTrackingArea)
            self.imageTrackingArea = nil
        }

        let rect = imageHoverRect()
        guard rect.width > 0, rect.height > 0 else {
            cancelToolbarAutoHide()
            toolbarIsSuppressedAfterAutoHide = false
            setToolbarVisible(false, animated: false)
            return
        }

        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        imageTrackingArea = area
    }

    private func updateToolbarVisibility(for event: NSEvent, animated: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        updateToolbarHover(at: point, animated: animated)
    }

    private func refreshToolbarVisibility(animated: Bool) {
        guard let window else {
            cancelToolbarAutoHide()
            toolbarIsSuppressedAfterAutoHide = false
            setToolbarVisible(false, animated: false)
            return
        }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateToolbarHover(at: point, animated: animated)
    }

    private func updateToolbarHover(at point: NSPoint, animated: Bool) {
        if usesLowResolutionPreview {
            cancelToolbarAutoHide()
            toolbarIsSuppressedAfterAutoHide = false
            setToolbarVisible(true, animated: animated)
            return
        }

        let overImage = imageHoverRect().contains(point)
        let overToolbar = toolbar.frame.contains(point)

        guard overImage else {
            cancelToolbarAutoHide()
            toolbarIsSuppressedAfterAutoHide = false
            setToolbarVisible(false, animated: animated)
            return
        }

        if overToolbar {
            cancelToolbarAutoHide()
            toolbarIsSuppressedAfterAutoHide = false
            setToolbarVisible(true, animated: animated)
            return
        }

        // Hovering over the pinned image outside of the toolbar only keeps the
        // toolbar visible for a short time. Once that time expires the toolbar
        // stays hidden until the pointer reaches the toolbar region again.
        if toolbarIsSuppressedAfterAutoHide {
            setToolbarVisible(false, animated: animated)
            return
        }

        setToolbarVisible(true, animated: animated)
        scheduleToolbarAutoHideIfNeeded()
    }

    private func scheduleToolbarAutoHideIfNeeded() {
        guard toolbarAutoHideTimer == nil else { return }
        let timer = Timer(
            timeInterval: PinZoom.toolbarHoverDuration,
            repeats: false
        ) { [weak self] _ in
            self?.toolbarAutoHideTimer = nil
            self?.handleToolbarAutoHide()
        }
        RunLoop.main.add(timer, forMode: .common)
        toolbarAutoHideTimer = timer
    }

    private func handleToolbarAutoHide() {
        guard let window else {
            setToolbarVisible(false, animated: false)
            return
        }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let overImage = imageHoverRect().contains(point)
        let overToolbar = toolbar.frame.contains(point)
        guard overImage, !overToolbar else { return }

        toolbarIsSuppressedAfterAutoHide = true
        setToolbarVisible(false, animated: true)
    }

    private func cancelToolbarAutoHide() {
        toolbarAutoHideTimer?.invalidate()
        toolbarAutoHideTimer = nil
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        if visible {
            toolbar.isHidden = false
        }

        let finish = { [weak self] in
            guard let self, !self.isToolbarVisible else { return }
            self.toolbar.isHidden = true
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PinZoom.toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                toolbar.animator().alphaValue = visible ? 1 : 0
            } completionHandler: {
                finish()
            }
        } else {
            toolbar.alphaValue = visible ? 1 : 0
            finish()
        }
    }
}

// MARK: - Pin Toolbar

final class PinToolbarView: NSView {
    static let preferredWidth: CGFloat = 202
    static let preferredHeight = FloatingControlChrome.height
    static let iconButtonSide: CGFloat = 24
    static let zoomMinimumWidth: CGFloat = 40

    private static let horizontalInset: CGFloat = 6
    private static let itemGap: CGFloat = 4

    var onEdit: (() -> Void)?
    var onOCR: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onResetZoom: (() -> Void)?
    var onClose: (() -> Void)?
    var onPointerEvent: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    var isOCRActive = false {
        didSet { ocrButton.isActive = isOCRActive }
    }

    var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomLabel.setPercentage(Int(round(zoomScale * 100)))
        }
    }

    private let editButton = PinToolbarIconButton(
        symbolName: "pencil",
        accessibilityLabel: L10n.pinToolbarEdit,
        symbolPointSize: 14
    )
    private let ocrButton = PinToolbarIconButton(
        symbolName: "text.viewfinder",
        accessibilityLabel: L10n.tipOCR,
        symbolPointSize: 14
    )
    private let copyButton = PinToolbarIconButton(
        symbolName: "doc.on.doc",
        accessibilityLabel: L10n.pinToolbarCopy,
        symbolPointSize: 14
    )
    private let dragButton = PinToolbarDragButton(
        symbolName: "cursorarrow.motionlines",
        accessibilityLabel: L10n.pinToolbarDrag,
        symbolPointSize: 14
    )
    private let zoomLabel = PinToolbarZoomButton()
    private let closeButton = PinToolbarIconButton(
        symbolName: "xmark",
        accessibilityLabel: L10n.pinToolbarClose,
        style: .destructive,
        symbolPointSize: 14
    )
    private var trackingArea: NSTrackingArea?

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
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = FloatingControlChrome.cornerRadius
        layer?.borderWidth = FloatingControlChrome.borderWidth
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 5
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        applyAppearance()

        editButton.toolTip = L10n.pinToolbarEdit
        editButton.target = self
        editButton.action = #selector(editTapped)
        ocrButton.toolTip = L10n.tipOCR
        ocrButton.target = self
        ocrButton.action = #selector(ocrTapped)
        copyButton.toolTip = L10n.pinToolbarCopy
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        dragButton.toolTip = L10n.pinToolbarDrag
        dragButton.onDrag = { [weak self] event in
            self?.onPointerEvent?()
            self?.onDrag?(event)
        }

        zoomLabel.onClick = { [weak self] in
            self?.onResetZoom?()
        }
        closeButton.toolTip = L10n.pinToolbarClose
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        zoomLabel.alignment = .center

        addSubview(closeButton)
        addSubview(dragButton)
        addSubview(editButton)
        addSubview(ocrButton)
        addSubview(copyButton)
        addSubview(zoomLabel)
    }

    override func layout() {
        super.layout()

        let optionalButtons = [dragButton, editButton, ocrButton, copyButton]
        var hiddenButtonCount = 0
        while hiddenButtonCount < optionalButtons.count,
              Self.requiredWidth(
                  optionalButtonCount: optionalButtons.count - hiddenButtonCount
              ) > bounds.width {
            hiddenButtonCount += 1
        }

        for (index, button) in optionalButtons.enumerated() {
            button.isHidden = index < hiddenButtonCount
        }

        let buttonSide = min(Self.iconButtonSide, max(0, bounds.height - 4))
        let buttonY = (bounds.height - buttonSide) / 2
        var x = Self.horizontalInset
        closeButton.frame = NSRect(
            x: x,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        x += buttonSide + Self.itemGap

        for button in optionalButtons.dropFirst(hiddenButtonCount) {
            button.frame = NSRect(x: x, y: buttonY, width: buttonSide, height: buttonSide)
            x += buttonSide + Self.itemGap
        }
        zoomLabel.isHidden = false
        zoomLabel.frame = NSRect(
            x: x,
            y: max(0, buttonY + 4),
            width: max(0, bounds.width - Self.horizontalInset - x),
            height: max(0, buttonSide - 8)
        )
    }

    private static func requiredWidth(optionalButtonCount: Int) -> CGFloat {
        let iconCount = 1 + max(0, optionalButtonCount)
        let gapCount = iconCount
        return horizontalInset * 2
            + CGFloat(iconCount) * iconButtonSide
            + CGFloat(gapCount) * itemGap
            + zoomMinimumWidth
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = AdaptiveChrome.resolvedCGColor(
            AdaptiveChrome.floatingBackground,
            for: effectiveAppearance
        )
        layer?.borderColor = AdaptiveChrome.resolvedCGColor(
            AdaptiveChrome.border,
            for: effectiveAppearance
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func scrollWheel(with event: NSEvent) {
        onPointerEvent?()
        onScrollWheel?(event)
    }

    override func magnify(with event: NSEvent) {
        onPointerEvent?()
        onMagnify?(event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerEvent?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent?()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerEvent?()
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    @objc private func editTapped() {
        onEdit?()
    }

    @objc private func ocrTapped() {
        onOCR?()
    }

    @objc private func copyTapped() {
        onCopy?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

private final class PinToolbarZoomButton: NSButton {
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        setPercentage(100)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setPercentage(_ percentage: Int) {
        let value = "\(percentage)%"
        attributedTitle = NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        setAccessibilityLabel(value)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    @objc private func clicked() {
        onClick?()
    }
}

private class PinToolbarIconButton: NSButton {
    enum Style {
        case standard
        case destructive
    }

    var isActive = false {
        didSet { updateAppearance() }
    }
    private let style: Style

    init(
        symbolName: String,
        accessibilityLabel: String,
        style: Style = .standard,
        symbolPointSize: CGFloat = 12
    ) {
        self.style = style
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityLabel(accessibilityLabel)

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
            self.image = image.withSymbolConfiguration(config)
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    private func updateAppearance() {
        switch style {
        case .standard:
            contentTintColor = isActive ? .white : .labelColor
            layer?.backgroundColor = AdaptiveChrome.resolvedCGColor(
                isActive ? accentGreen.withAlphaComponent(0.86) : .clear,
                for: effectiveAppearance
            )
        case .destructive:
            contentTintColor = .systemRed
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

private final class PinToolbarDragButton: PinToolbarIconButton {
    var onDrag: ((NSEvent) -> Void)?
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3 else {
            return
        }
        didStartDrag = true
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        didStartDrag = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

private final class TextPinToolbarView: NSView {
    static let preferredWidth: CGFloat = 106
    static let preferredHeight: CGFloat = 34

    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onEditText: (() -> Void)?
    var onPointerEvent: ((NSEvent) -> Void)?

    private let closeButton = PinToolbarIconButton(symbolName: "xmark", accessibilityLabel: L10n.imageMergeClose)
    private let textEditButton = PinToolbarIconButton(symbolName: "textformat", accessibilityLabel: L10n.pinToolbarEditText)
    private let editButton = PinToolbarIconButton(symbolName: "pencil", accessibilityLabel: L10n.pinToolbarEdit)
    private var trackingArea: NSTrackingArea?

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

        closeButton.toolTip = L10n.imageMergeClose
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        textEditButton.toolTip = L10n.pinToolbarEditText
        textEditButton.target = self
        textEditButton.action = #selector(editTextTapped)
        editButton.toolTip = L10n.pinToolbarEdit
        editButton.target = self
        editButton.action = #selector(editTapped)

        addSubview(closeButton)
        addSubview(textEditButton)
        addSubview(editButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()

        let buttonSide = min(28, max(22, bounds.height - 6))
        let buttonY = (bounds.height - buttonSide) / 2
        let horizontalInset: CGFloat = 4
        let gap = max(4, (bounds.width - horizontalInset * 2 - buttonSide * 3) / 2)

        closeButton.frame = NSRect(
            x: horizontalInset,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        textEditButton.frame = NSRect(
            x: closeButton.frame.maxX + gap,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        editButton.frame = NSRect(
            x: textEditButton.frame.maxX + gap,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()

        AdaptiveChrome.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent?(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerEvent?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent?(event)
    }

    override func mouseDown(with event: NSEvent) {
        onPointerEvent?(event)
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func editTextTapped() {
        onEditText?()
    }

    @objc private func editTapped() {
        onEdit?()
    }
}
