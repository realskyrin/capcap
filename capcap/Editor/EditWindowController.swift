import AppKit

class EditWindowController {
    private var canvasView: EditCanvasView?
    private var beautifyContainerView: BeautifyContainerView?
    private var canvasScrollView: EditorScrollView?
    private weak var hostSelectionView: SelectionView?
    private var toolbarView: ToolbarView?
    private var subToolbarView: NSView?
    private var captureRect: CGRect
    private var screen: NSScreen
    private var selectionRect: NSRect
    private var selectionViewRect: NSRect
    private let onComplete: (NSImage?) -> Void
    private var activeTool: EditTool = .none
    private var beautifySubToolbarView: BeautifySubToolbar?
    private var isBeautifyActive: Bool = false
    private var currentBeautifyPreset: BeautifyPreset?

    // Pre-captured screen snapshot (preserves transient menus/popups)
    private let preSnapshot: CGImage?

    // Scroll capture state
    private var scrollCapturer: ScrollCapturer?
    private var isScrollCapturing = false
    private var scrollEventMonitor: Any?
    private var scrollCaptureControlWindow: ScrollCaptureControlWindow?
    private var scrollPreviewWindow: ScrollPreviewWindow?

    // Drawing properties
    private var currentColor: NSColor = .red
    private var currentLineWidth: CGFloat = 3.0
    private var currentMosaicBlockSize: CGFloat = 12.0

    init(
        captureRect: CGRect,
        screen: NSScreen,
        selectionRect: NSRect,
        selectionViewRect: NSRect,
        hostSelectionView: SelectionView,
        preSnapshot: CGImage? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.captureRect = captureRect
        self.screen = screen
        self.selectionRect = selectionRect
        self.selectionViewRect = selectionViewRect
        self.hostSelectionView = hostSelectionView
        self.preSnapshot = preSnapshot
        self.onComplete = onComplete
    }

    func show() {
        guard let hostSelectionView else {
            onComplete(nil)
            return
        }

        let scrollView = EditorScrollView(frame: selectionViewRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: selectionViewRect.size))
        canvas.captureRect = captureRect
        canvas.captureScreen = screen
        canvas.preSnapshot = preSnapshot
        canvas.autoresizingMask = []

        let container = BeautifyContainerView(canvasView: canvas)
        container.autoresizingMask = []

        scrollView.documentView = container
        scrollView.editorCanvasView = canvas
        scrollView.isInteractionEnabled = false

        self.canvasScrollView = scrollView
        self.canvasView = canvas
        self.beautifyContainerView = container
        hostSelectionView.addSubview(scrollView)

