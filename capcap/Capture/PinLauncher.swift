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

    /// Creates a floating pinned window for `image`. When `origin` is nil the
    /// window is centered on the screen under the cursor. Oversized images are
    /// scaled down to fit the screen.
    static func pin(image: NSImage, at origin: NSPoint? = nil, source: PinSource? = nil) {
        let screen = activeScreen()
        let size = fittedSize(for: image.size, on: screen)
        let frameOrigin = origin ?? centeredOrigin(for: size, on: screen)

        makeWindow(image: image, size: size, origin: frameOrigin, source: source)
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
            makeWindow(image: pin.image, size: pin.size, origin: origin, source: source)
        }
    }

    private static func makeWindow(image: NSImage, size: NSSize, origin: NSPoint, source: PinSource?) {
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

    private static func loadImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage.imagePreservingPixelDimensions(from: data),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
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

// MARK: - Pin Content View (zoomable image with floating controls)

private enum PinZoom {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 5.0
    static let buttonStep: CGFloat = 0.1
    static let wheelSensitivity: CGFloat = 0.002
    static let toolbarInset: CGFloat = 8
    static let navigatorScaleThreshold: CGFloat = 1.2
    static let navigatorGap: CGFloat = 8
    static let navigatorIdleHideDelay: TimeInterval = 0.8
    static let navigatorActivationDelay: TimeInterval = 0.4
    static let navigatorEntryTimeout: TimeInterval = 3.0
    static let toolbarAnimationDuration: TimeInterval = 0.16
}

final class PinContentView: NSView {
    var image: NSImage? {
        didSet {
            navigator.image = image
            zoomScale = 1.0
            panOffset = .zero
            resetOCRSelection()
            needsDisplay = true
            needsLayout = true
            updateImageInteractionGeometry()
        }
    }
    weak var pinWindow: PinWindow?

    private let baseImageSize: NSSize
    private let toolbar = PinToolbarView()
    private let navigator = PinNavigatorView()
    private let ocrOverlay: OCRLineSelectionOverlayView
    private var zoomScale: CGFloat = 1.0 {
        didSet {
            toolbar.zoomScale = zoomScale
            updateNavigatorViewport()
            if !canShowNavigator {
                hideNavigator(animated: true)
            }
            needsDisplay = true
        }
    }
    private var panOffset: NSPoint = .zero {
        didSet {
            updateNavigatorViewport()
            needsDisplay = true
        }
    }
    private var panStartPoint: NSPoint?
    private var panStartOffset: NSPoint = .zero
    private var imageTrackingArea: NSTrackingArea?
    private var isToolbarVisible = false
    private var isNavigatorVisible = false
    private var isNavigatorFrameValid = false
    private var isNavigatorSuppressedUntilMouseExit = false
    private var wasMouseInNavigatorActivationRegion = false
    private var isMouseInNavigatorRegion = false
    private var lastNavigatorPointerPoint: NSPoint?
    private var navigatorNavigationBlockedUntil: Date?
    private var navigatorIdleTimer: Timer?
    private var navigatorEntryTimer: Timer?
    private var isOCRSelectionEnabled = false {
        didSet {
            toolbar.isOCRActive = isOCRSelectionEnabled
            refreshOCROverlayVisibility()
        }
    }
    private var hasOCRResult = false
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
        navigatorIdleTimer?.invalidate()
        navigatorEntryTimer?.invalidate()
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
        navigator.alphaValue = 0
        navigator.isHidden = true

        toolbar.onEdit = { [weak self] in
            self?.editPinnedImage()
        }
        toolbar.onOCR = { [weak self] in
            self?.toggleOCRSelection()
        }
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
        navigator.onFocusChanged = { [weak self] unitPoint in
            self?.focusImage(at: unitPoint)
        }
        navigator.onPointerActivity = { [weak self] point in
            self?.registerNavigatorPointerActivity(at: point) == true
        }
        navigator.onPointerExited = { [weak self] in
            self?.handleNavigatorPointerExit()
        }
        addSubview(navigator)
        addSubview(toolbar)
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

    override func layout() {
        super.layout()
        updateToolbarFrame()
        updateOCROverlayFrame()
        updateNavigatorFrame()
        updateNavigatorViewport()
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

    private func updateToolbarFrame() {
        let toolbarWidth = min(PinToolbarView.preferredWidth, max(PinToolbarView.minimumWidth, bounds.width - 12))
        let toolbarHeight = PinToolbarView.preferredHeight
        let imageFrame = imageRect()
        let margin: CGFloat = 6
        let proposedX = imageFrame.minX + PinZoom.toolbarInset
        let proposedY = imageFrame.maxY - toolbarHeight - PinZoom.toolbarInset
        let maxX = max(margin, bounds.width - toolbarWidth - margin)
        let maxY = max(margin, bounds.height - toolbarHeight - margin)

        toolbar.frame = NSRect(
            x: min(max(proposedX, margin), maxX),
            y: min(max(proposedY, margin), maxY),
            width: toolbarWidth,
            height: toolbarHeight
        )
    }

    private func updateOCROverlayFrame() {
        ocrOverlay.frame = imageRect()
        ocrOverlay.needsDisplay = true
    }

    private func updateNavigatorFrame() {
        let size = navigatorSize()
        guard size.width > 0, size.height > 0 else {
            isNavigatorFrameValid = false
            hideNavigator(animated: true)
            return
        }

        isNavigatorFrameValid = true
        let margin: CGFloat = 6
        let proposedX = PinZoom.toolbarInset
        let proposedY = bounds.height - PinToolbarView.preferredHeight -
            PinZoom.toolbarInset - PinZoom.navigatorGap - size.height
        let maxX = max(margin, bounds.width - size.width - margin)
        let maxY = max(margin, bounds.height - size.height - margin)

        navigator.frame = NSRect(
            x: min(max(proposedX, margin), maxX),
            y: min(max(proposedY, margin), maxY),
            width: size.width,
            height: size.height
        )
    }

    private func navigatorSize() -> NSSize {
        guard baseImageSize.width > 0, baseImageSize.height > 0 else { return .zero }

        let margin: CGFloat = 6
        let aspect = baseImageSize.width / baseImageSize.height
        let widthLimit = max(48, min(PinNavigatorView.maxWidth, bounds.width - margin * 2))
        let availableHeightBelowToolbar = toolbar.frame.minY - PinZoom.navigatorGap - margin
        let heightLimit = max(36, min(PinNavigatorView.maxHeight, availableHeightBelowToolbar))

        var width = min(widthLimit, max(PinNavigatorView.minWidth, bounds.width * 0.18))
        var height = width / aspect
        if height > heightLimit {
            height = heightLimit
            width = height * aspect
        }
        if width > widthLimit {
            width = widthLimit
            height = width / aspect
        }

        guard width >= 48, height >= 36 else { return .zero }
        return NSSize(width: floor(width), height: floor(height))
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard !toolbarInteractiveRect().contains(point) else { return }
        guard !navigatorInteractiveRect().contains(point) else { return }
        guard imageHoverRect().contains(point) else { return }

        if event.clickCount >= 2 {
            pinWindow?.dismiss()
            return
        }

        if zoomScale > 1 {
            panStartPoint = point
            panStartOffset = panOffset
            return
        }

        pinWindow?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoomScale > 1, let start = panStartPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        let proposed = NSPoint(
            x: panStartOffset.x + point.x - start.x,
            y: panStartOffset.y + point.y - start.y
        )
        panOffset = clampedPanOffset(proposed, scale: zoomScale)
        updateImageInteractionGeometry()
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
        zoomAtEventLocation(zoomScale * factor, event: event)
    }

    override func magnify(with event: NSEvent) {
        let factor = max(0.1, 1 + event.magnification)
        zoomAtEventLocation(zoomScale * factor, event: event)
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

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolbarVisibility(for: event, animated: true)
        updateNavigatorActivation(for: event, animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolbarVisibility(for: event, animated: true)
        updateNavigatorActivation(for: event, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateToolbarVisibility(for: event, animated: true)
        updateNavigatorActivation(for: event, animated: true)
    }

    private func adjustZoom(by delta: CGFloat) {
        setZoom(zoomScale + delta)
    }

    private func toggleOCRSelection() {
        guard image != nil else { return }
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
            let lines = await OCRService.recognizeLines(image: imageForOCR)
            guard let self, self.ocrRunID == runID else { return }
            self.ocrRecognitionTask = nil
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

        setZoom(proposedScale, focusing: unitPoint, at: point)
    }

    private func setZoom(
        _ proposedScale: CGFloat,
        focusing unitPoint: NSPoint? = nil,
        at focusPoint: NSPoint? = nil
    ) {
        let newScale = min(max(proposedScale, PinZoom.minScale), PinZoom.maxScale)
        let didChangeScale = abs(newScale - zoomScale) > 0.001
        guard didChangeScale || unitPoint != nil else { return }

        let currentSize = bounds.size
        let targetSize = windowSize(for: newScale)
        let shouldRevealNavigator = didChangeScale &&
            zoomScale < PinZoom.navigatorScaleThreshold &&
            newScale >= PinZoom.navigatorScaleThreshold
        if didChangeScale {
            zoomScale = newScale
        }
        if let unitPoint, newScale > 1 {
            resizeWindowKeepingTopLeft(for: newScale)
            panOffset = focusedPanOffset(
                on: unitPoint,
                scale: newScale,
                at: adjustedFocusPoint(
                    focusPoint,
                    from: currentSize,
                    to: targetSize
                )
            )
        } else {
            panOffset = newScale > 1 ? clampedPanOffset(panOffset, scale: newScale) : .zero
            if didChangeScale {
                resizeWindowKeepingTopLeft(for: newScale)
            }
        }
        updateImageInteractionGeometry()
        if shouldRevealNavigator {
            isNavigatorSuppressedUntilMouseExit = false
            showNavigator(animated: true)
            updateNavigatorActivationAtCurrentMouse(animated: true)
        }
    }

    private func focusImage(at unitPoint: NSPoint) {
        guard isNavigatorVisible,
              !isNavigatorSuppressedUntilMouseExit,
              !isNavigatorNavigationBlocked,
              zoomScale >= PinZoom.navigatorScaleThreshold
        else { return }

        let imageSize = scaledImageSize(for: zoomScale)
        panOffset = focusedPanOffset(on: unitPoint, scale: zoomScale, imageSize: imageSize)
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

    private func focusedPanOffset(
        on unitPoint: NSPoint,
        scale: CGFloat,
        imageSize: NSSize? = nil,
        at focusPoint: NSPoint? = nil
    ) -> NSPoint {
        let size = imageSize ?? scaledImageSize(for: scale)
        let targetPoint = focusPoint ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let imagePoint = NSPoint(
            x: min(max(unitPoint.x, 0), 1) * size.width,
            y: min(max(unitPoint.y, 0), 1) * size.height
        )
        let proposed = NSPoint(
            x: targetPoint.x - imagePoint.x,
            y: targetPoint.y - imagePoint.y - bounds.height + size.height
        )
        return clampedPanOffset(proposed, scale: scale)
    }

    private func adjustedFocusPoint(
        _ point: NSPoint?,
        from currentSize: NSSize,
        to targetSize: NSSize
    ) -> NSPoint? {
        guard let point else { return nil }
        return NSPoint(
            x: point.x,
            y: point.y + targetSize.height - currentSize.height
        )
    }

    private func imageRect() -> NSRect {
        let size = scaledImageSize(for: zoomScale)
        return NSRect(
            x: panOffset.x,
            y: bounds.height - size.height + panOffset.y,
            width: size.width,
            height: size.height
        )
    }

    private func scaledImageSize(for scale: CGFloat) -> NSSize {
        NSSize(
            width: max(1, floor(baseImageSize.width * scale)),
            height: max(1, floor(baseImageSize.height * scale))
        )
    }

    private func windowSize(for scale: CGFloat) -> NSSize {
        let imageSize = scaledImageSize(for: scale)
        let naturalSize = scale > 1 ? baseImageSize : imageSize
        return NSSize(
            width: max(naturalSize.width, PinToolbarView.minimumWidth + 12),
            height: max(naturalSize.height, PinToolbarView.preferredHeight + PinZoom.toolbarInset * 2)
        )
    }

    private func clampedPanOffset(_ offset: NSPoint, scale: CGFloat) -> NSPoint {
        guard scale > 1 else { return .zero }

        let imageSize = scaledImageSize(for: scale)
        let minX = min(0, bounds.width - imageSize.width)
        let maxY = max(0, imageSize.height - bounds.height)
        return NSPoint(
            x: min(max(offset.x, minX), 0),
            y: min(max(offset.y, 0), maxY)
        )
    }

    private func resizeWindowKeepingTopLeft(for scale: CGFloat) {
        let targetSize = windowSize(for: scale)
        guard let window else {
            setFrameSize(targetSize)
            return
        }

        let currentFrame = window.frame
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        guard abs(targetFrame.width - currentFrame.width) > 0.5 ||
              abs(targetFrame.height - currentFrame.height) > 0.5
        else { return }

        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func imageHoverRect() -> NSRect {
        guard image != nil else { return .zero }
        let rect = imageRect().intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .zero }
        return rect
    }

    private func updateImageInteractionGeometry() {
        updateToolbarFrame()
        updateOCROverlayFrame()
        updateNavigatorFrame()
        updateNavigatorViewport()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: true)
    }

    private func updateNavigatorViewport() {
        navigator.viewportRect = normalizedVisibleImageRect()
    }

    private var canShowNavigator: Bool {
        zoomScale >= PinZoom.navigatorScaleThreshold &&
            image != nil &&
            isNavigatorFrameValid &&
            navigator.frame.width > 0 &&
            navigator.frame.height > 0
    }

    private func normalizedVisibleImageRect() -> NSRect {
        let imageFrame = imageRect()
        let visible = imageFrame.intersection(bounds)
        guard !visible.isNull,
              imageFrame.width > 0,
              imageFrame.height > 0
        else { return .zero }

        return NSRect(
            x: min(max((visible.minX - imageFrame.minX) / imageFrame.width, 0), 1),
            y: min(max((visible.minY - imageFrame.minY) / imageFrame.height, 0), 1),
            width: min(max(visible.width / imageFrame.width, 0), 1),
            height: min(max(visible.height / imageFrame.height, 0), 1)
        )
    }

    private func navigatorInteractiveRect() -> NSRect {
        guard isNavigatorVisible,
              zoomScale >= PinZoom.navigatorScaleThreshold,
              navigator.frame.width > 0,
              navigator.frame.height > 0
        else { return .zero }
        return navigator.frame
    }

    private func toolbarInteractiveRect() -> NSRect {
        guard !toolbar.isHidden,
              toolbar.frame.width > 0,
              toolbar.frame.height > 0
        else { return .zero }
        return toolbar.frame
    }

    private func navigatorActivationRect() -> NSRect {
        guard canShowNavigator else { return .zero }
        return navigator.frame
    }

    private func updateImageTrackingArea() {
        if let imageTrackingArea {
            removeTrackingArea(imageTrackingArea)
            self.imageTrackingArea = nil
        }

        let rect = imageHoverRect()
        guard rect.width > 0, rect.height > 0 else {
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
        setToolbarVisible(imageHoverRect().contains(point), animated: animated)
    }

    private func updateNavigatorActivation(for event: NSEvent, animated: Bool) {
        updateNavigatorActivation(at: convert(event.locationInWindow, from: nil), animated: animated)
    }

    private func updateNavigatorActivationAtCurrentMouse(animated: Bool) {
        guard let window else { return }
        updateNavigatorActivation(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), animated: animated)
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private var isCurrentMouseInsideNavigatorActivationRegion: Bool {
        guard canShowNavigator, let point = currentMousePointInView() else { return false }
        return navigatorActivationRect().contains(point)
    }

    private func updateNavigatorActivation(at point: NSPoint, animated: Bool) {
        guard canShowNavigator else {
            isNavigatorSuppressedUntilMouseExit = false
            lastNavigatorPointerPoint = nil
            wasMouseInNavigatorActivationRegion = false
            hideNavigator(animated: animated)
            return
        }

        let inside = navigatorActivationRect().contains(point)
        if !inside {
            isNavigatorSuppressedUntilMouseExit = false
            navigatorNavigationBlockedUntil = nil
            lastNavigatorPointerPoint = nil
        }
        defer { wasMouseInNavigatorActivationRegion = inside }

        if isNavigatorSuppressedUntilMouseExit {
            if !inside, wasMouseInNavigatorActivationRegion {
                handleNavigatorPointerExit()
            }
            return
        }

        if inside {
            if !wasMouseInNavigatorActivationRegion {
                showNavigator(animated: animated)
                beginNavigatorHover(at: point)
                return
            }
            guard isNavigatorVisible else { return }

            guard registerNavigatorPointerActivity(at: point) else { return }
            if let unitPoint = navigator.unitPoint(forPointInSuperview: point) {
                focusImage(at: unitPoint)
            }
        } else if wasMouseInNavigatorActivationRegion {
            handleNavigatorPointerExit()
        }
    }

    private func refreshToolbarVisibility(animated: Bool) {
        guard let window else {
            setToolbarVisible(false, animated: false)
            return
        }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setToolbarVisible(imageHoverRect().contains(point), animated: animated)
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        setFloatingControl(
            toolbar,
            visible: visible,
            animated: animated,
            shouldRemainVisible: { [weak self] in self?.isToolbarVisible == true }
        )
    }

    private func showNavigator(animated _: Bool) {
        guard canShowNavigator else { return }
        navigatorEntryTimer?.invalidate()
        scheduleNavigatorEntryTimeout()
        guard !isNavigatorVisible else { return }

        isNavigatorVisible = true
        setFloatingControl(
            navigator,
            visible: true,
            animated: true,
            shouldRemainVisible: { [weak self] in self?.isNavigatorVisible == true }
        )
    }

    private func hideNavigator(animated _: Bool) {
        hideNavigator(animated: true, suppressUntilMouseExit: false)
    }

    private func hideNavigator(animated _: Bool, suppressUntilMouseExit: Bool) {
        navigatorIdleTimer?.invalidate()
        navigatorEntryTimer?.invalidate()
        isMouseInNavigatorRegion = false
        isNavigatorSuppressedUntilMouseExit = suppressUntilMouseExit
        navigatorNavigationBlockedUntil = nil
        lastNavigatorPointerPoint = nil
        wasMouseInNavigatorActivationRegion = suppressUntilMouseExit
        guard isNavigatorVisible || !navigator.isHidden else { return }

        isNavigatorVisible = false
        setFloatingControl(
            navigator,
            visible: false,
            animated: true,
            shouldRemainVisible: { [weak self] in self?.isNavigatorVisible == true }
        )
    }

    private func beginNavigatorHover(at point: NSPoint) {
        guard isNavigatorVisible else { return }
        isMouseInNavigatorRegion = true
        wasMouseInNavigatorActivationRegion = true
        navigatorNavigationBlockedUntil = Date().addingTimeInterval(PinZoom.navigatorActivationDelay)
        lastNavigatorPointerPoint = point
        navigatorEntryTimer?.invalidate()
        scheduleNavigatorIdleHide()
    }

    @discardableResult
    private func registerNavigatorPointerActivity(at point: NSPoint? = nil) -> Bool {
        guard isNavigatorVisible else { return false }
        isMouseInNavigatorRegion = true
        wasMouseInNavigatorActivationRegion = true
        navigatorEntryTimer?.invalidate()

        if let point {
            let didMove = navigatorPointerDidMove(to: point)
            guard didMove || navigatorIdleTimer == nil else { return false }
        }
        scheduleNavigatorIdleHide()
        return !isNavigatorNavigationBlocked
    }

    private func handleNavigatorPointerExit() {
        if isNavigatorSuppressedUntilMouseExit,
           isCurrentMouseInsideNavigatorActivationRegion {
            isMouseInNavigatorRegion = false
            navigatorIdleTimer?.invalidate()
            return
        }

        isMouseInNavigatorRegion = false
        isNavigatorSuppressedUntilMouseExit = false
        navigatorNavigationBlockedUntil = nil
        wasMouseInNavigatorActivationRegion = false
        lastNavigatorPointerPoint = nil
        navigatorIdleTimer?.invalidate()
        guard isNavigatorVisible else { return }
        scheduleNavigatorEntryTimeout()
    }

    private func navigatorPointerDidMove(to point: NSPoint) -> Bool {
        defer { lastNavigatorPointerPoint = point }
        guard let previous = lastNavigatorPointerPoint else { return true }

        return abs(previous.x - point.x) > 0.5 || abs(previous.y - point.y) > 0.5
    }

    private var isNavigatorNavigationBlocked: Bool {
        guard let blockedUntil = navigatorNavigationBlockedUntil else { return false }
        guard Date() < blockedUntil else {
            navigatorNavigationBlockedUntil = nil
            return false
        }
        return true
    }

    private func scheduleNavigatorIdleHide() {
        navigatorIdleTimer?.invalidate()
        let timer = Timer(timeInterval: PinZoom.navigatorIdleHideDelay, repeats: false) { [weak self] _ in
            guard let self, self.isMouseInNavigatorRegion else { return }
            self.hideNavigator(animated: true, suppressUntilMouseExit: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        navigatorIdleTimer = timer
    }

    private func scheduleNavigatorEntryTimeout() {
        navigatorEntryTimer?.invalidate()
        let timer = Timer(timeInterval: PinZoom.navigatorEntryTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isNavigatorVisible, !self.isMouseInNavigatorRegion else { return }
            self.hideNavigator(animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        navigatorEntryTimer = timer
    }

    private func setFloatingControl(
        _ view: NSView,
        visible: Bool,
        animated: Bool,
        shouldRemainVisible: @escaping () -> Bool
    ) {
        if visible {
            view.isHidden = false
        }

        let finish = { [weak view] in
            guard let view else { return }
            if !shouldRemainVisible() {
                view.isHidden = true
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PinZoom.toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = visible ? 1 : 0
            } completionHandler: {
                finish()
            }
        } else {
            view.alphaValue = visible ? 1 : 0
            finish()
        }
    }
}

// MARK: - Pin Navigator

private final class PinNavigatorView: NSView {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 160
    static let minWidth: CGFloat = 96

    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var viewportRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var onFocusChanged: ((NSPoint) -> Void)?
    var onPointerActivity: ((NSPoint) -> Bool)?
    var onPointerExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityLabel("Pinned image navigator")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        guard bounds.width > 0, bounds.height > 0 else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 5, yRadius: 5)

        NSColor(white: 0.02, alpha: 0.42).setFill()
        outerPath.fill()

        if let image {
            let imageRect = thumbnailImageRect()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: 3, yRadius: 3).addClip()

            let context = NSGraphicsContext.current
            let oldInterpolation = context?.imageInterpolation
            context?.imageInterpolation = .high
            image.draw(in: imageRect)
            if let oldInterpolation {
                context?.imageInterpolation = oldInterpolation
            }
            NSGraphicsContext.restoreGraphicsState()

            drawViewport(in: imageRect)
        }

        NSColor.systemGreen.withAlphaComponent(0.95).setStroke()
        outerPath.lineWidth = 3
        outerPath.stroke()
    }

    private func drawViewport(in imageRect: NSRect) {
        guard viewportRect.width > 0, viewportRect.height > 0 else { return }

        let rect = NSRect(
            x: imageRect.minX + viewportRect.minX * imageRect.width,
            y: imageRect.minY + viewportRect.minY * imageRect.height,
            width: max(8, viewportRect.width * imageRect.width),
            height: max(8, viewportRect.height * imageRect.height)
        ).intersection(imageRect)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        NSColor.systemGreen.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.88).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    func unitPoint(forPointInSuperview point: NSPoint) -> NSPoint? {
        guard let superview else { return nil }
        return unitPoint(forLocalPoint: convert(point, from: superview))
    }

    private func updateFocus(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        var shouldFocus = true
        if let superview {
            shouldFocus = onPointerActivity?(convert(localPoint, to: superview)) ?? true
        }
        guard shouldFocus else { return }
        guard let unitPoint = unitPoint(forLocalPoint: localPoint) else { return }
        onFocusChanged?(unitPoint)
    }

    private func unitPoint(forLocalPoint point: NSPoint) -> NSPoint? {
        guard !bounds.isEmpty else { return nil }
        guard bounds.contains(point) else { return nil }

        let imageRect = thumbnailImageRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        let clamped = NSPoint(
            x: min(max(point.x, imageRect.minX), imageRect.maxX),
            y: min(max(point.y, imageRect.minY), imageRect.maxY)
        )
        return NSPoint(
            x: (clamped.x - imageRect.minX) / imageRect.width,
            y: (clamped.y - imageRect.minY) / imageRect.height
        )
    }

    private func thumbnailImageRect() -> NSRect {
        let content = bounds.insetBy(dx: 5, dy: 5)
        guard content.width > 0, content.height > 0 else { return .zero }
        guard let image, image.size.width > 0, image.size.height > 0 else { return content }

        let imageAspect = image.size.width / image.size.height
        let contentAspect = content.width / content.height
        if imageAspect >= contentAspect {
            let height = content.width / imageAspect
            return NSRect(
                x: content.minX,
                y: content.midY - height / 2,
                width: content.width,
                height: height
            )
        } else {
            let width = content.height * imageAspect
            return NSRect(
                x: content.midX - width / 2,
                y: content.minY,
                width: width,
                height: content.height
            )
        }
    }
}

// MARK: - Pin Toolbar

private final class PinToolbarView: NSView {
    static let preferredWidth: CGFloat = 258
    static let minimumWidth: CGFloat = 220
    static let preferredHeight: CGFloat = 34

    var onEdit: (() -> Void)?
    var onOCR: (() -> Void)?
    var onMoveMouseDown: ((NSEvent) -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onClose: (() -> Void)?
    var isOCRActive = false {
        didSet { ocrButton.isActive = isOCRActive }
    }

    var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomLabel.stringValue = "\(Int(round(zoomScale * 100)))%"
        }
    }

    private let editButton = PinToolbarIconButton(symbolName: "pencil", accessibilityLabel: L10n.pinToolbarEdit)
    private let ocrButton = PinToolbarIconButton(symbolName: "text.viewfinder", accessibilityLabel: L10n.tipOCR)
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

        editButton.toolTip = L10n.pinToolbarEdit
        editButton.target = self
        editButton.action = #selector(editTapped)
        ocrButton.toolTip = L10n.tipOCR
        ocrButton.target = self
        ocrButton.action = #selector(ocrTapped)
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
        addSubview(editButton)
        addSubview(ocrButton)
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
        let buttonGap: CGFloat = 4

        closeButton.frame = NSRect(x: horizontalInset, y: buttonY, width: buttonSide, height: buttonSide)
        moveButton.frame = NSRect(
            x: bounds.width - horizontalInset - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        editButton.frame = NSRect(
            x: moveButton.frame.minX - buttonGap - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        ocrButton.frame = NSRect(
            x: editButton.frame.minX - buttonGap - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )

        let centerX = closeButton.frame.maxX + gap
        let centerWidth = max(76, ocrButton.frame.minX - gap - centerX)
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    @objc private func editTapped() {
        onEdit?()
    }

    @objc private func ocrTapped() {
        onOCR?()
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
    var isActive = false {
        didSet { updateAppearance() }
    }

    init(symbolName: String, accessibilityLabel: String) {
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
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
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
        contentTintColor = isActive ? .white : NSColor.white.withAlphaComponent(0.88)
        layer?.backgroundColor = (isActive
            ? accentGreen.withAlphaComponent(0.86)
            : NSColor.clear
        ).cgColor
    }
}

private final class PinToolbarMoveButton: PinToolbarIconButton {
    var onMouseDown: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
}