        showToolbar()
        bringEditorToFront()
    }

    private func showToolbar() {
        guard let hostSelectionView else { return }
        let toolbarRect = toolbarRect(in: hostSelectionView.bounds)

        let tv = ToolbarView(frame: toolbarRect)
        tv.onToolSelected = { [weak self] tool in self?.selectTool(tool) }
        tv.onUndo = { [weak self] in self?.canvasView?.undo() }
        tv.onScrollCapture = { [weak self] in self?.toggleScrollCapture() }
        tv.onBeautify = { [weak self] in self?.toggleBeautify() }
        tv.onSave = { [weak self] in self?.save() }
        tv.onPin = { [weak self] in self?.pin() }
        tv.onClose = { [weak self] in self?.close() }
        tv.onConfirm = { [weak self] in self?.confirm() }
        styleFloatingHUD(tv)
        self.toolbarView = tv
        hostSelectionView.addSubview(tv)
    }

    func updateLayout(selectionRect: NSRect, selectionViewRect: NSRect, captureRect: CGRect) {
        self.selectionRect = selectionRect
        self.selectionViewRect = selectionViewRect
        self.captureRect = captureRect

        canvasScrollView?.frame = selectionViewRect
        canvasView?.updateViewportSize(selectionViewRect.size)
        beautifyContainerView?.canvasSizeDidChange()
        canvasView?.captureRect = captureRect
        canvasView?.captureScreen = screen
        canvasView?.needsDisplay = true

        // Update toolbar position
        if let hostSelectionView {
            toolbarView?.frame = toolbarRect(in: hostSelectionView.bounds)
        }

        // Update sub-toolbar position
        updateSubToolbarPosition()

        if isBeautifyActive {
            updateCanvasFrameForBeautify()
            if let hostSelectionView, let toolbarFrame = toolbarView?.frame {
                let width = BeautifySubToolbar.preferredWidth(presetCount: BeautifyPreset.defaults.count)
                beautifySubToolbarView?.frame = subToolbarRect(
                    width: width,
                    height: 36,
                    toolbarFrame: toolbarFrame,
                    in: hostSelectionView.bounds
                )
            }
        }
    }

    private func selectTool(_ tool: EditTool) {
        // Beautify stays active — tools and beautify coexist so the user
        // can draw on top of the beautified live preview.

        activeTool = tool
        canvasView?.activeTool = tool
        canvasView?.currentColor = currentColor
        canvasView?.currentLineWidth = currentLineWidth
        canvasView?.currentMosaicBlockSize = currentMosaicBlockSize
        toolbarView?.updateSelection(tool: tool)
        updateEditorInteractionState()

        showSubToolbar(for: tool)

        // Restore focus to the overlay window after toolbar interaction so
        // keyboard input no longer falls through to the captured app.
        bringEditorToFront()
    }

    private func showSubToolbar(for tool: EditTool) {
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil

        switch tool {
        case .pen, .rectangle, .ellipse, .arrow:
            showColorSizeSubToolbar()
        case .mosaic:
            showMosaicSubToolbar()
        default:
            break
        }
    }

    private func showColorSizeSubToolbar() {
        guard let hostSelectionView, let toolbarFrame = toolbarView?.frame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let subRect = subToolbarRect(
            width: 300,
            height: 36,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )

        let view = ColorSizeSubToolbar(frame: subRect)
        view.currentColor = currentColor
        view.currentLineWidth = currentLineWidth
        view.onColorChanged = { [weak self] color in
            self?.currentColor = color
            self?.canvasView?.currentColor = color
        }
        view.onSizeChanged = { [weak self] size in
            self?.currentLineWidth = size
            self?.canvasView?.currentLineWidth = size
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
    }

    private func showMosaicSubToolbar() {
        guard let hostSelectionView, let toolbarFrame = toolbarView?.frame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let subRect = subToolbarRect(
            width: 220,
            height: 36,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )

        let view = MosaicSubToolbar(frame: subRect)
        view.currentBlockSize = currentMosaicBlockSize
        view.onSizeChanged = { [weak self] size in
            self?.currentMosaicBlockSize = size
            self?.canvasView?.currentMosaicBlockSize = size
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
    }

    private func updateSubToolbarPosition() {
        guard
            let hostSelectionView,
            let subToolbarView,
            let toolbarFrame = toolbarView?.frame
        else { return }

        subToolbarView.frame = subToolbarRect(
            width: subToolbarView.frame.width,
            height: subToolbarView.frame.height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds
        )
    }

    // MARK: - Beautify

    private func toggleBeautify() {
        if isBeautifyActive {
            deactivateBeautify()
        } else {
            activateBeautify()
        }
    }

    private func activateBeautify() {
        guard let canvasView, let container = beautifyContainerView else { return }
        let preset = BeautifyPreset.defaultPreset

        // Beautify and annotation tools coexist — don't clear the active tool.

        // The canvas draws its content (previewImage or externalBaseImage)
        // clipped to rounded corners. For normal screenshots there's no
        // previewImage, so we snapshot the selection area once and hand it
        // to the canvas as externalBaseImage.
        canvasView.beautifyCornerRadius = BeautifyRenderer.innerCornerRadius
        if canvasView.previewImage == nil, canvasView.externalBaseImage == nil {
            canvasView.externalBaseImage = canvasView.resolveBaseImageForEditing()
        }

        currentBeautifyPreset = preset
        container.setBeautify(preset: preset)
        isBeautifyActive = true
        toolbarView?.setBeautifyActive(true)
        showBeautifySubToolbar(selecting: preset)
        repositionSubToolbarsForBeautify()
        Defaults.lastBeautifyPresetID = preset.id

        updateCanvasFrameForBeautify()
        updateEditorInteractionState()
        canvasView.needsDisplay = true
        bringEditorToFront()
    }

    private func deactivateBeautify() {
        guard let canvasView, let container = beautifyContainerView else { return }
        currentBeautifyPreset = nil

        canvasView.beautifyCornerRadius = nil
        canvasView.externalBaseImage = nil

        container.setBeautify(preset: nil)
        isBeautifyActive = false
        toolbarView?.setBeautifyActive(false)
        beautifySubToolbarView?.removeFromSuperview()
        beautifySubToolbarView = nil

        // The tool's sub-toolbar was shifted down while the gradient picker
        // was above it; restore it to the normal slot.
        repositionSubToolbarsForBeautify()

        updateCanvasFrameForBeautify()
        updateEditorInteractionState()
        canvasView.needsDisplay = true
        bringEditorToFront()
    }

    private func applyBeautifyPreset(_ preset: BeautifyPreset) {
        guard let container = beautifyContainerView else { return }
        currentBeautifyPreset = preset
        container.setBeautify(preset: preset)
        Defaults.lastBeautifyPresetID = preset.id
        beautifySubToolbarView?.currentPresetID = preset.id
        canvasView?.needsDisplay = true
        updateCanvasFrameForBeautify()
    }

    /// Reposition the active annotation-tool sub-toolbar so it sits just
    /// below the gradient picker when beautify is on (and back to the normal
    /// slot directly below the main toolbar when beautify is off).
    private func repositionSubToolbarsForBeautify() {
        guard
            let hostSelectionView,
            let toolbarFrame = toolbarView?.frame,
            let sub = subToolbarView
        else { return }

        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        sub.frame = subToolbarRect(
            width: sub.frame.width,
            height: sub.frame.height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )
    }

    private func showBeautifySubToolbar(selecting preset: BeautifyPreset) {
        guard let hostSelectionView, let toolbarFrame = toolbarView?.frame else { return }

        beautifySubToolbarView?.removeFromSuperview()

        let width = BeautifySubToolbar.preferredWidth(presetCount: BeautifyPreset.defaults.count)
        let height: CGFloat = 36
        let subRect = subToolbarRect(
            width: width,
            height: height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds
        )

        let view = BeautifySubToolbar(frame: subRect, presets: BeautifyPreset.defaults)
        view.currentPresetID = preset.id
        view.onPresetSelected = { [weak self] selected in
            self?.applyBeautifyPreset(selected)
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        beautifySubToolbarView = view
    }

    private func updateCanvasFrameForBeautify() {
        guard
            let canvasView,
            let canvasScrollView,
            let hostSelectionView,
            let container = beautifyContainerView
        else { return }

        if isBeautifyActive {
            let outer = container.outerSize
            let overlayBounds = hostSelectionView.bounds
            let targetWidth = min(outer.width, overlayBounds.width)
            let targetHeight = min(outer.height, overlayBounds.height)
            let centerX = selectionViewRect.midX
            let centerY = selectionViewRect.midY
            var x = centerX - targetWidth / 2
            var y = centerY - targetHeight / 2
            x = max(overlayBounds.minX, min(overlayBounds.maxX - targetWidth, x))
            y = max(overlayBounds.minY, min(overlayBounds.maxY - targetHeight, y))
            canvasScrollView.frame = NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
        } else {
            canvasScrollView.frame = selectionViewRect
        }

        // Reset scroll offset in case the clip view scrolled during beautify
        // resize transitions, then re-tile so the scroll view layouts match.
        canvasScrollView.contentView.setBoundsOrigin(.zero)
        canvasScrollView.reflectScrolledClipView(canvasScrollView.contentView)
        container.needsDisplay = true
        canvasView.needsDisplay = true
    }

    // MARK: - Scroll Capture

    private func toggleScrollCapture() {
        if isScrollCapturing {
            stopScrollCapture()
        } else {
            startScrollCapture()
        }
    }

    private func startScrollCapture() {
        guard canvasView?.hasPreviewImage != true else { return }

        if isBeautifyActive {
            deactivateBeautify()
        }

        isScrollCapturing = true
        activeTool = .none
        canvasView?.activeTool = .none
        toolbarView?.updateSelection(tool: .none)
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        toolbarView?.setScrollCaptureActive(true)
        hostSelectionView?.scrollCaptureActive = true
        hostSelectionView?.needsDisplay = true
        updateEditorInteractionState()

        let capturer = ScrollCapturer(rect: captureRect, screen: screen)
        capturer.onPreviewUpdated = { [weak self] image in
            self?.updateScrollPreview(image)
        }
        scrollCapturer = capturer
        installScrollMonitor()
        showScrollCaptureControl()
        toolbarView?.isHidden = true
        hostSelectionView?.window?.ignoresMouseEvents = true
        NSApp.deactivate()
    }

    private func stopScrollCapture() {
        isScrollCapturing = false
        removeScrollMonitor()
        scrollCaptureControlWindow?.dismiss()
        scrollCaptureControlWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        toolbarView?.isHidden = false
        hostSelectionView?.window?.ignoresMouseEvents = false
        hostSelectionView?.scrollCaptureActive = false
        hostSelectionView?.needsDisplay = true
        toolbarView?.setScrollCaptureActive(false)

        guard let stitchedImage = scrollCapturer?.stopAndStitch() else {
            scrollCapturer = nil
            updateEditorInteractionState()
            bringEditorToFront()
            return
        }
        scrollCapturer = nil

        canvasView?.loadPreviewImage(stitchedImage)
        beautifyContainerView?.canvasSizeDidChange()
        canvasScrollView?.scrollToTop()
        updateEditorInteractionState()
        ToastWindow.show(message: L10n.mergedLongScreenshot, on: screen)
        bringEditorToFront()
    }

    private func save() {
        guard let finalImage = currentCompositeImage() else { return }

        tearDown()
        onComplete(nil)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "screenshot.png"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            if let pngData = finalImage.pngDataPreservingBacking() {
                try? pngData.write(to: url)
            }
        }
    }

    private func pin() {
        guard let finalImage = currentCompositeImage() else { return }

        let pinWindow = NSWindow(
            contentRect: NSRect(origin: selectionRect.origin, size: finalImage.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        pinWindow.level = .floating
        pinWindow.isOpaque = false
        pinWindow.backgroundColor = .clear
        pinWindow.isMovableByWindowBackground = true
        pinWindow.hasShadow = true
        pinWindow.isReleasedWhenClosed = false

        let contentView = PinContentView(frame: NSRect(origin: .zero, size: finalImage.size))
        contentView.image = finalImage
        contentView.pinWindow = pinWindow
        pinWindow.contentView = contentView
        PinWindowManager.shared.add(pinWindow)
        pinWindow.makeKeyAndOrderFront(nil)

        tearDown()
        onComplete(nil) // Don't copy to clipboard for pin
    }

    private func close() {
        tearDown()
        onComplete(nil)
    }

    func confirmFromKeyboard() {
        confirm()
    }

    private func confirm() {
        guard let finalImage = currentCompositeImage() else {
            tearDown()
            onComplete(nil)
            return
        }
        tearDown()
        onComplete(finalImage)
    }

    func tearDown() {
        isScrollCapturing = false
        scrollCapturer = nil
        removeScrollMonitor()
        scrollCaptureControlWindow?.dismiss()
        scrollCaptureControlWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        hostSelectionView?.window?.ignoresMouseEvents = false
        canvasScrollView?.removeFromSuperview()
        canvasScrollView = nil
        canvasView = nil
        hostSelectionView?.annotationToolActive = false
        hostSelectionView?.selectionInteractionEnabled = true
        hostSelectionView?.scrollCaptureActive = false
        toolbarView?.isHidden = false
        toolbarView?.removeFromSuperview()
        toolbarView = nil
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        beautifySubToolbarView?.removeFromSuperview()
        beautifySubToolbarView = nil
        isBeautifyActive = false
    }

    private func bringEditorToFront() {
        guard let hostWindow = hostSelectionView?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        if activeTool == .none, canvasView?.hasPreviewImage != true {
            hostWindow.makeFirstResponder(hostSelectionView)
        } else {
            hostWindow.makeFirstResponder(canvasView)
        }
    }

    private func currentCompositeImage() -> NSImage? {
        let fallbackBaseImage: NSImage?
        if canvasView?.hasPreviewImage == true {
            fallbackBaseImage = nil
        } else if let snapshot = preSnapshot {
            fallbackBaseImage = ScreenCapturer.crop(from: snapshot, captureRect: captureRect, screen: screen)
        } else {
            fallbackBaseImage = ScreenCapturer.capture(rect: captureRect, screen: screen)
        }

        return canvasView?.compositeImage(
            fallbackBaseImage: fallbackBaseImage,
            beautifyPreset: currentBeautifyPreset
        )
    }

    private func installScrollMonitor() {
        removeScrollMonitor()

        scrollEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleObservedScrollEvent(event)
        }
    }

    private func removeScrollMonitor() {
        if let scrollEventMonitor {
            NSEvent.removeMonitor(scrollEventMonitor)
            self.scrollEventMonitor = nil
        }
    }

    private func handleObservedScrollEvent(_ event: NSEvent) {
        guard isScrollCapturing else { return }
        guard selectionRect.contains(NSEvent.mouseLocation) else { return }

        let deltaX = normalizedScrollDelta(event.scrollingDeltaX, isPrecise: event.hasPreciseScrollingDeltas)
        let deltaY = normalizedScrollDelta(event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas)
        guard deltaY >= deltaX, deltaY > 0 else { return }

        scrollCapturer?.scheduleCapture(observedDeltaPoints: deltaY)
    }

    private func normalizedScrollDelta(_ delta: CGFloat, isPrecise: Bool) -> CGFloat {
        let magnitude = abs(delta)
        if isPrecise {
            return magnitude
        }

        // Legacy wheel events are line-based, so approximate them in points.
        return magnitude * 18
    }

    private func updateScrollPreview(_ image: NSImage) {
        if scrollPreviewWindow == nil {
            scrollPreviewWindow = ScrollPreviewWindow()
        }
        scrollPreviewWindow?.updatePreview(image, anchorRect: selectionRect)
    }

    private func showScrollCaptureControl() {
        guard
            let hostSelectionView,
            let hostWindow = hostSelectionView.window,
            let toolbarView,
            let buttonFrame = toolbarView.scrollCaptureButtonFrame
        else {
            return
        }

        let frameInSelectionView = toolbarView.convert(buttonFrame, to: hostSelectionView)
        let frameInWindow = hostSelectionView.convert(frameInSelectionView, to: nil)
        let frameOnScreen = hostWindow.convertToScreen(frameInWindow)

        let controlWindow = ScrollCaptureControlWindow(buttonFrame: frameOnScreen) { [weak self] in
            self?.toggleScrollCapture()
        }
        scrollCaptureControlWindow = controlWindow
        controlWindow.orderFrontRegardless()
    }

    private func updateEditorInteractionState() {
        let hasPreview = canvasView?.hasPreviewImage == true
        hostSelectionView?.annotationToolActive = (activeTool != .none) || isBeautifyActive
        hostSelectionView?.selectionInteractionEnabled = !(isScrollCapturing || hasPreview || isBeautifyActive)
        canvasScrollView?.isInteractionEnabled = (activeTool != .none) || hasPreview || isBeautifyActive
        hostSelectionView?.needsDisplay = true
    }

    private func toolbarRect(in bounds: NSRect) -> NSRect {
        let width: CGFloat = 520
        let height: CGFloat = 44
        let margin: CGFloat = 8

        let x = clampedX(
            selectionViewRect.midX - width / 2,
            width: width,
            in: bounds,
            margin: margin
        )
        var y = selectionViewRect.minY - height - margin
        if y < margin {
            y = min(selectionViewRect.maxY + margin, bounds.maxY - height - margin)
        }
        y = max(margin, min(bounds.maxY - height - margin, y))

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func subToolbarRect(
        width: CGFloat,
        height: CGFloat,
        toolbarFrame: NSRect,
        in bounds: NSRect,
        offset: CGFloat = 0
    ) -> NSRect {
        let margin: CGFloat = 8
        let x = clampedX(toolbarFrame.midX - width / 2, width: width, in: bounds, margin: margin)
        var y = toolbarFrame.minY - height - 4 - offset
        if y < margin {
            y = min(toolbarFrame.maxY + 4 + offset, bounds.maxY - height - margin)
        }
        y = max(margin, min(bounds.maxY - height - margin, y))

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func clampedX(_ proposedX: CGFloat, width: CGFloat, in bounds: NSRect, margin: CGFloat) -> CGFloat {
        max(margin, min(bounds.maxX - width - margin, proposedX))
    }

    private func styleFloatingHUD(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.25
        view.layer?.shadowRadius = 10
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
}

// MARK: - Main Toolbar View

private let accentGreen = NSColor(red: 0, green: 212.0/255.0, blue: 106.0/255.0, alpha: 1.0)

private final class EditorScrollView: NSScrollView {
    weak var editorCanvasView: EditCanvasView?
    var isInteractionEnabled = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func scrollToTop() {
        guard let documentView else { return }
        let topOffset = max(0, documentView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: topOffset))
        reflectScrolledClipView(contentView)
    }
}

class ToolbarView: NSView {
    var onToolSelected: ((EditTool) -> Void)?
    var onUndo: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onBeautify: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var toolButtons: [(EditTool, ToolButton)] = []
    private var scrollCaptureBtn: ToolButton?
    private var beautifyBtn: ToolButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateSelection(tool: EditTool) {
        for (btnTool, btn) in toolButtons {
            btn.isSelected = (btnTool == tool)
        }
    }

    private func setupButtons() {
        let buttonSize: CGFloat = 32
        let spacing: CGFloat = 6
        // 13 buttons: rect, ellipse, arrow, pen, mosaic, numbered, undo, scrollCapture, beautify | save, pin, cancel, confirm
        let totalButtons = 13
        let separatorWidth: CGFloat = 8
        let totalWidth = CGFloat(totalButtons) * buttonSize + CGFloat(totalButtons - 1) * spacing + separatorWidth
        var x = (bounds.width - totalWidth) / 2
        let y = (bounds.height - buttonSize) / 2

        // Tool buttons (toggleable annotation tools)
        let tools: [(EditTool, String)] = [
            (.rectangle, "rectangle"),
            (.ellipse, "circle"),
            (.arrow, "arrow.up.right"),
            (.pen, "pencil.tip"),
            (.mosaic, "square.grid.3x3"),
            (.numbered, "1.circle"),
        ]

        for (tool, symbol) in tools {
            let btn = ToolButton(
                frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
                symbolName: symbol,
                normalColor: .white,
                selectedColor: accentGreen
            )
            btn.target = self
            btn.action = #selector(toolTapped(_:))
            btn.tag = toolButtons.count
            addSubview(btn)
            toolButtons.append((tool, btn))
            x += buttonSize + spacing
        }

        // Undo button
        let undoBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "arrow.uturn.backward",
            normalColor: .white,
            selectedColor: .white
        )
        undoBtn.target = self
        undoBtn.action = #selector(undoTapped)
        addSubview(undoBtn)
        x += buttonSize + spacing

        // Scroll capture button
        let scrollBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "arrow.up.and.down.text.horizontal",
            normalColor: .white,
            selectedColor: accentGreen
        )
        scrollBtn.target = self
        scrollBtn.action = #selector(scrollCaptureTapped)
        addSubview(scrollBtn)
        scrollCaptureBtn = scrollBtn
        x += buttonSize + spacing

        // Beautify button
        let beautifyBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "sparkles",
            normalColor: .white,
            selectedColor: accentGreen
        )
        beautifyBtn.target = self
        beautifyBtn.action = #selector(beautifyTapped)
        addSubview(beautifyBtn)
        self.beautifyBtn = beautifyBtn
        x += buttonSize + spacing + separatorWidth

        // Save button
        let saveBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "square.and.arrow.down",
            normalColor: .white,
            selectedColor: .white
        )
        saveBtn.target = self
        saveBtn.action = #selector(saveTapped)
        addSubview(saveBtn)
        x += buttonSize + spacing

        // Pin button
        let pinBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "pin",
            normalColor: .white,
            selectedColor: .white
        )
        pinBtn.target = self
        pinBtn.action = #selector(pinTapped)
        addSubview(pinBtn)
        x += buttonSize + spacing

        // Cancel button (red)
        let closeBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "xmark",
            normalColor: NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0),
            selectedColor: NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
        )
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        addSubview(closeBtn)
        x += buttonSize + spacing

        // Confirm button (green)
        let confirmBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "checkmark",
            normalColor: accentGreen,
            selectedColor: accentGreen
        )
        confirmBtn.target = self
        confirmBtn.action = #selector(confirmTapped)
        addSubview(confirmBtn)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }

    @objc private func toolTapped(_ sender: ToolButton) {
        let index = sender.tag
        guard index < toolButtons.count else { return }
        let (tool, _) = toolButtons[index]
        onToolSelected?(tool)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func scrollCaptureTapped() { onScrollCapture?() }
    @objc private func beautifyTapped() { onBeautify?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func confirmTapped() { onConfirm?() }

    func setScrollCaptureActive(_ active: Bool) {
        scrollCaptureBtn?.isSelected = active
    }

    func setBeautifyActive(_ active: Bool) {
        beautifyBtn?.isSelected = active
    }

    var scrollCaptureButtonFrame: NSRect? {
        scrollCaptureBtn?.frame
    }
}

// MARK: - Tool Button

class ToolButton: NSButton {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private let normalColor: NSColor
    private let selectedColor: NSColor

    init(frame: NSRect, symbolName: String, normalColor: NSColor, selectedColor: NSColor) {
        self.normalColor = normalColor
        self.selectedColor = selectedColor
        super.init(frame: frame)

        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            image = img.withSymbolConfiguration(config)
        }

        contentTintColor = normalColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            contentTintColor = selectedColor
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.15).setFill()
            bgPath.fill()
        } else {
            contentTintColor = normalColor
        }
        super.draw(dirtyRect)
    }
}

private final class ScrollCaptureControlWindow: NSPanel {
    init(buttonFrame: NSRect, onTap: @escaping () -> Void) {
        let padding: CGFloat = 6
        let windowRect = NSRect(
            x: buttonFrame.minX - padding,
            y: buttonFrame.minY - padding,
            width: buttonFrame.width + padding * 2,
            height: buttonFrame.height + padding * 2
        )

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 4
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = ScrollCaptureControlView(
            frame: NSRect(origin: .zero, size: windowRect.size),
            onTap: onTap
        )
    }

    func dismiss() {
        orderOut(nil)
        contentView = nil
    }
}

private final class ScrollCaptureControlView: NSView {
    private let onTap: () -> Void

    init(frame: NSRect, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        let button = ToolButton(
            frame: bounds.insetBy(dx: 6, dy: 6),
            symbolName: "arrow.up.and.down.text.horizontal",
            normalColor: .white,
            selectedColor: accentGreen
        )
        button.isSelected = true
        button.target = self
        button.action = #selector(buttonTapped)
        addSubview(button)
    }

    @objc private func buttonTapped() {
        onTap()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.92).setFill()
        path.fill()
    }
}

// MARK: - Scroll Preview Window

private final class ScrollPreviewWindow: NSPanel {
    private let imageView = NSImageView()
    private let maxPreviewWidth: CGFloat = 120
    private let maxPreviewHeight: CGFloat = 400
    private let contentInset: CGFloat = 4

    init() {
        let initialRect = NSRect(
            x: 0,
            y: 0,
            width: maxPreviewWidth + contentInset * 2,
            height: maxPreviewHeight + contentInset * 2
        )
        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let containerRect = NSRect(origin: .zero, size: initialRect.size)
        let container = NSView(frame: containerRect)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        container.layer?.borderWidth = 0.5
        container.autoresizingMask = [.width, .height]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.frame = containerRect.insetBy(dx: contentInset, dy: contentInset)
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        contentView = container
    }

    func updatePreview(_ image: NSImage, anchorRect: NSRect) {
        imageView.image = image
        let windowW = maxPreviewWidth + contentInset * 2
        let windowH = maxPreviewHeight + contentInset * 2

        // Position to the right of selection, or left if no room
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        var x = anchorRect.maxX + 12
        if x + windowW > screenFrame.maxX {
            x = anchorRect.minX - windowW - 12
        }
        // Vertically align to top of selection
        let y = anchorRect.maxY - windowH

        setFrame(NSRect(x: x, y: y, width: windowW, height: windowH), display: true)

        if !isVisible {
            orderFrontRegardless()
        }
    }

    func dismiss() {
        orderOut(nil)
        imageView.image = nil
        contentView = nil
    }
}

// MARK: - Color + Size Sub-toolbar

private class ColorSizeSubToolbar: NSView {
    var currentColor: NSColor = .red
    var currentLineWidth: CGFloat = 3.0
    var onColorChanged: ((NSColor) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?

    private var sizeButtons: [NSView] = []
    private var colorButtons: [NSView] = []

    private let sizes: [CGFloat] = [2, 4, 6]
    private let colors: [NSColor] = [
        NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),   // Red
        NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),    // Blue
        NSColor(red: 0.0, green: 0.83, blue: 0.42, alpha: 1.0),   // Green
        NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),     // Yellow
        .white,
        NSColor(white: 0.5, alpha: 1.0),                           // Gray
        .black,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x: CGFloat = 12
        let midY = bounds.midY

        // Size dots
        for (i, size) in sizes.enumerated() {
            let dotSize = 6 + CGFloat(i) * 4  // 6, 10, 14
            let dot = SizeDotView(
                frame: NSRect(x: x - dotSize/2 + 8, y: midY - dotSize/2, width: dotSize, height: dotSize),
                isSelected: abs(currentLineWidth - size) < 0.5
            )
            dot.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(sizeTapped(_:)))
            dot.addGestureRecognizer(click)
            addSubview(dot)
            sizeButtons.append(dot)
            x += dotSize + 10
        }

        x += 8

        // Separator
        let sep = NSView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(sep)
        x += 9

        // Color swatches
        let swatchSize: CGFloat = 18
        for (i, color) in colors.enumerated() {
            let swatch = ColorSwatchView(
                frame: NSRect(x: x, y: midY - swatchSize/2, width: swatchSize, height: swatchSize),
                color: color,
                isSelected: colorsMatch(color, currentColor)
            )
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(colorTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            colorButtons.append(swatch)
            x += swatchSize + 5
        }
    }

    @objc private func sizeTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? SizeDotView else { return }
        let index = view.itemIndex
        guard index < sizes.count else { return }
        currentLineWidth = sizes[index]
        onSizeChanged?(currentLineWidth)
        updateSizeSelection()
    }

    @objc private func colorTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? ColorSwatchView else { return }
        let index = view.itemIndex
        guard index < colors.count else { return }
        currentColor = colors[index]
        onColorChanged?(currentColor)
        updateColorSelection()
    }

    private func updateSizeSelection() {
        for (i, view) in sizeButtons.enumerated() {
            (view as? SizeDotView)?.isSelected = abs(currentLineWidth - sizes[i]) < 0.5
        }
    }

    private func updateColorSelection() {
        for (i, view) in colorButtons.enumerated() {
            (view as? ColorSwatchView)?.isSelected = colorsMatch(colors[i], currentColor)
        }
    }

    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.deviceRGB), let bc = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(ac.redComponent - bc.redComponent) < 0.01 &&
               abs(ac.greenComponent - bc.greenComponent) < 0.01 &&
               abs(ac.blueComponent - bc.blueComponent) < 0.01
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }
}

// MARK: - Mosaic Sub-toolbar

private class MosaicSubToolbar: NSView {
    var currentBlockSize: CGFloat = 12.0
    var onSizeChanged: ((CGFloat) -> Void)?

    private var sizeButtons: [NSView] = []
    private let sizes: [CGFloat] = [8, 12, 18]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x: CGFloat = 12
        let midY = bounds.midY

        // Size dots
        for (i, size) in sizes.enumerated() {
            let dotSize = 6 + CGFloat(i) * 4
            let dot = SizeDotView(
                frame: NSRect(x: x - dotSize/2 + 8, y: midY - dotSize/2, width: dotSize, height: dotSize),
                isSelected: abs(currentBlockSize - size) < 0.5
            )
            dot.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(sizeTapped(_:)))
            dot.addGestureRecognizer(click)
            addSubview(dot)
            sizeButtons.append(dot)
            x += dotSize + 10
        }
    }

    @objc private func sizeTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? SizeDotView else { return }
        let index = view.itemIndex
        guard index < sizes.count else { return }
        currentBlockSize = sizes[index]
        onSizeChanged?(currentBlockSize)
        for (i, v) in sizeButtons.enumerated() {
            (v as? SizeDotView)?.isSelected = (i == index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }
}

// MARK: - Size Dot View

private class SizeDotView: NSView {
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0

    init(frame: NSRect, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = isSelected ? accentGreen : NSColor.white.withAlphaComponent(0.6)
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Color Swatch View

private class ColorSwatchView: NSView {
    let color: NSColor
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0

    init(frame: NSRect, color: NSColor, isSelected: Bool) {
        self.color = color
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Draw color circle
        let inset: CGFloat = isSelected ? 1 : 2
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        color.setFill()
        path.fill()

        if isSelected {
            // Draw green selection ring
            let ring = NSBezierPath(ovalIn: bounds)
            accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }

        // Draw border for white/light colors
        if color == .white || color == NSColor(white: 0.5, alpha: 1.0) {
            let border = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.gray.withAlphaComponent(0.3).setStroke()
            border.lineWidth = 0.5
            border.stroke()
        }
    }
}

// MARK: - Pin Window Manager (retains all pinned windows)

class PinWindowManager {
    static let shared = PinWindowManager()
    private var windows: [NSWindow] = []

    func add(_ window: NSWindow) {
        windows.append(window)
    }

    func remove(_ window: NSWindow) {
        windows.removeAll { $0 === window }
    }
}

// MARK: - Pin Content View (draggable image with close button)

class PinContentView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    weak var pinWindow: NSWindow?

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
        guard let window = pinWindow else { return }
        pinWindow = nil
        window.orderOut(nil)
        window.contentView = nil
        PinWindowManager.shared.remove(window)
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
    }

    // Allow window dragging by background
    override func mouseDown(with event: NSEvent) {
        pinWindow?.performDrag(with: event)
    }
}

// MARK: - Beautify Sub-toolbar

private class BeautifySubToolbar: NSView {
    var onPresetSelected: ((BeautifyPreset) -> Void)?
    var currentPresetID: String? {
        didSet { updateSelection() }
    }

    var onPaddingChanged: ((CGFloat) -> Void)?

    private var swatchButtons: [BeautifySwatchView] = []
    private let presets: [BeautifyPreset]
    private let initialPadding: CGFloat
    private var paddingSlider: NSSlider?
    private let swatchDiameter: CGFloat = 24
    private let swatchSpacing: CGFloat = 8
    private let innerPadding: CGFloat = 12
    private let sliderWidth: CGFloat = 120
    private let sliderHeight: CGFloat = 20

    init(frame: NSRect, presets: [BeautifyPreset], initialPadding: CGFloat = BeautifyRenderer.paddingSliderDefault) {
        self.presets = presets
        self.initialPadding = initialPadding
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func preferredWidth(presetCount: Int) -> CGFloat {
        let diameter: CGFloat = 24
        let spacing: CGFloat = 8
        let innerPad: CGFloat = 12
        let separatorGap: CGFloat = 10
        let sliderWidth: CGFloat = 120
        let trailingPad: CGFloat = 12
        let swatches = CGFloat(presetCount) * diameter + CGFloat(max(presetCount - 1, 0)) * spacing
        return innerPad + swatches + separatorGap + sliderWidth + trailingPad
    }

    private func setup() {
        var x: CGFloat = innerPadding
        let midY = bounds.midY
        for (i, preset) in presets.enumerated() {
            let rect = NSRect(
                x: x,
                y: midY - swatchDiameter / 2,
                width: swatchDiameter,
                height: swatchDiameter
            )
            let swatch = BeautifySwatchView(
                frame: rect,
                preset: preset,
                isSelected: preset.id == currentPresetID
            )
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(swatchTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            swatchButtons.append(swatch)
            x += swatchDiameter + swatchSpacing
        }

        // After the loop, `x` has an extra swatchSpacing; back up to the right
        // edge of the last swatch, then lay out: 4 px gap → 1 px separator →
        // 5 px gap → slider. Total = separatorGap (10 px).
        let lastSwatchRightEdge = x - swatchSpacing
        let sepX = lastSwatchRightEdge + 4
        let sep = NSView(frame: NSRect(x: sepX, y: 6, width: 1, height: bounds.height - 12))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(sep)

        // Horizontal padding slider, 5 px to the right of the separator.
        let sliderX = sepX + 1 + 5
        let slider = NSSlider(
            value: Double(initialPadding),
            minValue: Double(BeautifyRenderer.paddingSliderMin),
            maxValue: Double(BeautifyRenderer.paddingSliderMax),
            target: self,
            action: #selector(paddingSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.frame = NSRect(
            x: sliderX,
            y: midY - sliderHeight / 2,
            width: sliderWidth,
            height: sliderHeight
        )
        addSubview(slider)
        paddingSlider = slider
    }

    @objc private func swatchTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? BeautifySwatchView else { return }
        let index = view.itemIndex
        guard index < presets.count else { return }
        let preset = presets[index]
        currentPresetID = preset.id
        onPresetSelected?(preset)
    }

    @objc private func paddingSliderChanged(_ sender: NSSlider) {
        let clamped = max(
            BeautifyRenderer.paddingSliderMin,
            min(BeautifyRenderer.paddingSliderMax, CGFloat(sender.doubleValue))
        )
        onPaddingChanged?(clamped)
    }

    private func updateSelection() {
        for swatch in swatchButtons {
            swatch.isSelected = (swatch.preset.id == currentPresetID)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }
}

private class BeautifySwatchView: NSView {
    let preset: BeautifyPreset
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0

    init(frame: NSRect, preset: BeautifyPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isSelected ? 1 : 2
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let clipPath = NSBezierPath(ovalIn: circleRect)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()

        if let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) {
            gradient.draw(in: circleRect, angle: preset.angleDegrees)
        } else {
            preset.startColor.setFill()
            circleRect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Subtle outer border so light presets remain visible on the dark toolbar
        let border = NSBezierPath(ovalIn: circleRect)
        NSColor.white.withAlphaComponent(0.15).setStroke()
        border.lineWidth = 0.5
        border.stroke()

        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds)
            accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
