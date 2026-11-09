import AppKit
import Carbon
import QuartzCore
import UniformTypeIdentifiers

enum EditorToolbarPlacement {
    private static let edgeMargin: CGFloat = 8

    static func primaryToolbarRect(
        referenceRect: NSRect,
        in bounds: NSRect,
        size: NSSize,
        topSafeInset: CGFloat
    ) -> NSRect {
        let width = size.width
        let height = size.height
        let margin = edgeMargin
        let minimumX = bounds.minX + margin
        let maximumX = bounds.maxX - width - margin
        let x = max(minimumX, min(maximumX, referenceRect.maxX - width))

        let minimumY = bounds.minY + margin
        let maximumY = bounds.maxY - max(0, topSafeInset) - height - margin
        var y = referenceRect.minY - height - margin
        if y < minimumY {
            y = min(referenceRect.maxY + margin, maximumY)
        }
        y = max(minimumY, min(maximumY, y))

        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func sideToolbarRect(
        referenceRect: NSRect,
        in bounds: NSRect,
        size: NSSize,
        avoiding primaryFrame: NSRect? = nil
    ) -> NSRect {
        let width = size.width
        let height = size.height
        let margin = edgeMargin

        let minimumX = bounds.minX + margin
        let maximumX = bounds.maxX - width - margin
        var x = referenceRect.maxX + margin
        if x + width > bounds.maxX - margin {
            x = referenceRect.minX - width - margin
        }
        x = max(minimumX, min(maximumX, x))

        let minimumY = bounds.minY + margin
        let maximumY = bounds.maxY - height - margin
        var y = max(minimumY, min(maximumY, referenceRect.minY))

        var rect = NSRect(x: x, y: y, width: width, height: height)

        if let primary = primaryFrame, rect.intersects(primary) {
            // Try to sit fully above the primary toolbar's band; fall back
            // to below it when there isn't enough headroom.
            let above = primary.maxY + margin
            if above + height <= bounds.maxY - margin {
                y = above
            } else {
                y = max(minimumY, primary.minY - margin - height)
            }
            rect.origin.y = y
        }

        return rect
    }
}

struct FixedImageCropGeometry {
    static func adjustedSourceRect(
        _ sourceRect: NSRect,
        from oldViewport: NSRect,
        to newViewport: NSRect,
        imageBounds: NSRect
    ) -> NSRect {
        guard oldViewport.width > 0, oldViewport.height > 0,
              sourceRect.width > 0, sourceRect.height > 0,
              imageBounds.width > 0, imageBounds.height > 0
        else { return sourceRect }

        let scaleX = sourceRect.width / oldViewport.width
        let scaleY = sourceRect.height / oldViewport.height
        let proposed = NSRect(
            x: sourceRect.minX + (newViewport.minX - oldViewport.minX) * scaleX,
            y: sourceRect.minY + (newViewport.minY - oldViewport.minY) * scaleY,
            width: sourceRect.width + (newViewport.width - oldViewport.width) * scaleX,
            height: sourceRect.height + (newViewport.height - oldViewport.height) * scaleY
        ).standardized
        let clipped = proposed.intersection(imageBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return sourceRect
        }
        return clipped
    }
}

enum FixedImageCropRenderer {
    static func crop(_ image: NSImage, to sourceRect: NSRect) -> NSImage? {
        let imageBounds = NSRect(origin: .zero, size: image.size)
        let clipped = sourceRect.standardized.intersection(imageBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        if clipped.equalTo(imageBounds) {
            return image
        }

        guard let cgImage = image.cgImagePreservingBacking() else { return nil }
        let scaleX = CGFloat(cgImage.width) / imageBounds.width
        let scaleY = CGFloat(cgImage.height) / imageBounds.height
        let pixelsWide = max(1, Int(round(clipped.width * scaleX)))
        let pixelsHigh = max(1, Int(round(clipped.height * scaleY)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }
        bitmap.size = clipped.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .none
        image.draw(
            in: NSRect(origin: .zero, size: clipped.size),
            from: clipped,
            operation: .copy,
            fraction: 1
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: clipped.size)
        result.addRepresentation(bitmap)
        return result
    }
}

class EditWindowController {
    private var canvasView: EditCanvasView?
    private var beautifyContainerView: BeautifyContainerView?
    private var canvasScrollView: EditorScrollView?
    private var selectionChromeOverlay: SelectionChromeOverlay?
    private weak var hostSelectionView: SelectionView?
    private var toolbarView: ToolbarView?
    /// Optional vertical toolbar on the left/right of the selection. Created
    /// only when the user has assigned tools to it in settings.
    private var sideToolbarView: ToolbarView?
    private var subToolbarView: NSView?
    private var qrCodeOverlayView: QRCodeChoiceOverlayView?
    private var qrCodeDetectionGeneration = 0
    private var captureRect: CGRect
    private var screen: NSScreen
    private var selectionRect: NSRect
    private var selectionViewRect: NSRect
    private let onComplete: (NSImage?) -> Void
    private let onRecordingSelection: ((NSRect, NSScreen) -> Void)?
    private let onRequestFocusReturn: (() -> Void)?
    private var activeTool: EditTool = .none
    private var beautifySubToolbarView: BeautifySubToolbar?
    private var isBeautifyActive: Bool = false
    private var currentBeautifyPreset: BeautifyPreset?
    private var currentBeautifyShadowSize: CGFloat = CGFloat(Defaults.lastBeautifyShadowSize)
    private var isAdjustingBeautifyShadowSize = false

    /// True when the capture came from clicking a single window (not a free
    /// drag). Drives the rounded-corner + drop-shadow effect on the final
    /// output. Cleared by OverlayWindowController if the user resizes the
    /// selection, since the rect no longer matches the window.
    var isWindowCapture: Bool = false

    // Pre-captured screen snapshot (preserves transient menus/popups)
    private let preSnapshot: CGImage?

    /// Image-edit mode: when set, this image replaces the screen-capture
    /// pipeline as the editor's base image (no live capture, no preSnapshot
    /// crop). Also disables scroll capture, which is a screen-only concept.
    private var overrideBaseImage: NSImage?
    private var overrideBaseImageCropRect: NSRect?
    private var croppedOverrideBaseImage: NSImage?

    /// Single-window capture with the WindowServer's real alpha silhouette.
    /// Used as the base image and annotation clip mask for clicked-window
    /// captures so the final corners match the system window exactly.
    private var windowBaseImage: NSImage?
    private var windowCapturePreparation: WindowCapturePreparation?
    private var windowCaptureObserver: UUID?
    private var pendingWindowCaptureAction: ToolbarItemID?
    private var windowCaptureWaitAlert: NSAlert?

    private var isPreparingWindowCapture: Bool {
        windowCapturePreparation?.isComplete == false
    }

    var isWaitingForWindowCaptureOutput: Bool { windowCaptureWaitAlert != nil }
    private let keepsHostWindowAcrossSpaces: Bool

    // Scroll capture state
    private var scrollCapturer: ScrollCapturer?
    private var scrollCaptureSessionID: UUID?
    private var isScrollCapturing = false
    private var isScrollCaptureFinalizing = false
    private var scrollCaptureControlWindow: ScrollCaptureControlWindow?
    private var scrollPreviewWindow: ScrollPreviewWindow?
    /// Persistent finish hint shown inside the selection during scroll
    /// capture. Excluded from the capture so it never appears in
    /// the stitched long screenshot.
    private var scrollCaptureHintWindow: ScrollCaptureHintWindow?
    private var autoScroller: AutoScroller?
    private var manualScrollCaptureTimer: DispatchSourceTimer?
    /// Key monitor while capcap is deactivated for scroll capture, so any key
    /// stops scrolling and opens the captured image for cropping.
    private var scrollCaptureKeyMonitor: Any?

    // Crop mode state, shown between scroll capture and the editor.
    private var isCropping = false
    private var scrollCropView: ScrollCropView?
    private var scrollCropControlWindow: ScrollCropControlWindow?

    var blocksHistoryNavigation: Bool {
        isWaitingForWindowCaptureOutput || isScrollCaptureBusy || isCropping
    }

    private var isScrollCaptureBusy: Bool {
        isScrollCapturing || isScrollCaptureFinalizing
    }

    private var shouldShowSelectionChrome: Bool {
        Self.shouldShowSelectionChrome(
            hasPreviewImage: canvasView?.hasPreviewImage == true,
            isScrollCaptureBusy: isScrollCaptureBusy,
            isCropping: isCropping
        )
    }

    static func shouldShowSelectionChrome(
        hasPreviewImage: Bool,
        isScrollCaptureBusy: Bool,
        isCropping: Bool
    ) -> Bool {
        !hasPreviewImage && !isScrollCaptureBusy && !isCropping
    }

    private var isLiveScreenCaptureSession: Bool {
        overrideBaseImage == nil && onRecordingSelection != nil
    }

    private var isScrollCaptureAllowed: Bool {
        isLiveScreenCaptureSession && !isWindowCapture
    }

    struct RestorableState {
        let canvasState: EditCanvasView.RestorableState
        let beautifyState: BeautifyState
        let overrideBaseImageCropRect: NSRect?
        let overrideBaseImage: NSImage?
        let selectionRect: NSRect
        let selectionViewRect: NSRect
        let captureRect: CGRect
        let selectionAdjustmentBounds: NSRect?
        var windowCapturePreparation: WindowCapturePreparation? = nil
    }

    struct BeautifyState {
        let isActive: Bool
        let presetID: String?
        let shadowSize: CGFloat
    }

    // Drawing properties
    private var currentColor: NSColor = EditorStyleDefaults.primaryColor
    private var currentLineWidth: CGFloat = EditorStyleDefaults.standardLineWidth
    private var currentNumberSize: CGFloat = EditorStyleDefaults.numberSize
    private var currentArrowStyle: ArrowStyle = Defaults.lastArrowStyle
    private var currentMosaicBlockSize: CGFloat = CGFloat(Defaults.mosaicBlockSize)
    private var currentMosaicStyle: MosaicStyle = Defaults.mosaicStyle
    private var currentMosaicBlurRadius: CGFloat = CGFloat(Defaults.mosaicBlurRadius)
    private var currentFontSize: CGFloat = CGFloat(Defaults.lastTextFontSize)
    /// Font family for new text annotations. nil = the system bold default.
    private var currentFontName: String? = Defaults.textFontName
    /// Whether new text annotations get a contrast outline.
    private var currentTextStroke: Bool = Defaults.lastTextStroke
    /// Whether new text annotations render as callout bubbles with an arrow handle.
    private var currentTextCallout: Bool = Defaults.lastTextCallout
    /// Whether new rectangle/ellipse annotations are filled.
    private var currentShapeFillMode: ShapeFillMode = Defaults.lastShapeFillMode
    private var currentShapeStrokeStyle: ShapeStrokeStyle = Defaults.lastShapeStrokeStyle
    /// Marker keeps its own color/size slot so toggling between pen and
    /// marker preserves each tool's last-used choice.
    private var currentMarkerColor: NSColor = EditorStyleDefaults.markerColor
    private var currentMarkerLineWidth: CGFloat = EditorStyleDefaults.markerLineWidth
    private var currentEmoji: String?
    private var recentEmojis: [String] = Defaults.recentEmojis
    private var emojiPopover: NSPopover?
    private var beautifyPresetPopover: NSPopover?
    private var beautifyToolbarPresetIDs: [String] = Defaults.beautifyToolbarPresetIDs
    /// Last color sampled from the toolbar eyedropper. Persisted locally and
    /// shown as an ink-bottle control for color-capable annotation tools.
    private var pickedColorSwatch: NSColor?

    var isTextEditing: Bool {
        canvasView?.isTextEditing == true
    }

    init(
        captureRect: CGRect,
        screen: NSScreen,
        selectionRect: NSRect,
        selectionViewRect: NSRect,
        hostSelectionView: SelectionView,
        preSnapshot: CGImage? = nil,
        overrideBaseImage: NSImage? = nil,
        windowBaseImage: NSImage? = nil,
        isWindowCapture: Bool = false,
        onRecordingSelection: ((NSRect, NSScreen) -> Void)? = nil,
        onRequestFocusReturn: (() -> Void)? = nil,
        keepsHostWindowAcrossSpaces: Bool = false,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.captureRect = captureRect
        self.screen = screen
        self.selectionRect = selectionRect
        self.selectionViewRect = selectionViewRect
        self.hostSelectionView = hostSelectionView
        self.preSnapshot = preSnapshot
        self.overrideBaseImage = overrideBaseImage
        if let overrideBaseImage {
            let imageBounds = NSRect(origin: .zero, size: overrideBaseImage.size)
            self.overrideBaseImageCropRect = imageBounds
            self.croppedOverrideBaseImage = overrideBaseImage
        } else {
            self.overrideBaseImageCropRect = nil
            self.croppedOverrideBaseImage = nil
        }
        self.windowBaseImage = windowBaseImage
        self.keepsHostWindowAcrossSpaces = keepsHostWindowAcrossSpaces
        self.isWindowCapture = isWindowCapture
        self.onRecordingSelection = onRecordingSelection
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onComplete = onComplete
        self.pickedColorSwatch = Self.color(fromHex: Defaults.lastPickedColorHex)
    }

    func attachWindowCapturePreparation(_ preparation: WindowCapturePreparation?) {
        detachWindowCapturePreparation()
        guard let preparation else { return }
        windowCapturePreparation = preparation
        windowCaptureObserver = preparation.observe { [weak self, weak preparation] image in
            guard let self, let preparation,
                  self.windowCapturePreparation === preparation else { return }
            self.applyPreparedWindowImage(image)
        }
    }

    private func detachWindowCapturePreparation() {
        if let windowCaptureObserver {
            windowCapturePreparation?.removeObserver(windowCaptureObserver)
        }
        windowCaptureObserver = nil
        windowCapturePreparation = nil
    }

    private func applyPreparedWindowImage(_ image: NSImage) {
        guard let canvasView else { return }
        // Rotation turns the frozen capture into a fixed-image document. Keep
        // its source coordinates and crop, replacing only that source's alpha.
        if overrideBaseImage != nil {
            overrideBaseImage = image
            croppedOverrideBaseImage = overrideBaseImageCropRect.flatMap {
                FixedImageCropRenderer.crop(image, to: $0)
            } ?? image
            canvasView.overrideBaseImage = effectiveOverrideBaseImage
        }
        if isWindowCapture {
            windowBaseImage = image
            canvasView.windowBaseImage = image
        }
        if isBeautifyActive, canvasView.previewImage == nil {
            canvasView.externalBaseImage = effectiveOverrideBaseImage ?? image
        }
        canvasView.needsDisplay = true
        // No show(), restoreState(), focus change, or undo mutation here: an
        // annotation gesture may be in progress while the worker completes.
        if let alert = windowCaptureWaitAlert {
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .OK)
        }
    }

    func show() {
        guard let hostSelectionView else {
            onComplete(nil)
            requestFocusReturn()
            return
        }

        let canvasSize = canvasContentSize(for: selectionViewRect.size)
        let scrollView = EditorScrollView(frame: selectionViewRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = canvasSize.height > selectionViewRect.height + 0.5
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.hostSelectionView = hostSelectionView
        canvas.captureRect = captureRect
        canvas.captureScreen = screen
        canvas.preSnapshot = preSnapshot
        canvas.overrideBaseImage = effectiveOverrideBaseImage
        canvas.windowBaseImage = windowBaseImage
        canvas.autoresizingMask = []
        canvas.onAnnotationSelected = { [weak self] annotation in
            self?.handleAnnotationSelectionChanged(annotation)
        }
        canvas.onMultiSelectionChanged = { [weak self] isMultiSelecting in
            if isMultiSelecting {
                self?.selectTool(.none)
            }
        }
        canvas.onHistoryStateChanged = { [weak self] canUndo, canRedo in
            self?.updateHistoryButtons(canUndo: canUndo, canRedo: canRedo)
        }
        canvas.onImageRotationChanged = { [weak self] in
            self?.layoutRotatedImage()
        }
        canvas.onEmojiStamped = { [weak self] in
            self?.handleEmojiStamped()
        }

        let container = BeautifyContainerView(canvasView: canvas)
        container.autoresizingMask = []

        scrollView.documentView = container
        scrollView.editorCanvasView = canvas
        scrollView.isInteractionEnabled = overrideBaseImage != nil

        self.canvasScrollView = scrollView
        self.canvasView = canvas
        self.beautifyContainerView = container
        hostSelectionView.addSubview(scrollView)
        resetCanvasScrollPosition()

        // Sits above `scrollView` so the dashed border + handles stay
        // visible when beautify expands the canvas frame with a gradient
        // background. Only handle hits are claimed; everything else falls
        // through to the canvas / SelectionView underneath.
        let overlay = SelectionChromeOverlay(frame: hostSelectionView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.selectionView = hostSelectionView
        hostSelectionView.addSubview(overlay)
        self.selectionChromeOverlay = overlay

        showToolbar()
        // The first editor frame includes the interactive canvas, border,
        // handles and toolbar, even while its precise silhouette is pending.
        repositionFloatingChrome()
        updateEditorInteractionState()
        updateHistoryButtons(canUndo: canvas.canUndo, canRedo: canvas.canRedo)
        if Defaults.lastBeautifyEnabled {
            activateBeautify()
        }
        bringEditorToFront()
    }

    private func showToolbar() {
        guard let hostSelectionView else { return }
        let layout = Defaults.toolbarLayout

        // Each toolbar exists only when the user has assigned tools to it.
        if !layout.primary.isEmpty {
            let tv = ToolbarView(items: layout.primary, orientation: .horizontal)
            wireToolbarCallbacks(tv)
            tv.frame = toolbarRect(in: hostSelectionView.bounds, size: tv.preferredSize)
            styleFloatingHUD(tv)
            self.toolbarView = tv
            hostSelectionView.addSubview(tv)
        }

        if !layout.side.isEmpty {
            let sv = ToolbarView(items: layout.side, orientation: .vertical)
            wireToolbarCallbacks(sv)
            sv.frame = sideToolbarRect(
                in: hostSelectionView.bounds,
                size: sv.preferredSize,
                avoiding: toolbarView?.frame
            )
            styleFloatingHUD(sv)
            self.sideToolbarView = sv
            hostSelectionView.addSubview(sv)
        }

        updateCaptureActionAvailability()
    }

    /// Injects the controller's action callbacks into a toolbar. Both the
    /// primary and the side toolbar share the same wiring — a tool behaves
    /// identically regardless of which bar it was dragged to.
    private func wireToolbarCallbacks(_ tv: ToolbarView) {
        tv.onItemTriggered = { [weak self] item in
            _ = self?.performToolbarItem(item, togglesSelectedTool: true)
        }
        tv.onMoveSelectionStart = { [weak self] in self?.handleMoveSelectionStart() }
        tv.onMoveSelectionDrag = { [weak self] delta in self?.handleMoveSelectionDrag(delta: delta) }
        tv.onMoveSelectionEnd = { [weak self] in self?.handleMoveSelectionEnd() }
    }

    @discardableResult
    private func performToolbarItem(
        _ item: ToolbarItemID,
        togglesSelectedTool: Bool
    ) -> Bool {
        if isWaitingForWindowCaptureOutput {
            if item == .close { close() }
            return true
        }
        if let tool = item.editTool {
            selectTool(togglesSelectedTool && activeTool == tool ? .none : tool)
            return true
        }

        switch item {
        case .insertImage:
            showInsertImageMenu()
        case .colorPicker:
            runColorPicker()
        case .undo:
            _ = canvasView?.undo()
        case .redo:
            _ = canvasView?.redo()
        case .scrollCapture:
            toggleScrollCapture()
        case .beautify:
            toggleBeautify()
        case .rotate:
            showRotationSubToolbar()
        case .qrCode:
            performQRCodeRecognition()
        case .ocr:
            performOCR()
        case .screenshotTranslate:
            performScreenshotTranslation()
        case .save:
            save()
        case .upload:
            guard Defaults.hasUsableUploadProvider else { return false }
            upload()
        case .pin:
            pin()
        case .record:
            guard onRecordingSelection != nil else { return false }
            record()
        case .close:
            close()
        case .confirm:
            confirmFromKeyboard()
        case .moveSelection:
            return false
        case .rectangle, .ellipse, .arrow, .line, .pen, .marker, .spotlight,
             .mosaic, .eraser, .magnifier, .numbered, .text, .emoji:
            return false
        }
        return true
    }

    /// Output is one explicit transaction. A sheet freezes input only after an
    /// output request, so its annotations cannot change while alpha is pending.
    /// Subsequent hotkeys cannot overwrite the original intent; Cancel resumes
    /// editing without canceling the document's background preparation.
    private func deferUntilWindowCaptureReady(_ item: ToolbarItemID) -> Bool {
        guard isPreparingWindowCapture else { return false }
        guard pendingWindowCaptureAction == nil else { return true }
        guard let hostWindow = hostSelectionView?.window else { return true }
        canvasView?.commitActiveTextEditing()
        dismissEmojiPopover()
        dismissBeautifyPresetPopover()
        pendingWindowCaptureAction = item
        let alert = NSAlert()
        alert.messageText = L10n.windowCapturePreparing
        alert.addButton(withTitle: L10n.tipCancel)
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        alert.accessoryView = spinner
        windowCaptureWaitAlert = alert
        alert.beginSheetModal(for: hostWindow) { [weak self, weak alert] response in
            guard let self, let alert, self.windowCaptureWaitAlert === alert else { return }
            let action = self.pendingWindowCaptureAction
            self.pendingWindowCaptureAction = nil
            self.windowCaptureWaitAlert = nil
            if response == .OK, let action {
                _ = self.performToolbarItem(action, togglesSelectedTool: false)
            } else {
                self.bringEditorToFront()
            }
        }
        return true
    }

    @discardableResult
    func cancelWindowCaptureOutput() -> Bool {
        guard let alert = windowCaptureWaitAlert else { return false }
        pendingWindowCaptureAction = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
        return true
    }

    func handleWindowCaptureWaitKeyDown(_ event: NSEvent) -> Bool {
        guard isWaitingForWindowCaptureOutput else { return false }
        if event.keyCode == 53 { cancelWindowCaptureOutput() }
        return true
    }

    /// Primary + side toolbars currently on screen.
    private var toolbars: [ToolbarView] {
        [toolbarView, sideToolbarView].compactMap { $0 }
    }

    private func updateHistoryButtons(canUndo: Bool, canRedo: Bool) {
        toolbars.forEach {
            $0.setUndoEnabled(canUndo)
            $0.setRedoEnabled(canRedo)
        }
    }

    private func updateCaptureActionAvailability() {
        let scrollCaptureEnabled = isScrollCaptureAllowed && !isScrollCaptureBusy && canvasView?.hasPreviewImage != true
        let recordingEnabled = isLiveScreenCaptureSession && !isScrollCaptureBusy
        toolbars.forEach {
            $0.setScrollCaptureEnabled(scrollCaptureEnabled)
            $0.setRecordingEnabled(recordingEnabled)
        }
    }

    /// Frame the option sub-toolbars (color/size, text, beautify) anchor
    /// against — the primary toolbar when it exists, otherwise the side
    /// toolbar, so options still appear if the user emptied the primary bar.
    private var subToolbarAnchorFrame: NSRect? {
        toolbarView?.frame ?? sideToolbarView?.frame
    }

    func updateLayout(selectionRect: NSRect, selectionViewRect: NSRect, captureRect: CGRect) {
        dismissQRCodeOverlay()
        if !isWindowCapture, overrideBaseImage == nil {
            detachWindowCapturePreparation()
            windowBaseImage = nil
        }
        let previousSelectionViewRect = self.selectionViewRect
        self.selectionRect = selectionRect
        self.selectionViewRect = selectionViewRect
        self.captureRect = captureRect

        if let overrideBaseImage,
           let currentCropRect = overrideBaseImageCropRect {
            let rotation = canvasView?.imageRotation ?? .none
            let transform = rotation.transform(for: overrideBaseImage.size)
            let imageBounds = NSRect(origin: .zero, size: rotation.orientedSize(overrideBaseImage.size))
            let orientedCropRect = FixedImageCropGeometry.adjustedSourceRect(
                currentCropRect.applying(transform),
                from: previousSelectionViewRect,
                to: selectionViewRect,
                imageBounds: imageBounds
            )
            let adjustedCropRect = orientedCropRect.applying(transform.inverted())
            canvasView?.preserveAnnotationImagePositions(from: currentCropRect, to: adjustedCropRect)
            overrideBaseImageCropRect = adjustedCropRect
            croppedOverrideBaseImage = FixedImageCropRenderer.crop(
                overrideBaseImage,
                to: adjustedCropRect
            ) ?? croppedOverrideBaseImage
            canvasView?.overrideBaseImage = effectiveOverrideBaseImage
            hostSelectionView?.selectionSizeLabelOverride = Self.cropSizeLabelText(
                rotation.orientedSize(adjustedCropRect.size)
            )
        }

        if !isWindowCapture {
            canvasView?.windowBaseImage = nil
        }

        let canvasSize = canvasContentSize(for: selectionViewRect.size)
        if overrideBaseImage == nil {
            canvasView?.preserveAnnotationScreenPositions(
                from: previousSelectionViewRect,
                to: selectionViewRect
            )
        }
        canvasView?.updateViewportSize(canvasSize)
        beautifyContainerView?.canvasSizeDidChange()
        canvasView?.captureRect = captureRect
        canvasView?.captureScreen = screen

        if isBeautifyActive {
            canvasView?.beautifyCornerRadius = isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius
        }

        // Beautify caches the cropped screenshot in `externalBaseImage` so the
        // canvas can clip it to rounded corners. Without re-cropping here, a
        // selection resize would just stretch the cached image to the new
        // canvas frame instead of revealing a different region of the screen.
        if isBeautifyActive,
           let canvasView,
           canvasView.previewImage == nil {
            canvasView.externalBaseImage = windowShapedBaseImage(
                from: canvasView.resolveBaseImageForEditing()
            )
        }

        canvasView?.needsDisplay = true

        // Resize the scroll view (and beautified outer when active) before
        // positioning floating chrome so toolbar anchors against the right rect.
        updateCanvasFrameForBeautify()

        updateCaptureActionAvailability()
        repositionFloatingChrome()
    }

    private func canvasContentSize(for viewportSize: NSSize) -> NSSize {
        guard
            let image = effectiveOverrideBaseImage,
            image.size.width > 0,
            image.size.height > 0,
            viewportSize.width > 0
        else {
            return viewportSize
        }

        let rotation = canvasView?.imageRotation ?? .none
        let presentationScale = canvasView?.presentationScale ?? 1
        let scale = viewportSize.width / rotation.orientedSize(image.size).width / presentationScale
        return NSSize(
            width: image.size.width * scale,
            height: max(1, floor(image.size.height * scale))
        )
    }

    private var effectiveOverrideBaseImage: NSImage? {
        croppedOverrideBaseImage ?? overrideBaseImage
    }

    private static func cropSizeLabelText(_ size: NSSize) -> String {
        "\(max(1, Int(round(size.width)))) x \(max(1, Int(round(size.height))))"
    }

    private func selectTool(_ tool: EditTool) {
        // Beautify stays active — tools and beautify coexist so the user
        // can draw on top of the beautified live preview.
        dismissQRCodeOverlay()

        if tool != .none {
            canvasView?.clearMultiSelection()
        }
        activeTool = tool
        canvasView?.activeTool = tool
        normalizeShapeStrokeStyle(for: tool)
        pushCurrentStyleToCanvas()
        toolbars.forEach { $0.updateSelection(tool: tool) }
        updateEditorInteractionState()

        showSubToolbar(for: tool)

        // Restore focus to the overlay window after toolbar interaction so
        // keyboard input no longer falls through to the captured app.
        bringEditorToFront()
    }

    /// Selection in the canvas changed. When an annotation gets selected we
    /// switch to its matching tool and rebuild the sub-toolbar with the
    /// annotation's own values, so the user can adjust color / size /
    /// font-size of the selected mark without entering edit mode.
    private func handleAnnotationSelectionChanged(_ annotation: Annotation?) {
        guard let annotation else { return }
        guard let tool = tool(for: annotation), tool != .none else { return }

        seedCurrentValues(from: annotation)
        pushCurrentStyleToCanvas()

        if activeTool != tool {
            // selectTool rebuilds the sub-toolbar; the seeded values flow in.
            selectTool(tool)
        } else {
            // Same tool — rebuild the sub-toolbar to refresh displayed values.
            showSubToolbar(for: tool)
        }
    }

    private func pushCurrentStyleToCanvas() {
        canvasView?.currentColor = currentColor
        canvasView?.currentLineWidth = currentLineWidth
        canvasView?.currentNumberSize = currentNumberSize
        canvasView?.currentArrowStyle = currentArrowStyle
        canvasView?.currentMosaicBlockSize = currentMosaicBlockSize
        canvasView?.currentMosaicStyle = currentMosaicStyle
        canvasView?.currentMosaicBlurRadius = currentMosaicBlurRadius
        canvasView?.currentFontSize = currentFontSize
        canvasView?.currentFontName = currentFontName
        canvasView?.currentTextStroke = currentTextStroke
        canvasView?.currentTextCallout = currentTextCallout
        canvasView?.currentShapeFillMode = currentShapeFillMode
        canvasView?.currentShapeStrokeStyle = currentShapeStrokeStyle
        canvasView?.currentEmoji = currentEmoji
        canvasView?.currentMarkerColor = currentMarkerColor
        canvasView?.currentMarkerLineWidth = currentMarkerLineWidth
    }

    private func tool(for annotation: Annotation) -> EditTool? {
        switch annotation {
        case is TextAnnotation: return .text
        case is RectAnnotation: return .rectangle
        case is EllipseAnnotation: return .ellipse
        case is ArrowAnnotation: return .arrow
        case is LineAnnotation: return .line
        case is PenAnnotation: return .pen
        case is MarkerAnnotation: return .marker
        case is SpotlightAnnotation: return .spotlight
        case is MosaicAnnotation: return .mosaic
        case is MagnifierAnnotation: return .magnifier
        case is NumberAnnotation: return .numbered
        case is EmojiAnnotation: return .emoji
        default: return nil
        }
    }

    /// Pull color / size / font-size off the annotation into the matching
    /// "current" slot so the next sub-toolbar rebuild reflects them and
    /// any new annotation created afterward inherits the same look.
    private func seedCurrentValues(from annotation: Annotation) {
        switch annotation {
        case let t as TextAnnotation:
            currentColor = t.color
            currentFontSize = t.fontSize
            currentFontName = t.fontName
            currentTextStroke = t.hasStroke
            currentTextCallout = t.hasCallout
        case let p as PenAnnotation:
            currentColor = p.color
            currentLineWidth = p.lineWidth
        case let m as MarkerAnnotation:
            currentMarkerColor = m.color
            currentMarkerLineWidth = m.lineWidth
        case let mosaic as MosaicAnnotation:
            currentMosaicBlockSize = mosaic.blockSize
            currentMosaicStyle = mosaic.style
            currentMosaicBlurRadius = mosaic.blurRadius
        case let magnifier as MagnifierAnnotation:
            currentColor = magnifier.color
            currentLineWidth = magnifier.lineWidth
        case let r as RectAnnotation:
            currentColor = r.color
            currentLineWidth = r.lineWidth
            currentShapeFillMode = r.fillMode
            currentShapeStrokeStyle = r.strokeStyle
        case let e as EllipseAnnotation:
            currentColor = e.color
            currentLineWidth = e.lineWidth
            currentShapeFillMode = e.fillMode
            currentShapeStrokeStyle = e.strokeStyle == .rounded ? .standard : e.strokeStyle
        case let a as ArrowAnnotation:
            currentColor = a.color
            currentLineWidth = a.lineWidth
            currentArrowStyle = a.style
            canvasView?.currentColor = a.color
            canvasView?.currentLineWidth = a.lineWidth
            canvasView?.currentArrowStyle = a.style
        case let l as LineAnnotation:
            currentColor = l.color
            currentLineWidth = l.lineWidth
        case let n as NumberAnnotation:
            currentColor = n.color
            currentNumberSize = n.size
        case is EmojiAnnotation:
            currentEmoji = nil
            canvasView?.currentEmoji = nil
        default:
            break
        }
    }

    private func normalizeShapeStrokeStyle(for tool: EditTool) {
        guard tool == .ellipse, currentShapeStrokeStyle == .rounded else { return }
        currentShapeStrokeStyle = .standard
    }

    private func showSubToolbar(for tool: EditTool) {
        dismissEmojiPopover()
        dismissBeautifyPresetPopover()
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        toolbars.forEach { $0.setActive(false, for: .rotate) }

        switch tool {
        case .pen, .line:
            showColorSizeSubToolbar(
                sizes: EditorStyleDefaults.standardLineSizes,
                dynamicColor: pickedColorSwatch,
                currentSize: currentLineWidth,
                onSize: { [weak self] size in
                    self?.setCurrentDrawingLineWidth(size)
                }
            )
        case .arrow:
            showColorSizeSubToolbar(
                sizes: EditorStyleDefaults.standardLineSizes,
                dynamicColor: pickedColorSwatch,
                currentSize: currentLineWidth,
                width: ColorSizeSubToolbar.preferredWidth(
                    sizes: EditorStyleDefaults.standardLineSizes,
                    dynamicColor: pickedColorSwatch,
                    showsShapeFillModes: false,
                    showsArrowStyles: true
                ),
                onSize: { [weak self] size in
                    self?.setCurrentDrawingLineWidth(size)
                },
                arrowStyle: currentArrowStyle,
                onArrowStyle: { [weak self] style in
                    self?.setArrowStyle(style)
                }
            )
        case .rectangle, .ellipse:
            showColorSizeSubToolbar(
                sizes: EditorStyleDefaults.standardLineSizes,
                dynamicColor: pickedColorSwatch,
                currentSize: currentLineWidth,
                width: ColorSizeSubToolbar.preferredWidth(
                    sizes: EditorStyleDefaults.standardLineSizes,
                    dynamicColor: pickedColorSwatch,
                    showsShapeFillModes: true,
                    showsShapeStrokeStyles: true,
                    shapeStrokePreviewShape: tool == .ellipse ? .ellipse : .rectangle
                ),
                onSize: { [weak self] size in
                    self?.setCurrentDrawingLineWidth(size)
                },
                shapeFillMode: currentShapeFillMode,
                onShapeFillMode: { [weak self] mode in
                    self?.setShapeFillMode(mode)
                },
                shapeStrokeStyle: currentShapeStrokeStyle,
                shapeStrokePreviewShape: tool == .ellipse ? .ellipse : .rectangle,
                onShapeStrokeStyle: { [weak self] style in
                    self?.setShapeStrokeStyle(style)
                }
            )
        case .magnifier:
            showColorSizeSubToolbar(
                sizes: EditorStyleDefaults.standardLineSizes,
                dynamicColor: pickedColorSwatch,
                currentSize: currentLineWidth,
                onSize: { [weak self] size in
                    self?.setCurrentDrawingLineWidth(size)
                }
            )
        case .marker:
            showColorSizeSubToolbar(
                sizes: EditorStyleDefaults.markerLineSizes,
                currentColor: currentMarkerColor,
                dynamicColor: pickedColorSwatch,
                currentSize: currentMarkerLineWidth,
                sizeMaxValue: CGFloat(Defaults.markerLineWidthMax),
                onColor: { [weak self] color in
                    self?.setCurrentMarkerColor(color)
                },
                onSize: { [weak self] size in
                    self?.setCurrentMarkerLineWidth(size)
                }
            )
        case .text:
            showTextSubToolbar()
        case .emoji:
            showEmojiSubToolbar()
        case .numbered:
            showColorSizeSubToolbar(
                sizes: [CGFloat(Defaults.numberSizeDefault)],
                dynamicColor: pickedColorSwatch,
                currentSize: currentNumberSize,
                sizeMinValue: CGFloat(Defaults.numberSizeMin),
                sizeMaxValue: CGFloat(Defaults.numberSizeMax),
                onSize: { [weak self] size in
                    self?.setCurrentNumberSize(size)
                }
            )
        case .mosaic:
            showMosaicSubToolbar()
        case .eraser:
            // The eraser has no sub-toolbar — drag over annotations to delete.
            break
        default:
            break
        }
    }

    private func showColorSizeSubToolbar(
        sizes: [CGFloat],
        currentColor: NSColor? = nil,
        dynamicColor: NSColor? = nil,
        currentSize: CGFloat,
        width: CGFloat? = nil,
        sizeMinValue: CGFloat = CGFloat(Defaults.editorLineWidthMin),
        sizeMaxValue: CGFloat = CGFloat(Defaults.editorLineWidthMax),
        onColor: ((NSColor) -> Void)? = nil,
        onSize: ((CGFloat) -> Void)? = nil,
        shapeFillMode: ShapeFillMode? = nil,
        onShapeFillMode: ((ShapeFillMode) -> Void)? = nil,
        shapeStrokeStyle: ShapeStrokeStyle? = nil,
        shapeStrokePreviewShape: ShapeStrokePreviewShape = .rectangle,
        onShapeStrokeStyle: ((ShapeStrokeStyle) -> Void)? = nil,
        arrowStyle: ArrowStyle? = nil,
        onArrowStyle: ((ArrowStyle) -> Void)? = nil
    ) {
        guard let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let resolvedWidth = width ?? ColorSizeSubToolbar.preferredWidth(
            sizes: sizes,
            dynamicColor: dynamicColor,
            showsShapeFillModes: shapeFillMode != nil,
            showsArrowStyles: arrowStyle != nil,
            showsShapeStrokeStyles: shapeStrokeStyle != nil,
            shapeStrokePreviewShape: shapeStrokePreviewShape
        )
        let subRect = subToolbarRect(
            width: resolvedWidth,
            height: 36,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )

        let resolvedColor = currentColor ?? self.currentColor
        let view = ColorSizeSubToolbar(
            frame: subRect,
            sizes: sizes,
            currentColor: resolvedColor,
            dynamicColor: dynamicColor,
            currentSize: currentSize,
            sizeMinValue: sizeMinValue,
            sizeMaxValue: sizeMaxValue,
            shapeFillMode: shapeFillMode,
            shapeStrokeStyle: shapeStrokeStyle,
            shapeStrokePreviewShape: shapeStrokePreviewShape,
            arrowStyle: arrowStyle
        )
        view.onColorChanged = { [weak self] color in
            if let onColor {
                onColor(color)
            } else {
                self?.setCurrentDrawingColor(color)
            }
            // Push the same color onto whatever annotation is currently
            // selected. With no selection this is a no-op, so the call is
            // safe to make from every tool's color path.
            self?.canvasView?.mutateSelectedAnnotationAtomic { $0.withColor(color) }
        }
        view.onSizeBegan = { [weak self] in
            self?.canvasView?.beginSelectionAdjustment()
        }
        view.onSizeChanged = { [weak self] size in
            onSize?(size)
            self?.canvasView?.mutateSelectedAnnotationLive { $0.withLineWidth(size) }
        }
        view.onSizeEnded = { [weak self] in
            self?.canvasView?.commitSelectionAdjustment()
        }
        view.onShapeFillModeChanged = onShapeFillMode
        view.onShapeStrokeStyleChanged = onShapeStrokeStyle
        view.onArrowStyleChanged = onArrowStyle
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
    }

    private func showTextSubToolbar() {
        guard let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let subRect = subToolbarRect(
            width: TextSubToolbar.preferredWidth(dynamicColor: pickedColorSwatch),
            height: 36,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )

        let view = TextSubToolbar(
            frame: subRect,
            currentColor: currentColor,
            currentFontSize: currentFontSize,
            currentFontName: currentFontName,
            dynamicColor: pickedColorSwatch,
            strokeEnabled: currentTextStroke,
            calloutEnabled: currentTextCallout
        )
        view.onColorChanged = { [weak self] color in
            self?.setCurrentDrawingColor(color)
            self?.canvasView?.mutateSelectedAnnotationAtomic { $0.withColor(color) }
        }
        view.onStrokeChanged = { [weak self] enabled in
            self?.currentTextStroke = enabled
            self?.canvasView?.currentTextStroke = enabled
            Defaults.lastTextStroke = enabled
            // Apply to the selected text annotation, if any. Other annotation
            // types carry no outline, so the transform leaves them untouched.
            self?.canvasView?.mutateSelectedAnnotationAtomic { annotation in
                (annotation as? TextAnnotation)?.withStroke(enabled) ?? annotation
            }
        }
        view.onCalloutChanged = { [weak self] enabled in
            self?.currentTextCallout = enabled
            self?.canvasView?.currentTextCallout = enabled
            Defaults.lastTextCallout = enabled
            self?.canvasView?.mutateSelectedAnnotationAtomic { annotation in
                (annotation as? TextAnnotation)?.withCallout(enabled) ?? annotation
            }
        }
        view.onFontSizeBegan = { [weak self] in
            self?.canvasView?.beginSelectionAdjustment()
        }
        view.onFontSizeChanged = { [weak self] size in
            self?.currentFontSize = size
            self?.canvasView?.currentFontSize = size
            Defaults.lastTextFontSize = Double(size)
            self?.canvasView?.mutateSelectedAnnotationLive { $0.withFontSize(size) }
        }
        view.onFontSizeEnded = { [weak self] in
            self?.canvasView?.commitSelectionAdjustment()
        }
        view.onFontNameChanged = { [weak self] fontName in
            self?.currentFontName = fontName
            self?.canvasView?.currentFontName = fontName
            Defaults.textFontName = fontName
            self?.canvasView?.mutateSelectedAnnotationAtomic { annotation in
                (annotation as? TextAnnotation)?.withFontName(fontName) ?? annotation
            }
        }
        view.onFontMenuClosed = { [weak self] in
            self?.bringEditorToFront()
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
    }

    private func showMosaicSubToolbar() {
        guard let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let subRect = subToolbarRect(
            width: MosaicSubToolbar.preferredWidth,
            height: 36,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )

        let view = MosaicSubToolbar(
            frame: subRect,
            style: currentMosaicStyle,
            blockSize: currentMosaicBlockSize,
            blurRadius: currentMosaicBlurRadius
        )
        view.onAdjustmentBegan = { [weak self] in
            self?.canvasView?.beginSelectionAdjustment()
        }
        view.onSettingsChanged = { [weak self] style, blockSize, blurRadius in
            guard let self else { return }
            self.currentMosaicStyle = style
            self.currentMosaicBlockSize = blockSize
            self.currentMosaicBlurRadius = blurRadius
            self.canvasView?.currentMosaicStyle = style
            self.canvasView?.currentMosaicBlockSize = blockSize
            self.canvasView?.currentMosaicBlurRadius = blurRadius
            Defaults.mosaicStyle = style
            Defaults.mosaicBlockSize = Double(blockSize)
            Defaults.mosaicBlurRadius = Double(blurRadius)
            self.canvasView?.mutateSelectedMosaicLive(
                style: style, blockSize: blockSize, blurRadius: blurRadius
            )
        }
        view.onAdjustmentEnded = { [weak self] in
            self?.canvasView?.commitSelectionAdjustment()
            self?.bringEditorToFront()
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
    }

    private func showEmojiSubToolbar() {
        guard let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let width = min(
            EmojiSubToolbar.preferredVisibleWidth,
            max(EmojiSubToolbar.minimumVisibleWidth, hostSelectionView.bounds.width - 16)
        )
        let subRect = subToolbarRect(
            width: width,
            height: 42,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )

        let view = EmojiSubToolbar(
            frame: subRect,
            emojis: Self.recentEmojiChoices(from: recentEmojis),
            selectedEmoji: currentEmoji
        )
        view.onEmojiSelected = { [weak self, weak view] emoji in
            self?.selectEmoji(emoji, subToolbar: view, promotesToRecent: false)
        }
        view.onMoreRequested = { [weak self, weak view] anchor in
            self?.showEmojiPicker(anchoredTo: anchor, subToolbar: view)
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
    }

    private func selectEmoji(_ emoji: String, subToolbar: EmojiSubToolbar?, promotesToRecent: Bool) {
        currentEmoji = emoji
        canvasView?.currentEmoji = emoji
        let visibleEmojis = Self.recentEmojiChoices(from: recentEmojis)
        if promotesToRecent, !visibleEmojis.contains(emoji) {
            promoteRecentEmoji(emoji)
            subToolbar?.emojis = Self.recentEmojiChoices(from: recentEmojis)
        }
        subToolbar?.selectedEmoji = emoji
        dismissEmojiPopover()
        bringEditorToFront()
    }

    private func showEmojiPicker(anchoredTo anchor: NSView, subToolbar: EmojiSubToolbar?) {
        dismissBeautifyPresetPopover()
        dismissEmojiPopover()

        let picker = EmojiPickerView(
            frame: NSRect(origin: .zero, size: EmojiPickerView.preferredSize),
            emojis: Self.emojiPickerChoices,
            selectedEmoji: currentEmoji
        )
        picker.onEmojiSelected = { [weak self, weak subToolbar] emoji in
            self?.selectEmoji(emoji, subToolbar: subToolbar, promotesToRecent: true)
        }

        let viewController = NSViewController()
        viewController.view = picker

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = EmojiPickerView.preferredSize
        popover.contentViewController = viewController
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        emojiPopover = popover
    }

    private func dismissEmojiPopover() {
        emojiPopover?.performClose(nil)
        emojiPopover = nil
    }

    private func dismissBeautifyPresetPopover() {
        beautifyPresetPopover?.performClose(nil)
        beautifyPresetPopover = nil
    }

    private func promoteRecentEmoji(_ emoji: String) {
        var next = [emoji]
        for existing in Self.recentEmojiChoices(from: recentEmojis) where existing != emoji {
            next.append(existing)
        }
        for fallback in Self.defaultRecentEmojiChoices where !next.contains(fallback) {
            next.append(fallback)
        }
        recentEmojis = Array(next.prefix(Self.recentEmojiLimit))
        Defaults.recentEmojis = recentEmojis
    }

    private func handleEmojiStamped() {
        currentEmoji = nil
        canvasView?.currentEmoji = nil
        (subToolbarView as? EmojiSubToolbar)?.selectedEmoji = nil
        dismissEmojiPopover()
        NSCursor.arrow.set()
    }

    private func updateSubToolbarPosition() {
        guard
            let hostSelectionView,
            let subToolbarView,
            let toolbarFrame = subToolbarAnchorFrame
        else { return }

        // When the beautify gradient picker is up, keep the tool's color/size
        // sub-toolbar shifted below it so the two rows don't overlap.
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        subToolbarView.frame = subToolbarRect(
            width: subToolbarView.frame.width,
            height: subToolbarView.frame.height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds,
            offset: offset
        )
    }

    /// Reposition the main toolbar, beautify gradient row, tool color/size
    /// row, and selection chrome overlay against the current `selectionViewRect`
    /// and beautify state. Called whenever the underlying geometry changes —
    /// beautify toggles, preset/projection changes, or the user resizes the
    /// selection.
    private func repositionFloatingChrome() {
        // Moving the slider while it tracks the pointer changes its local
        // mouse coordinates, feeding a new value back into the layout again.
        guard !isAdjustingBeautifyShadowSize else { return }
        guard let hostSelectionView else { return }
        if let toolbarView {
            toolbarView.frame = toolbarRect(
                in: hostSelectionView.bounds,
                size: toolbarView.preferredSize
            )
        }
        if let sideToolbarView {
            sideToolbarView.frame = sideToolbarRect(
                in: hostSelectionView.bounds,
                size: sideToolbarView.preferredSize,
                avoiding: toolbarView?.frame
            )
        }
        updateSubToolbarPosition()
        if isBeautifyActive,
           let toolbarFrame = subToolbarAnchorFrame,
           let beautifySub = beautifySubToolbarView {
            beautifySub.frame = subToolbarRect(
                width: beautifySub.frame.width,
                height: beautifySub.frame.height,
                toolbarFrame: toolbarFrame,
                in: hostSelectionView.bounds
            )
        }
        updateSelectionChromePresentation()
    }

    private func updateSelectionChromePresentation() {
        let isVisible = shouldShowSelectionChrome
        selectionChromeOverlay?.isHidden = !isVisible
        selectionChromeOverlay?.update(
            rect: selectionViewRect,
            active: isVisible
        )
    }

    // MARK: - Move-selection drag handle

    /// Original selection rect captured at the moment the user pressed the
    /// move-selection drag handle. Per-frame deltas are applied against
    /// this so the rect doesn't drift if a frame is missed.
    private var moveSelectionStartRect: NSRect?

    private func handleMoveSelectionStart() {
        canvasView?.commitActiveTextEditing()
        moveSelectionStartRect = hostSelectionView?.currentSelectionRect ?? .zero
    }

    private func handleMoveSelectionDrag(delta: CGSize) {
        guard let moveSelectionStartRect else { return }
        hostSelectionView?.moveByExternalDrag(
            deltaFromOriginal: delta,
            originalRect: moveSelectionStartRect
        )
    }

    private func handleMoveSelectionEnd() {
        guard moveSelectionStartRect != nil else { return }
        hostSelectionView?.finalizeExternalDrag()
        moveSelectionStartRect = nil
    }

    // MARK: - Image Rotation

    private func showRotationSubToolbar() {
        guard !isScrollCaptureBusy, !isCropping,
              let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else { return }
        if subToolbarView is RotationSubToolbar {
            showSubToolbar(for: activeTool)
            return
        }
        selectTool(.none)
        let view = RotationSubToolbar(frame: subToolbarRect(
            width: 92, height: 36, toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds, offset: isBeautifyActive ? 40 : 0
        ))
        view.onRotate = { [weak self] clockwise in self?.rotateImage(clockwise: clockwise) }
        styleFloatingHUD(view)
        subToolbarView = view
        hostSelectionView.addSubview(view)
        toolbars.forEach { $0.setActive(true, for: .rotate) }
    }

    private func rotateImage(clockwise: Bool) {
        guard !isScrollCaptureBusy, !isCropping, let canvasView else { return }
        canvasView.commitActiveTextEditing()
        dismissQRCodeOverlay()
        // A screen selection becomes a fixed image at the first rotation.
        // Never recapture the desktop underneath the rotated document.
        if overrideBaseImage == nil, !canvasView.hasPreviewImage {
            guard let image = canvasView.resolveBaseImageForEditing() else { return }
            overrideBaseImage = image
            overrideBaseImageCropRect = NSRect(origin: .zero, size: image.size)
            croppedOverrideBaseImage = image
            canvasView.overrideBaseImage = image
        }
        canvasView.rotateImage(clockwise: clockwise)
    }

    private func layoutRotatedImage() {
        guard let canvasView, let hostSelectionView, let hostWindow = hostSelectionView.window else { return }
        dismissQRCodeOverlay()
        let orientedSize = canvasView.imageRotation.orientedSize(canvasView.bounds.size)
        guard orientedSize.width > 0, orientedSize.height > 0 else { return }
        let visibleRect = NSRect(
            x: screen.visibleFrame.minX - screen.frame.minX,
            y: screen.visibleFrame.minY - screen.frame.minY,
            width: screen.visibleFrame.width, height: screen.visibleFrame.height
        )
        let scale = min(1, floor(visibleRect.width * 0.70) / orientedSize.width)
        canvasView.setPresentationScale(scale)
        let displaySize = canvasView.orientedDisplaySize
        let viewportSize = NSSize(
            width: displaySize.width,
            height: min(displaySize.height, max(1, visibleRect.height - 120))
        )
        let origin = NSPoint(
            x: max(visibleRect.minX, min(selectionViewRect.midX - viewportSize.width / 2, visibleRect.maxX - viewportSize.width)),
            y: max(visibleRect.minY, min(selectionViewRect.midY - viewportSize.height / 2, visibleRect.maxY - viewportSize.height))
        )
        selectionViewRect = NSRect(origin: origin, size: viewportSize)
        selectionRect = hostWindow.convertToScreen(hostSelectionView.convert(selectionViewRect, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRect = CGRect(x: selectionRect.minX, y: primaryHeight - selectionRect.maxY,
                             width: selectionRect.width, height: selectionRect.height)
        hostSelectionView.updateSelectionRect(selectionViewRect)
        hostSelectionView.selectionLocked = true
        if let source = overrideBaseImage, let crop = overrideBaseImageCropRect {
            let rotation = canvasView.imageRotation
            let orientedCrop = crop.applying(rotation.transform(for: source.size))
            let fullSize = rotation.orientedSize(source.size)
            let sourceScale = displaySize.width / orientedCrop.width
            hostSelectionView.selectionAdjustmentBounds = NSRect(
                x: origin.x - orientedCrop.minX * sourceScale,
                y: origin.y - orientedCrop.minY * sourceScale,
                width: fullSize.width * sourceScale,
                height: fullSize.height * sourceScale
            ).intersection(visibleRect)
        }
        if let image = canvasView.resolveBaseImageForEditing() {
            hostSelectionView.selectionSizeLabelOverride = Self.sizeLabelText(
                for: canvasView.imageRotation.orientedSize(image.size)
            )
        }
        beautifyContainerView?.canvasSizeDidChange()
        updateCanvasFrameForBeautify()
        updateEditorInteractionState()
        updateCaptureActionAvailability()
        repositionFloatingChrome()
    }

    // MARK: - Beautify

    private func toggleBeautify() {
        dismissQRCodeOverlay()
        if isBeautifyActive {
            deactivateBeautify()
        } else {
            activateBeautify()
        }
        // Session teardown and scroll capture can disable beautify temporarily
        // Only an explicit toggle changes the preference for the next editor
        Defaults.lastBeautifyEnabled = isBeautifyActive
    }

    private func activateBeautify() {
        guard let canvasView, let container = beautifyContainerView else {
            return
        }
        let preset = BeautifyPreset.defaultPreset

        // Beautify and annotation tools coexist — don't clear the active tool.

        // The canvas draws its content (previewImage or externalBaseImage)
        // inside the beautify card. Normal selections use a fixed card clip;
        // clicked-window captures use the window's own rounded alpha mask.
        canvasView.beautifyCornerRadius = isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius
        if canvasView.previewImage == nil, canvasView.externalBaseImage == nil {
            canvasView.externalBaseImage = windowShapedBaseImage(
                from: canvasView.resolveBaseImageForEditing()
            )
        }

        currentBeautifyPreset = preset
        if preset.isWallpaper {
            container.wallpaperImage = nil
            loadBeautifyWallpaper(presetID: preset.id)
        }
        container.setBeautify(preset: preset)
        container.setShadowSize(currentBeautifyShadowSize)
        isBeautifyActive = true
        toolbars.forEach { $0.setBeautifyActive(true) }
        showBeautifySubToolbar(selecting: preset)
        Defaults.lastBeautifyPresetID = preset.id

        updateCanvasFrameForBeautify()
        repositionFloatingChrome()
        updateEditorInteractionState()
        canvasView.needsDisplay = true
        bringEditorToFront()
    }

    private func deactivateBeautify() {
        guard let canvasView, let container = beautifyContainerView else {
            return
        }
        dismissBeautifyPresetPopover()
        finishBeautifyShadowSizeAdjustment(repositionChrome: false)
        currentBeautifyPreset = nil

        canvasView.beautifyCornerRadius = nil
        canvasView.externalBaseImage = nil

        container.setBeautify(preset: nil)
        isBeautifyActive = false
        toolbars.forEach { $0.setBeautifyActive(false) }
        beautifySubToolbarView?.removeFromSuperview()
        beautifySubToolbarView = nil

        updateCanvasFrameForBeautify()
        repositionFloatingChrome()
        updateEditorInteractionState()
        canvasView.needsDisplay = true
        bringEditorToFront()
    }

    private func applyBeautifyPreset(_ preset: BeautifyPreset) {
        guard let container = beautifyContainerView else {
            return
        }
        currentBeautifyPreset = preset

        if preset.isWallpaper {
            container.wallpaperImage = nil
            loadBeautifyWallpaper(presetID: preset.id)
        } else {
            container.wallpaperImage = nil
        }

        container.setBeautify(preset: preset)
        Defaults.lastBeautifyPresetID = preset.id
        beautifySubToolbarView?.currentPresetID = preset.id
        canvasView?.needsDisplay = true
        updateCanvasFrameForBeautify()
        repositionFloatingChrome()
    }

    private func applyBeautifyShadowSize(_ size: CGFloat) {
        let size = BeautifyRenderer.normalizedShadowSize(size)
        guard currentBeautifyShadowSize != size else { return }
        let scrollOrigin = canvasScrollView?.contentView.bounds.origin
        currentBeautifyShadowSize = size
        if !isAdjustingBeautifyShadowSize {
            Defaults.lastBeautifyShadowSize = Double(size)
        }
        beautifyContainerView?.setShadowSize(currentBeautifyShadowSize)
        updateCanvasFrameForBeautify(preservingScrollOrigin: scrollOrigin)
        repositionFloatingChrome()
    }

    private func finishBeautifyShadowSizeAdjustment(repositionChrome: Bool = true) {
        guard isAdjustingBeautifyShadowSize else { return }
        isAdjustingBeautifyShadowSize = false
        Defaults.lastBeautifyShadowSize = Double(currentBeautifyShadowSize)
        if repositionChrome {
            repositionFloatingChrome()
        }
    }

    private func loadBeautifyWallpaper(presetID: String) {
        BeautifyRenderer.loadWallpaperImage(for: screen) { [weak self] image in
            guard let self else { return }
            guard self.isBeautifyActive,
                  self.currentBeautifyPreset?.id == presetID,
                  self.currentBeautifyPreset?.isWallpaper == true else {
                return
            }
            self.beautifyContainerView?.wallpaperImage = image
            self.beautifyContainerView?.needsDisplay = true
            self.canvasView?.needsDisplay = true
        }
    }

    private func showBeautifySubToolbar(selecting preset: BeautifyPreset) {
        guard let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else {
            return
        }

        dismissBeautifyPresetPopover()
        finishBeautifyShadowSizeAdjustment(repositionChrome: false)
        beautifySubToolbarView?.removeFromSuperview()

        let toolbarPresets = BeautifyPreset.toolbarPresets(
            preferredIDs: beautifyToolbarPresetIDs
        )
        let width = BeautifySubToolbar.preferredWidth(presetCount: toolbarPresets.count)
        let height: CGFloat = 36
        let subRect = subToolbarRect(
            width: width,
            height: height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds
        )

        let view = BeautifySubToolbar(
            frame: subRect,
            presets: toolbarPresets,
            screen: screen,
            initialShadowSize: currentBeautifyShadowSize
        )
        view.currentPresetID = preset.id
        view.onPresetSelected = { [weak self] selected in
            self?.dismissBeautifyPresetPopover()
            self?.applyBeautifyPreset(selected)
        }
        view.onMoreRequested = { [weak self, weak view] anchor in
            self?.showBeautifyPresetPicker(anchoredTo: anchor, subToolbar: view)
        }
        view.onShadowSizeChanged = { [weak self] size in
            self?.applyBeautifyShadowSize(size)
        }
        view.onShadowSizeEditingBegan = { [weak self] in
            self?.isAdjustingBeautifyShadowSize = true
        }
        view.onShadowSizeEditingEnded = { [weak self] in
            self?.finishBeautifyShadowSizeAdjustment()
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        beautifySubToolbarView = view
    }

    private func showBeautifyPresetPicker(
        anchoredTo anchor: NSView,
        subToolbar: BeautifySubToolbar?
    ) {
        dismissEmojiPopover()
        dismissBeautifyPresetPopover()

        let toolbarPresets = subToolbar?.presets ?? BeautifyPreset.toolbarPresets(
            preferredIDs: beautifyToolbarPresetIDs
        )
        let pickerPresets = BeautifyPreset.pickerPresets(
            excluding: toolbarPresets
        )
        let pickerSize = BeautifyPresetPickerView.preferredSize(
            itemCount: pickerPresets.count
        )
        let picker = BeautifyPresetPickerView(
            frame: NSRect(origin: .zero, size: pickerSize),
            presets: pickerPresets,
            screen: screen,
            selectedPresetID: currentBeautifyPreset?.id
        )
        picker.onPresetSelected = { [weak self, weak subToolbar] preset in
            self?.promoteBeautifyPresetToToolbar(preset, subToolbar: subToolbar)
            self?.applyBeautifyPreset(preset)
            self?.dismissBeautifyPresetPopover()
        }

        let viewController = NSViewController()
        viewController.view = picker

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = pickerSize
        popover.contentViewController = viewController
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        beautifyPresetPopover = popover
    }

    private func promoteBeautifyPresetToToolbar(
        _ preset: BeautifyPreset,
        subToolbar: BeautifySubToolbar?
    ) {
        beautifyToolbarPresetIDs = BeautifyPreset.promotedToolbarPresetIDs(
            selecting: preset.id,
            currentIDs: beautifyToolbarPresetIDs
        )
        Defaults.beautifyToolbarPresetIDs = beautifyToolbarPresetIDs
        subToolbar?.updatePresets(
            BeautifyPreset.toolbarPresets(preferredIDs: beautifyToolbarPresetIDs)
        )
        subToolbar?.currentPresetID = preset.id
    }

    private func updateCanvasFrameForBeautify(preservingScrollOrigin scrollOrigin: NSPoint? = nil) {
        guard
            let canvasView,
            let canvasScrollView,
            let hostSelectionView,
            let container = beautifyContainerView
        else {
            return
        }

        let frame = isBeautifyActive
            ? outerVisualRect(in: hostSelectionView.bounds)
            : selectionViewRect
        if canvasScrollView.frame != frame {
            canvasScrollView.frame = frame
        }

        if let scrollOrigin {
            updateCanvasScrollAvailability()
            let clipView = canvasScrollView.contentView
            var bounds = clipView.bounds
            bounds.origin = scrollOrigin
            let origin = clipView.constrainBoundsRect(bounds).origin
            if clipView.bounds.origin != origin {
                clipView.scroll(to: origin)
                canvasScrollView.reflectScrolledClipView(clipView)
            }
        } else {
            resetCanvasScrollPosition()
        }
        container.needsDisplay = true
        canvasView.needsDisplay = true
    }

    private var isCanvasTallerThanViewport: Bool {
        guard let scrollView = canvasScrollView, let documentView = scrollView.documentView else {
            return false
        }
        return documentView.frame.height > scrollView.contentView.bounds.height + 0.5
    }

    private func updateCanvasScrollAvailability() {
        guard let scrollView = canvasScrollView, let documentView = scrollView.documentView else {
            return
        }
        let needsVerticalScroller = documentView.frame.height > scrollView.contentView.bounds.height + 0.5
        if scrollView.hasVerticalScroller != needsVerticalScroller {
            scrollView.hasVerticalScroller = needsVerticalScroller
        }
    }

    private func resetCanvasScrollPosition() {
        guard let scrollView = canvasScrollView else { return }
        updateCanvasScrollAvailability()
        if isCanvasTallerThanViewport {
            scrollView.scrollToTop()
        } else {
            scrollView.contentView.setBoundsOrigin(.zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// The on-screen rect of the canvas/scroll view. When beautify is on this
    /// is the outer (gradient + inner image) rect, anchored so the inner
    /// image stays exactly where the user drew the selection — the gradient
    /// is allowed to spill past the screen edges rather than shifting the
    /// inner image to fit. The `bounds` parameter is kept for call-site
    /// symmetry; it isn't read here.
    private func outerVisualRect(in bounds: NSRect) -> NSRect {
        _ = bounds
        guard isBeautifyActive, let container = beautifyContainerView else {
            return selectionViewRect
        }
        let outer = container.outerSize
        guard outer.width > 0, outer.height > 0 else {
            return selectionViewRect
        }
        let padding = container.contentPadding
        // Compare content with the stable selection viewport. The scroll view
        // still has its previous size while a new margin is being applied.
        if container.innerImageSize.height > selectionViewRect.height + 0.5 {
            return NSRect(
                x: selectionViewRect.minX - padding.left,
                y: selectionViewRect.minY - padding.bottom,
                width: selectionViewRect.width + padding.left + padding.right,
                height: selectionViewRect.height + padding.top + padding.bottom
            )
        }
        return NSRect(
            x: selectionViewRect.minX - padding.left,
            y: selectionViewRect.minY - padding.bottom,
            width: outer.width,
            height: outer.height
        )
    }

    // MARK: - Scroll Capture

    private func toggleScrollCapture() {
        // Scroll capture only makes sense for live screen content; in
        // image-edit mode or clicked-window captures there's nothing to scroll.
        guard isScrollCaptureAllowed else { return }
        guard !isScrollCaptureFinalizing else { return }
        if canvasView?.hasPreviewImage == true { return }
        if isScrollCapturing {
            stopScrollCapture()
        } else {
            showScrollCaptureModeMenu()
        }
    }

    private enum ScrollCaptureMode {
        case automatic
        case manual
    }

    private func showScrollCaptureModeMenu() {
        canvasView?.commitActiveTextEditing()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: L10n.scrollCaptureAutoScroll) { [weak self] in
            DispatchQueue.main.async {
                self?.startScrollCapture(mode: .automatic)
            }
        })
        menu.addItem(ClosureMenuItem(title: L10n.scrollCaptureManualScroll) { [weak self] in
            DispatchQueue.main.async {
                self?.startScrollCapture(mode: .manual)
            }
        })
        popUpToolbarMenu(menu, anchoredTo: .scrollCapture)
    }

    private func startScrollCapture(mode: ScrollCaptureMode) {
        guard isScrollCaptureAllowed else { return }
        guard !isScrollCaptureBusy else { return }
        guard canvasView?.hasPreviewImage != true else { return }

        if isBeautifyActive {
            deactivateBeautify()
        }

        if mode == .automatic {
            // Automatic scroll posts synthetic events; without Accessibility
            // access capcap cannot move the target page.
            guard AutoScroller.isPermitted else {
                ToastWindow.show(message: L10n.autoScrollPermissionNeeded, on: screen)
                return
            }
        }

        isScrollCapturing = true
        let sessionID = UUID()
        scrollCaptureSessionID = sessionID
        activeTool = .none
        canvasView?.activeTool = .none
        toolbars.forEach { $0.updateSelection(tool: .none) }
        dismissEmojiPopover()
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        toolbars.forEach { $0.setScrollCaptureActive(true) }
        hostSelectionView?.scrollCaptureActive = true
        updateEditorInteractionState()
        // Commit the cutout before taking any frames. Manual mode captures in
        // init; automatic mode waits for its target to be ready first.
        hostSelectionView?.display()
        CATransaction.flush()

        // Show the persistent hint inside the selection *before* the capturer
        // takes its first (synchronous) frame, then exclude its window from the
        // capture so it never bleeds into the stitched long screenshot.
        let hintText = mode == .automatic ? L10n.scrollCaptureHint : L10n.scrollCaptureManualHint
        let hintWindow = ScrollCaptureHintWindow(text: hintText)
        hintWindow.present(in: selectionRect)
        scrollCaptureHintWindow = hintWindow

        // Allocate both panels before the first capture so their window IDs
        // are excluded even when a wide selection puts the preview inside it.
        let previewWindow = ScrollPreviewWindow()
        scrollPreviewWindow = previewWindow
        showScrollCaptureControl()

        let capturer = ScrollCapturer(
            rect: captureRect,
            screen: screen,
            // Exclude the entire selection overlay, not just the hint. Its
            // dimming cutout can leave antialiased pixels at capture edges,
            // which become horizontal bands when frame bottoms are stitched.
            // This also protects the final asynchronous capture after the
            // selection view has returned to its ordinary drawing state.
            excludingWindowNumbers: Self.scrollCaptureExcludedWindowNumbers(
                selectionWindow: hostSelectionView?.window,
                hintWindow: hintWindow,
                previewWindow: previewWindow,
                controlWindow: scrollCaptureControlWindow
            ),
            onPreviewUpdated: { [weak self] image in
                guard let self, self.scrollCaptureSessionID == sessionID else { return }
                self.updateScrollPreview(image)
            },
            capturesInitialFrame: mode != .automatic
        )
        scrollCapturer = capturer
        installScrollCaptureKeyMonitor()
        toolbars.forEach { $0.isHidden = true }
        // The overlay stays click-through so scroll input reaches the page
        // underneath in both automatic and manual mode.
        hostSelectionView?.window?.ignoresMouseEvents = true
        NSApp.deactivate()
        switch mode {
        case .automatic:
            startAutoScroll(capturer: capturer)
        case .manual:
            startManualScrollCapture(capturer: capturer)
        }
    }

    static func scrollCaptureExcludedWindowNumbers(
        selectionWindow: NSWindow?,
        hintWindow: NSWindow,
        previewWindow: NSWindow? = nil,
        controlWindow: NSWindow? = nil
    ) -> [CGWindowID] {
        [selectionWindow, hintWindow, previewWindow, controlWindow].compactMap { window in
            guard let window, window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        }
    }

    static func scrollPreviewFrame(anchorRect: NSRect, screenFrame: NSRect) -> NSRect {
        let inset: CGFloat = 12
        let available = screenFrame.insetBy(dx: min(inset, screenFrame.width / 4), dy: min(inset, screenFrame.height / 4))
        let width = min(128, available.width)
        let height = min(408, available.height)
        let right = anchorRect.maxX + inset
        let left = anchorRect.minX - inset - width
        let preferredX: CGFloat
        if right + width <= available.maxX {
            preferredX = right
        } else if left >= available.minX {
            preferredX = left
        } else {
            preferredX = anchorRect.maxX - inset - width
        }
        return NSRect(
            x: min(max(preferredX, available.minX), available.maxX - width),
            y: min(max(anchorRect.maxY - height, available.minY), available.maxY - height),
            width: width,
            height: height
        )
    }

    /// Prepares the target window before sending scroll input. The pointer is
    /// moved into the content once and remains free to reach the stop button.
    private func startAutoScroll(capturer: ScrollCapturer) {
        // Start with substantial overlap. AutoScroller reduces the requested
        // distance after recovery; only verified image movement is appended.
        let stepPoints = max(1, min(180, selectionRect.height * 0.15))
        let center = CGPoint(x: captureRect.midX, y: captureRect.midY)
        let captureWindows: [NSWindow?] = [
            hostSelectionView?.window, scrollCaptureHintWindow,
            scrollPreviewWindow, scrollCaptureControlWindow
        ]
        let excludedWindowNumbers = captureWindows.compactMap { window -> CGWindowID? in
            guard let window, window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        }

        let scroller = AutoScroller(
            centerPoint: center,
            stepPixels: Int(stepPoints),
            captureRect: captureRect,
            excludingWindowNumbers: excludedWindowNumbers,
            onKeyPressed: { [weak self, weak capturer] in
                guard let self, let capturer, self.scrollCapturer === capturer,
                      self.isScrollCapturing else { return }
                self.stopScrollCapture()
            },
            onRecoveryChanged: { [weak self, weak capturer] isRecovering in
                guard let self, let capturer, self.scrollCapturer === capturer,
                      self.isScrollCapturing else { return }
                self.scrollCaptureHintWindow?.updateText(
                    isRecovering ? L10n.autoScrollRecovering : L10n.scrollCaptureHint,
                    in: self.selectionRect
                )
            }
        )
        autoScroller = scroller
        scroller.start(
            prepareCapture: { capturer.prepareInitialFrameSynchronously() },
            captureStep: { expectedShift in
                switch capturer.captureSynchronously(expectedShiftPoints: CGFloat(expectedShift)) {
                case .appended: return .progressed
                case .noNewContent: return .stalled
                case .retry: return .retry
                case .captureUnavailable: return .captureUnavailable
                case .captureFailed: return .captureFailed
                case .atCapacity: return .finished
                }
            },
            onFinished: { [weak self, weak capturer] reason in
                guard let self, let capturer, self.scrollCapturer === capturer,
                      self.isScrollCapturing else { return }
                switch reason {
                case .noProgress, .movementUnconfirmed, .targetUnavailable, .permissionDenied:
                    self.autoScroller?.stop()
                    self.autoScroller = nil
                    self.scrollCaptureHintWindow?.updateText(
                        (reason == .noProgress || reason == .movementUnconfirmed)
                            ? L10n.autoScrollNoProgress : L10n.autoScrollTargetUnavailable,
                        in: self.selectionRect
                    )
                    self.startManualScrollCapture(capturer: capturer)
                case .noNewContent, .capacity:
                    self.stopScrollCapture()
                case .alignmentFailed, .captureUnavailable:
                    self.stopScrollCapture(forceIncomplete: true)
                }
            }
        )
    }

    /// Samples the selected region while the user scrolls manually. Duplicate
    /// frames are ignored by `ScrollCapturer`, so steady polling gives the user
    /// a forgiving capture window without adding a second stitching path.
    private func startManualScrollCapture(capturer: ScrollCapturer) {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "capcap.manual-scroll-capture", qos: .userInitiated)
        )
        manualScrollCaptureTimer = timer
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15, leeway: .milliseconds(30))
        var retryStartedAt: TimeInterval?
        var waitingForOverlap = false
        var hasRestoredManualHint = false
        timer.setEventHandler { [weak self, weak capturer] in
            guard let capturer else { return }
            // Continuous manual input may never produce two identical frames.
            // Sample it directly and let overlap validation reject bad frames.
            let outcome = capturer.captureSynchronously(expectedShiftPoints: 0, waitsForSettledFrame: false)
            if case .atCapacity = outcome {
                DispatchQueue.main.async { [weak self, weak capturer] in
                    guard let self, let capturer, self.scrollCapturer === capturer,
                          self.isScrollCapturing else { return }
                    self.stopScrollCapture()
                }
                return
            }
            if case .captureFailed = outcome {
                DispatchQueue.main.async { [weak self, weak capturer] in
                    guard let self, let capturer, self.scrollCapturer === capturer,
                          self.isScrollCapturing else { return }
                    self.stopScrollCapture(forceIncomplete: true)
                }
                return
            }
            var needsOverlap = waitingForOverlap
            var restoreManualHint = false
            switch outcome {
            case .retry:
                let now = ProcessInfo.processInfo.systemUptime
                if retryStartedAt == nil { retryStartedAt = now }
                needsOverlap = now - (retryStartedAt ?? now) >= 2 || waitingForOverlap
            case .appended:
                retryStartedAt = nil
                needsOverlap = false
                restoreManualHint = !hasRestoredManualHint
                hasRestoredManualHint = true
            case .noNewContent:
                retryStartedAt = nil
            case .captureUnavailable:
                // A missing frame does not establish lost overlap. Keep the
                // session and anchor while the stream reports its next frame.
                retryStartedAt = nil
            case .atCapacity, .captureFailed:
                break
            }
            if needsOverlap != waitingForOverlap || restoreManualHint {
                waitingForOverlap = needsOverlap
                DispatchQueue.main.async { [weak self, weak capturer] in
                    guard let self, let capturer, self.scrollCapturer === capturer,
                          self.isScrollCapturing else { return }
                    self.scrollCaptureHintWindow?.updateText(
                        needsOverlap ? L10n.scrollCaptureNeedsOverlap : L10n.scrollCaptureManualHint,
                        in: self.selectionRect
                    )
                }
            }
        }
        timer.resume()
    }

    private func stopManualScrollCapture() {
        manualScrollCaptureTimer?.setEventHandler {}
        manualScrollCaptureTimer?.cancel()
        manualScrollCaptureTimer = nil
    }

    private func stopScrollCapture(forceIncomplete: Bool = false) {
        guard isScrollCapturing else { return }
        isScrollCapturing = false
        isScrollCaptureFinalizing = true
        autoScroller?.stop()
        autoScroller = nil
        stopManualScrollCapture()
        removeScrollCaptureKeyMonitor()
        let finishingCapturer = scrollCapturer
        finishingCapturer?.onPreviewUpdated = nil
        scrollCapturer = nil
        let sessionID = scrollCaptureSessionID
        scrollCaptureControlWindow?.showFinalizing()
        scrollCaptureHintWindow?.updateText(L10n.scrollCaptureFinalizing, in: selectionRect)
        // Keep the preview and live cutout visible while the last frame is
        // being composed. Restoring the old frozen screen here causes a flash.
        hostSelectionView?.window?.ignoresMouseEvents = false
        toolbars.forEach { $0.setScrollCaptureActive(false) }
        updateEditorInteractionState()
        updateCaptureActionAvailability()

        guard let finishingCapturer else {
            finishScrollCapture(stitchedImage: nil)
            return
        }
        finishingCapturer.stopAndStitch { [weak self] result in
            guard let self, self.scrollCaptureSessionID == sessionID else { return }
            self.finishScrollCapture(stitchedImage: result.image, isIncomplete: result.isIncomplete || forceIncomplete)
        }
    }

    private func finishScrollCapture(stitchedImage: NSImage?, isIncomplete: Bool = false) {
        guard isScrollCaptureFinalizing else { return }
        isScrollCaptureFinalizing = false
        scrollCaptureSessionID = nil

        hostSelectionView?.scrollCaptureActive = false
        hostSelectionView?.needsDisplay = true
        scrollCaptureControlWindow?.dismiss()
        scrollCaptureControlWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        scrollCaptureHintWindow?.dismiss()
        scrollCaptureHintWindow = nil
        toolbars.forEach { $0.isHidden = false }
        updateEditorInteractionState()
        updateCaptureActionAvailability()
        bringEditorToFront()
        if let stitchedImage {
            enterCropMode(with: stitchedImage)
            updateEditorInteractionState()
        }
        if isIncomplete {
            ToastWindow.show(message: L10n.scrollCaptureIncomplete, on: screen)
        }
    }

    // MARK: - Crop Mode

    /// Shows the stitched long screenshot scaled to fit, with a top/bottom
    /// crop overlay. The editor stays hidden underneath until confirmed.
    private func enterCropMode(with image: NSImage) {
        guard let hostSelectionView else {
            // Defensive: no host view means the editor was already torn down.
            finishCropFallback(with: image)
            return
        }

        isCropping = true
        activeTool = .none
        canvasView?.activeTool = .none
        toolbars.forEach { $0.updateSelection(tool: .none) }
        toolbars.forEach { $0.isHidden = true }
        selectionChromeOverlay?.isHidden = true

        let cropView = ScrollCropView(frame: hostSelectionView.bounds, image: image)
        cropView.autoresizingMask = [.width, .height]
        hostSelectionView.addSubview(cropView)
        scrollCropView = cropView

        showCropControl()
        bringEditorToFront()
        ToastWindow.show(message: L10n.cropLongScreenshotHint, on: screen)
    }

    /// Skips crop mode and drops the image straight into the editor — only
    /// used when there is no host view to host the crop overlay.
    private func finishCropFallback(with image: NSImage) {
        loadScrollCaptureImageIntoEditor(image)
        toolbars.forEach { $0.isHidden = false }
        bringEditorToFront()
    }

    private func confirmCrop() {
        guard isCropping, let cropView = scrollCropView else {
            exitCropMode()
            return
        }

        let cropped = cropView.croppedImage()
        exitCropMode()
        loadScrollCaptureImageIntoEditor(cropped)
        ToastWindow.show(message: L10n.mergedLongScreenshot, on: screen)
    }

    private func loadScrollCaptureImageIntoEditor(_ image: NSImage) {
        canvasView?.loadPreviewImage(image)
        hostSelectionView?.selectionSizeLabelOverride = Self.sizeLabelText(for: image.size)
        beautifyContainerView?.canvasSizeDidChange()
        updateCanvasScrollAvailability()
        canvasScrollView?.scrollToTop()
        updateEditorInteractionState()
        updateCaptureActionAvailability()
    }

    private static func sizeLabelText(for size: NSSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        return "\(Int(size.width.rounded())) x \(Int(size.height.rounded()))"
    }

    private func exitCropMode() {
        isCropping = false
        scrollCropView?.removeFromSuperview()
        scrollCropView = nil
        scrollCropControlWindow?.dismiss()
        scrollCropControlWindow = nil
        selectionChromeOverlay?.isHidden = false
        toolbars.forEach { $0.isHidden = false }
        bringEditorToFront()
    }

    private func showCropControl() {
        let controlWindow = ScrollCropControlWindow(
            onConfirm: { [weak self] in self?.confirmCrop() }
        )
        controlWindow.positionAtBottom(of: screen)
        scrollCropControlWindow = controlWindow
        controlWindow.orderFrontRegardless()
    }

    private func save() {
        guard !deferUntilWindowCaptureReady(.save) else { return }
        canvasView?.commitActiveTextEditing()
        guard let finalImage = currentCompositeImage() else { return }
        let quality = Defaults.screenshotSaveQuality

        if Defaults.askSaveLocation {
            let suggestedName = FilenameTemplate.imageFileName(
                for: finalImage,
                fileExtension: quality.fileExtension,
                consumeCounters: false
            )
            promptForScreenshotSaveLocation(suggestedName: suggestedName) { [weak self] chosen in
                guard let self else { return }
                guard let chosen else {
                    self.bringEditorToFront()
                    return
                }
                self.finishSave(image: finalImage, destinationOverride: chosen)
            }
            return
        }

        finishSave(image: finalImage, destinationOverride: nil)
    }

    /// Encode and write the screenshot. When `destinationOverride` is set (user
    /// picked a path in the save panel), write there; otherwise create a unique
    /// file under the configured screenshot directory.
    private func finishSave(image finalImage: NSImage, destinationOverride: URL?) {
        let targetScreen = screen
        let focusReturn = onRequestFocusReturn
        let quality = Defaults.screenshotSaveQuality

        tearDown()
        onComplete(nil)

        if quality.usesLossyCompression {
            ToastWindow.show(message: L10n.screenshotQualityCompressingSave, on: targetScreen, duration: 600)
        }

        ImageOutputEncoder.encodeAsync(image: finalImage, quality: quality) { result in
            if quality.usesLossyCompression {
                ToastWindow.dismiss()
            }

            var shouldReturnFocus = true
            switch result {
            case .failure:
                ToastWindow.show(message: L10n.screenshotCompressionFailed, on: targetScreen, duration: 3.0)
            case .success(let output):
                do {
                    let destination: URL
                    if let destinationOverride {
                        destination = destinationOverride
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                    } else {
                        let filename = FilenameTemplate.imageFileName(
                            for: finalImage,
                            fileExtension: output.fileExtension,
                            imageSize: output.pixelSize
                        )
                        destination = try SaveDestination.uniqueFile(
                            in: Defaults.screenshotSaveDirectory,
                            fileName: filename
                        )
                    }
                    try output.data.write(to: destination, options: .atomic)
                    let directoryPath = SaveDestination.displayPath(destination.deletingLastPathComponent())
                    ToastWindow.show(message: L10n.screenshotSaved(to: directoryPath), on: targetScreen)
                    if Defaults.autoRevealSavedFiles {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                        shouldReturnFocus = false
                    }
                } catch {
                    ToastWindow.show(
                        message: L10n.screenshotSaveFailed(error.localizedDescription),
                        on: targetScreen,
                        duration: 3.5
                    )
                }
            }

            if shouldReturnFocus {
                focusReturn?()
            }
        }
    }

    /// Save panel for screenshots. Presented as a sheet on the overlay when
    /// possible so it appears above the capture chrome. Cancel keeps the editor open.
    private func promptForScreenshotSaveLocation(
        suggestedName: String,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = Defaults.screenshotSaveDirectory
        panel.nameFieldStringValue = suggestedName

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            completion(url)
        }

        NSApp.activate(ignoringOtherApps: true)
        if let hostWindow = hostSelectionView?.window {
            panel.beginSheetModal(for: hostWindow, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    private func upload() {
        guard !deferUntilWindowCaptureReady(.upload) else { return }
        canvasView?.commitActiveTextEditing()
        guard let finalImage = currentCompositeImage() else { return }
        let targetScreen = screen
        tearDown()
        onComplete(nil)
        UploadManager.shared.upload(image: finalImage, on: targetScreen)
    }

    /// Text-recognition action: exits the selection/editor, then opens the OCR
    /// panel anchored to the original selection. Uses the raw capture (no
    /// annotations) so recognition is not polluted by drawn marks.
    private func performOCR() {
        guard !deferUntilWindowCaptureReady(.ocr) else { return }
        canvasView?.commitActiveTextEditing()
        let baseImage = orientedBaseImageForOutput() ?? currentCompositeImage()
        let anchorRect = selectionRect
        let targetScreen = screen
        tearDown()
        onComplete(nil)
        guard let baseImage else { return }
        OCRTranslatePanel.presentTextRecognition(image: baseImage, anchorRect: anchorRect, screen: targetScreen)
    }

    private func performQRCodeRecognition() {
        guard !deferUntilWindowCaptureReady(.qrCode) else { return }
        canvasView?.commitActiveTextEditing()
        dismissQRCodeOverlay()
        clearActiveToolForQRCodeRecognition()

        guard
            let canvasView,
            let hostSelectionView,
            let image = canvasView.resolveBaseImageForEditing() ?? currentCompositeImage(),
            let cgImage = image.cgImagePreservingBacking()
        else {
            ToastWindow.show(message: L10n.qrCodeNotFound, on: screen)
            return
        }

        qrCodeDetectionGeneration += 1
        let generation = qrCodeDetectionGeneration
        toolbars.forEach { $0.setActive(true, for: .qrCode) }

        DispatchQueue.global(qos: .userInitiated).async {
            let detections = QRCodeDetector.detect(in: cgImage)
            DispatchQueue.main.async { [weak self, weak canvasView, weak hostSelectionView] in
                guard let self,
                      let canvasView,
                      let hostSelectionView,
                      generation == self.qrCodeDetectionGeneration
                else { return }
                self.handleQRCodeDetections(
                    detections,
                    canvasView: canvasView,
                    hostSelectionView: hostSelectionView
                )
            }
        }
    }

    private func clearActiveToolForQRCodeRecognition() {
        activeTool = .none
        canvasView?.activeTool = .none
        canvasView?.clearMultiSelection()
        toolbars.forEach { $0.updateSelection(tool: .none) }
        dismissEmojiPopover()
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        updateEditorInteractionState()
        bringEditorToFront()
    }

    private func handleQRCodeDetections(
        _ detections: [QRCodeDetection],
        canvasView: EditCanvasView,
        hostSelectionView: SelectionView
    ) {
        guard !detections.isEmpty else {
            dismissQRCodeOverlay()
            ToastWindow.show(message: L10n.qrCodeNotFound, on: screen)
            return
        }

        guard detections.count > 1 else {
            copyQRCodePayload(detections[0].payload)
            return
        }

        let choices = detections.map { detection in
            let canvasRect = canvasRect(
                fromNormalizedBoundingBox: detection.normalizedBoundingBox,
                in: canvasView.bounds
            )
            return QRCodeChoice(
                payload: detection.payload,
                anchorRect: canvasView.convert(canvasRect, to: hostSelectionView)
            )
        }

        let overlay = QRCodeChoiceOverlayView(
            frame: hostSelectionView.bounds,
            choices: choices
        ) { [weak self] choice in
            self?.copyQRCodePayload(choice.payload)
        }
        qrCodeOverlayView?.removeFromSuperview()
        qrCodeOverlayView = overlay
        hostSelectionView.addSubview(overlay)
        toolbars.forEach { $0.setActive(true, for: .qrCode) }
        bringEditorToFront()
    }

    private func copyQRCodePayload(_ payload: String) {
        let targetScreen = screen
        ClipboardManager.copyToClipboard(text: payload)
        tearDown()
        onComplete(nil)
        ToastWindow.show(message: L10n.qrCodeCopied, on: targetScreen)
        requestFocusReturn()
    }

    private func dismissQRCodeOverlay() {
        qrCodeDetectionGeneration += 1
        qrCodeOverlayView?.removeFromSuperview()
        qrCodeOverlayView = nil
        toolbars.forEach { $0.setActive(false, for: .qrCode) }
    }

    private func canvasRect(fromNormalizedBoundingBox box: CGRect, in bounds: NSRect) -> NSRect {
        let standardized = box.standardized
        let minX = max(0, min(1, standardized.minX))
        let minY = max(0, min(1, standardized.minY))
        let maxX = max(0, min(1, standardized.maxX))
        let maxY = max(0, min(1, standardized.maxY))
        return NSRect(
            x: bounds.minX + minX * bounds.width,
            y: bounds.minY + minY * bounds.height,
            width: max(0, maxX - minX) * bounds.width,
            height: max(0, maxY - minY) * bounds.height
        )
    }

    /// Screenshot-translation action: uses OCR internally, but only shows the
    /// translated result to the user.
    private func performScreenshotTranslation() {
        guard !deferUntilWindowCaptureReady(.screenshotTranslate) else { return }
        canvasView?.commitActiveTextEditing()
        let baseImage = orientedBaseImageForOutput() ?? currentCompositeImage()
        let anchorRect = selectionRect
        let targetScreen = screen
        tearDown()
        onComplete(nil)
        guard let baseImage else { return }
        OCRTranslatePanel.presentScreenshotTranslation(image: baseImage, anchorRect: anchorRect, screen: targetScreen)
    }

    private func pin() {
        guard !deferUntilWindowCaptureReady(.pin) else { return }
        canvasView?.commitActiveTextEditing()
        guard let finalImage = currentCompositeImage() else { return }

        PinLauncher.pin(image: finalImage, at: selectionRect.origin)

        tearDown()
        onComplete(nil) // Don't copy to clipboard for pin
    }

    private func record() {
        guard let onRecordingSelection else { return }
        canvasView?.commitActiveTextEditing()
        let rect = selectionRect
        let targetScreen = screen
        tearDown()
        onComplete(nil)
        onRecordingSelection(rect, targetScreen)
    }

    private func close() {
        tearDown()
        onComplete(nil)
        requestFocusReturn()
    }

    private func toolUsesPickedColorSwatch(_ tool: EditTool) -> Bool {
        switch tool {
        case .rectangle, .ellipse, .line, .arrow, .pen, .marker, .numbered, .text:
            return true
        default:
            return false
        }
    }

    private func setShapeFillMode(_ mode: ShapeFillMode) {
        currentShapeFillMode = mode
        canvasView?.currentShapeFillMode = mode
        Defaults.lastShapeFillMode = mode
        canvasView?.mutateSelectedAnnotationAtomic { $0.withShapeFillMode(mode) }
    }

    private func setShapeStrokeStyle(_ style: ShapeStrokeStyle) {
        currentShapeStrokeStyle = style
        canvasView?.currentShapeStrokeStyle = style
        Defaults.lastShapeStrokeStyle = style
        canvasView?.mutateSelectedAnnotationAtomic { $0.withShapeStrokeStyle(style) }
    }

    private func setCurrentDrawingColor(_ color: NSColor) {
        currentColor = color
        canvasView?.currentColor = color
        if let hex = Self.hex(from: color) {
            Defaults.lastEditorColorHex = hex
        }
    }

    private func setCurrentDrawingLineWidth(_ size: CGFloat) {
        currentLineWidth = size
        canvasView?.currentLineWidth = size
        Defaults.lastEditorLineWidth = Double(size)
    }

    private func setCurrentNumberSize(_ size: CGFloat) {
        let clamped = min(max(size, CGFloat(Defaults.numberSizeMin)), CGFloat(Defaults.numberSizeMax))
        currentNumberSize = clamped
        canvasView?.currentNumberSize = clamped
        Defaults.lastNumberSize = Double(clamped)
    }

    private func setCurrentMarkerColor(_ color: NSColor) {
        currentMarkerColor = color
        canvasView?.currentMarkerColor = color
        if let hex = Self.hex(from: color) {
            Defaults.lastMarkerColorHex = hex
        }
    }

    private func setCurrentMarkerLineWidth(_ size: CGFloat) {
        let clamped = min(max(size, CGFloat(Defaults.editorLineWidthMin)), CGFloat(Defaults.markerLineWidthMax))
        currentMarkerLineWidth = clamped
        canvasView?.currentMarkerLineWidth = clamped
        Defaults.lastMarkerLineWidth = Double(clamped)
    }

    private func setArrowStyle(_ style: ArrowStyle) {
        currentArrowStyle = style
        canvasView?.currentArrowStyle = style
        Defaults.lastArrowStyle = style
        canvasView?.mutateSelectedAnnotationAtomic { annotation in
            guard let arrow = annotation as? ArrowAnnotation else { return annotation }
            return arrow.withStyle(style)
        }
    }

    private static func color(fromHex hex: String?) -> NSColor? {
        guard var trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    private static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else {
            return nil
        }
        let r = Int(round(max(0, min(1, rgb.redComponent)) * 255))
        let g = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Trigger the system color sampler (loupe). The picked color's hex is
    /// copied to the clipboard and the color becomes the toolbar ink-bottle
    /// color for color-capable tools. It does not directly change the active
    /// tool color.
    private func runColorPicker() {
        canvasView?.commitActiveTextEditing()
        ColorPickerRunner.shared.run(on: screen) { [weak self] swatchColor, _ in
            guard let self else { return }
            self.pickedColorSwatch = swatchColor
            if self.toolUsesPickedColorSwatch(self.activeTool) {
                self.showSubToolbar(for: self.activeTool)
            }
        }
    }

    private func showInsertImageMenu() {
        canvasView?.commitActiveTextEditing()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: L10n.insertImageFromClipboard) { [weak self] in
            self?.insertImageFromClipboard()
        })
        menu.addItem(ClosureMenuItem(title: L10n.insertImageFromFile) { [weak self] in
            self?.insertImageFromFile()
        })
        popUpToolbarMenu(menu, anchoredTo: .insertImage)
    }

    private func insertImageFromClipboard() {
        guard let image = ClipboardImageSource.currentImage() else {
            ToastWindow.show(message: L10n.insertImageNoClipboardImage, on: screen)
            bringEditorToFront()
            return
        }
        insertImage(image)
    }

    private func insertImageFromFile() {
        canvasView?.commitActiveTextEditing()
        let panel = NSOpenPanel()
        panel.title = L10n.insertImageChooseFile
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard
                response == .OK,
                let url = panel.url,
                let image = Self.loadImageForInsertion(from: url)
            else {
                self?.bringEditorToFront()
                return
            }
            self?.insertImage(image)
        }

        if let hostWindow = hostSelectionView?.window {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func insertImage(_ image: NSImage) {
        selectTool(.none)
        _ = canvasView?.insertImage(image)
        bringEditorToFront()
    }

    private func popUpToolbarMenu(_ menu: NSMenu, anchoredTo itemID: ToolbarItemID) {
        guard let hostSelectionView else { return }
        let anchor = toolbarItemFrameInHost(for: itemID) ?? NSRect(
            x: hostSelectionView.bounds.midX,
            y: hostSelectionView.bounds.midY,
            width: 1,
            height: 1
        )
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: anchor.minX, y: anchor.maxY + 4),
            in: hostSelectionView
        )
        bringEditorToFront()
    }

    private func toolbarItemFrameInHost(for itemID: ToolbarItemID) -> NSRect? {
        guard let hostSelectionView else { return nil }
        for toolbar in toolbars {
            if let frame = toolbar.frame(for: itemID) {
                return toolbar.convert(frame, to: hostSelectionView)
            }
        }
        return nil
    }

    private static func loadImageForInsertion(from url: URL) -> NSImage? {
        if let data = try? Data(contentsOf: url),
           let rep = NSBitmapImageRep(data: data) {
            let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
            rep.size = pixelSize
            let image = NSImage(size: pixelSize)
            image.addRepresentation(rep)
            return image
        }
        return NSImage(contentsOf: url)
    }

    private static let recentEmojiLimit = 10

    private static let defaultRecentEmojiChoices = [
        "⭐️", "❤️", "👍", "👎", "🚀",
        "😀", "😂", "😍", "🔥", "✅",
    ]

    private static let emojiPickerChoices = [
        "😀", "😄", "😂", "🤣", "😍", "🤔", "😎", "🤯", "😱",
        "😤", "🥳", "🤡", "💩", "👻", "🤖", "👽", "😈",
        "🙈", "🙉", "🙊", "💪", "👏", "🙌", "🤝", "🫡",
        "⭐️", "❤️", "👍", "👎", "🚀", "✅", "❌", "⚠️", "❓",
        "🔥", "✨", "🎉", "💡", "📌", "🚩", "☝️",
    ]

    private static func recentEmojiChoices(from stored: [String]) -> [String] {
        var result: [String] = []
        for emoji in stored + defaultRecentEmojiChoices {
            guard !emoji.isEmpty, !result.contains(emoji) else { continue }
            result.append(emoji)
            if result.count == recentEmojiLimit { break }
        }
        return result
    }

    private func cancelActiveColorSampler() {
        ColorPickerRunner.shared.cancel()
    }

    func confirmFromKeyboard() {
        guard !isWaitingForWindowCaptureOutput else { return }
        // Finishing capture enters crop mode; copying is a separate action.
        if isScrollCaptureFinalizing {
            return
        }
        if isScrollCapturing {
            stopScrollCapture()
            return
        }
        if isCropping {
            confirmCrop()
            return
        }
        confirm()
    }

    @discardableResult
    func pinFromKeyboard() -> Bool {
        guard !isWaitingForWindowCaptureOutput else { return true }
        guard !isScrollCaptureBusy, !isCropping else { return false }
        pin()
        return true
    }

    /// Called by the overlay's local mouse monitor before AppKit dispatches a
    /// left click. This lets the editor preserve the selection's established
    /// double-click-to-copy gesture even while the annotation canvas owns the
    /// event.
    func handleCanvasConfirmDoubleClick(_ event: NSEvent) -> Bool {
        guard let canvasView, let hostSelectionView else { return false }

        guard !isScrollCaptureBusy,
              !isCropping,
              event.modifierFlags.intersection([.command, .shift]).isEmpty,
              hostSelectionView.selectionLocked,
              hostSelectionView.selectionInteractionEnabled,
              event.window === hostSelectionView.window
        else {
            canvasView.discardPotentialConfirmDoubleClick()
            return false
        }

        let canvasPoint = canvasView.convert(event.locationInWindow, from: nil)
        guard canvasView.visibleRect.contains(canvasPoint) else {
            canvasView.discardPotentialConfirmDoubleClick()
            return false
        }

        if event.clickCount >= 2 {
            return canvasView.handlePotentialConfirmDoubleClick(
                clickCount: event.clickCount,
                at: canvasPoint
            )
        }

        guard event.clickCount == 1 else {
            canvasView.discardPotentialConfirmDoubleClick()
            return false
        }

        let hostPoint = hostSelectionView.convert(event.locationInWindow, from: nil)
        let hitView = hostSelectionView.hitTest(hostPoint)
        let isEditorSurface = hitView === hostSelectionView
            || hitView === canvasView
            || hitView?.isDescendant(of: canvasView) == true
        guard isEditorSurface else {
            canvasView.discardPotentialConfirmDoubleClick()
            return false
        }

        return canvasView.handlePotentialConfirmDoubleClick(
            clickCount: event.clickCount,
            at: canvasPoint
        )
    }

    /// Save-to-file (⌘S) entry point — mirrors `confirmFromKeyboard`'s phased
    /// behavior so the hotkey works regardless of which stage the editor is in.
    func saveFromKeyboard() {
        guard !isWaitingForWindowCaptureOutput else { return }
        if isScrollCaptureFinalizing {
            return
        }
        if isScrollCapturing {
            stopScrollCapture()
            return
        }
        if isCropping {
            confirmCrop()
            return
        }
        save()
    }

    func handleScrollCaptureKeyDown(_ event: NSEvent) -> Bool {
        if isScrollCaptureFinalizing { return true }
        if isScrollCapturing {
            stopScrollCapture()
            return true
        }
        guard isCropping else { return false }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }

        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirmCrop()
            return true
        default:
            return false
        }
    }

    func undoFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCaptureBusy, !isCropping else { return false }
        return canvasView?.undoFromKeyboard(for: event) ?? false
    }

    func redoFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCaptureBusy, !isCropping else { return false }
        return canvasView?.redoFromKeyboard(for: event) ?? false
    }

    func handleAnnotationClipboardShortcutFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCaptureBusy, !isCropping else { return false }
        return canvasView?.handleAnnotationClipboardShortcutFromKeyboard(for: event) ?? false
    }

    func nudgeSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCaptureBusy, !isCropping else { return false }
        return canvasView?.nudgeSelectedAnnotationFromKeyboard(for: event) ?? false
    }

    func deleteSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCaptureBusy, !isCropping else { return false }
        return canvasView?.deleteSelectedAnnotationFromKeyboard(for: event) ?? false
    }

    func handleEditorShortcutFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCaptureBusy, !isCropping else { return false }
        guard let shortcut = EditorShortcutRegistry.action(matching: event) else { return false }

        switch shortcut {
        case .select:
            selectTool(.none)
        case .shapeFill:
            return toggleShapeFillFromKeyboard()
        case .toolbar(let item):
            // Holding a tool key selects it once rather than repeatedly
            // toggling it as macOS generates key-repeat events.
            if event.isARepeat, item.editTool != nil { return true }
            return performToolbarItem(item, togglesSelectedTool: true)
        }
        return true
    }

    private func toggleShapeFillFromKeyboard() -> Bool {
        guard activeTool == .rectangle || activeTool == .ellipse else { return false }
        let nextMode: ShapeFillMode
        switch currentShapeFillMode {
        case .none:
            nextMode = .opaque
        case .opaque:
            nextMode = .translucent
        case .translucent:
            nextMode = .none
        }
        setShapeFillMode(nextMode)
        showSubToolbar(for: activeTool)
        return true
    }

    private func confirm() {
        guard !deferUntilWindowCaptureReady(.confirm) else { return }
        canvasView?.commitActiveTextEditing()
        guard let finalImage = currentCompositeImage() else {
            tearDown()
            onComplete(nil)
            requestFocusReturn()
            return
        }
        tearDown()
        onComplete(finalImage)
        requestFocusReturn()
    }

    private func requestFocusReturn() {
        onRequestFocusReturn?()
    }

    func tearDown() {
        finishBeautifyShadowSizeAdjustment(repositionChrome: false)
        detachWindowCapturePreparation()
        pendingWindowCaptureAction = nil
        if let alert = windowCaptureWaitAlert {
            windowCaptureWaitAlert = nil
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel)
        }
        moveSelectionStartRect = nil
        dismissQRCodeOverlay()
        cancelActiveColorSampler()
        isScrollCapturing = false
        isScrollCaptureFinalizing = false
        scrollCaptureSessionID = nil
        autoScroller?.stop()
        autoScroller = nil
        stopManualScrollCapture()
        removeScrollCaptureKeyMonitor()
        scrollCapturer?.onPreviewUpdated = nil
        scrollCapturer = nil
        isCropping = false
        scrollCropView?.removeFromSuperview()
        scrollCropView = nil
        scrollCropControlWindow?.dismiss()
        scrollCropControlWindow = nil
        scrollCaptureControlWindow?.dismiss()
        scrollCaptureControlWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        scrollCaptureHintWindow?.dismiss()
        scrollCaptureHintWindow = nil
        hostSelectionView?.window?.ignoresMouseEvents = false
        canvasScrollView?.removeFromSuperview()
        canvasScrollView = nil
        canvasView?.discardPotentialConfirmDoubleClick()
        canvasView = nil
        selectionChromeOverlay?.removeFromSuperview()
        selectionChromeOverlay = nil
        hostSelectionView?.annotationToolActive = false
        hostSelectionView?.selectionInteractionEnabled = true
        hostSelectionView?.scrollCaptureActive = false
        toolbars.forEach { $0.isHidden = false; $0.removeFromSuperview() }
        toolbarView = nil
        sideToolbarView = nil
        dismissEmojiPopover()
        dismissBeautifyPresetPopover()
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        beautifySubToolbarView?.removeFromSuperview()
        beautifySubToolbarView = nil
        isBeautifyActive = false
    }

    private func bringEditorToFront() {
        guard let hostWindow = hostSelectionView?.window else { return }
        if keepsHostWindowAcrossSpaces {
            hostWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            hostWindow.collectionBehavior = []
        }
        NSApp.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        if activeTool == .none, canvasView?.hasPreviewImage != true {
            hostWindow.makeFirstResponder(hostSelectionView)
        } else {
            hostWindow.makeFirstResponder(canvasView)
        }
    }

    func restorableState() -> RestorableState? {
        guard let canvasView else { return nil }
        return RestorableState(
            canvasState: canvasView.restorableState(),
            beautifyState: BeautifyState(
                isActive: isBeautifyActive,
                presetID: currentBeautifyPreset?.id,
                shadowSize: currentBeautifyShadowSize
            ),
            overrideBaseImageCropRect: overrideBaseImageCropRect,
            overrideBaseImage: overrideBaseImage,
            selectionRect: selectionRect,
            selectionViewRect: selectionViewRect,
            captureRect: captureRect,
            selectionAdjustmentBounds: hostSelectionView?.selectionAdjustmentBounds,
            windowCapturePreparation: windowCapturePreparation
        )
    }

    func restoreState(_ state: RestorableState) {
        overrideBaseImage = state.overrideBaseImage
        overrideBaseImageCropRect = state.overrideBaseImageCropRect
        croppedOverrideBaseImage = state.overrideBaseImage
        canvasView?.overrideBaseImage = state.overrideBaseImage
        selectionRect = state.selectionRect
        selectionViewRect = state.selectionViewRect
        captureRect = state.captureRect
        hostSelectionView?.updateSelectionRect(selectionViewRect)
        hostSelectionView?.selectionAdjustmentBounds = state.selectionAdjustmentBounds
        if let overrideBaseImage,
           let cropRect = state.overrideBaseImageCropRect {
            overrideBaseImageCropRect = cropRect
            croppedOverrideBaseImage = FixedImageCropRenderer.crop(
                overrideBaseImage,
                to: cropRect
            ) ?? overrideBaseImage
            canvasView?.overrideBaseImage = effectiveOverrideBaseImage
            let canvasSize = canvasContentSize(for: selectionViewRect.size)
            canvasView?.updateViewportSize(canvasSize)
            beautifyContainerView?.canvasSizeDidChange()
        }
        if state.beautifyState.isActive {
            applyBeautifyState(state.beautifyState)
        } else if isBeautifyActive {
            deactivateBeautify()
        }
        canvasView?.restoreState(state.canvasState)
        canvasView?.captureRect = captureRect
        if let image = canvasView?.resolveBaseImageForEditing(), let rotation = canvasView?.imageRotation {
            hostSelectionView?.selectionSizeLabelOverride = Self.sizeLabelText(for: rotation.orientedSize(image.size))
        }
        beautifyContainerView?.canvasSizeDidChange()
        updateCanvasFrameForBeautify()
        repositionFloatingChrome()
        updateCanvasScrollAvailability()
        updateEditorInteractionState()
        updateHistoryButtons(canUndo: canvasView?.canUndo == true, canRedo: canvasView?.canRedo == true)
        attachWindowCapturePreparation(state.windowCapturePreparation)
    }

    private func applyBeautifyState(_ state: BeautifyState) {
        guard let canvasView, let container = beautifyContainerView else { return }
        let preset = BeautifyPreset.preset(forID: state.presetID) ?? .defaultPreset

        canvasView.beautifyCornerRadius = isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius
        if canvasView.previewImage == nil, canvasView.externalBaseImage == nil {
            canvasView.externalBaseImage = windowShapedBaseImage(
                from: canvasView.resolveBaseImageForEditing()
            )
        }

        currentBeautifyPreset = preset
        currentBeautifyShadowSize = state.shadowSize
        if preset.isWallpaper {
            container.wallpaperImage = nil
            loadBeautifyWallpaper(presetID: preset.id)
        }
        container.setBeautify(preset: preset)
        container.setShadowSize(state.shadowSize)
        isBeautifyActive = true
        toolbars.forEach { $0.setBeautifyActive(true) }
        showBeautifySubToolbar(selecting: preset)
    }

    private func currentCompositeImage() -> NSImage? {
        var fallbackBaseImage: NSImage?
        if canvasView?.hasPreviewImage == true {
            fallbackBaseImage = nil
        } else if let effectiveOverrideBaseImage {
            fallbackBaseImage = effectiveOverrideBaseImage
        } else if isWindowCapture, let windowBaseImage {
            fallbackBaseImage = windowBaseImage
        } else if let snapshot = preSnapshot {
            fallbackBaseImage = ScreenCapturer.crop(from: snapshot, captureRect: captureRect, screen: screen)
        } else {
            fallbackBaseImage = ScreenCapturer.capture(rect: captureRect, screen: screen)
        }

        if canvasView?.hasPreviewImage != true {
            fallbackBaseImage = windowShapedBaseImage(from: fallbackBaseImage)
        }

        let annotationClipMask = isWindowCapture && canvasView?.hasPreviewImage != true
            ? fallbackBaseImage
            : nil

        guard let composite = canvasView?.compositeImage(
            fallbackBaseImage: fallbackBaseImage,
            beautifyPreset: currentBeautifyPreset,
            beautifyShadowSize: currentBeautifyShadowSize,
            wallpaperImage: isBeautifyActive ? beautifyContainerView?.wallpaperImage : nil,
            annotationClipMask: annotationClipMask,
            beautifyInnerClipRadius: isBeautifyActive && isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius
        ) else { return nil }

        // Window captures get rounded corners — and, when enabled, a
        // macOS-style drop shadow — mimicking the system's native window
        // screenshots. Skipped while beautify is active (beautify supplies its
        // own card styling) and for scroll-capture stitched results.
        guard isWindowCapture, !isBeautifyActive, canvasView?.hasPreviewImage != true else {
            return composite
        }

        let rounded = windowBaseImage == nil ? WindowEffects.roundedCorners(composite) : composite
        guard Defaults.windowShadowEnabled else { return rounded }
        return WindowEffects.withShadow(rounded, size: CGFloat(Defaults.windowShadowSize))
    }

    private func orientedBaseImageForOutput() -> NSImage? {
        guard let canvasView, let image = canvasView.resolveBaseImageForEditing() else { return nil }
        return canvasView.imageRotation.render(image)
    }

    private func windowShapedBaseImage(from image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        guard isWindowCapture, canvasView?.hasPreviewImage != true else { return image }
        return windowBaseImage ?? WindowEffects.roundedCorners(image)
    }

    /// While scroll capture runs capcap is deactivated, so a local key monitor
    /// would not fire. In automatic mode the event tap in `AutoScroller` is
    /// the primary path; this global monitor also covers manual mode.
    private func installScrollCaptureKeyMonitor() {
        removeScrollCaptureKeyMonitor()
        scrollCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self, self.isScrollCapturing else { return }
            self.stopScrollCapture()
        }
    }

    private func removeScrollCaptureKeyMonitor() {
        if let scrollCaptureKeyMonitor {
            NSEvent.removeMonitor(scrollCaptureKeyMonitor)
            self.scrollCaptureKeyMonitor = nil
        }
    }

    private func updateScrollPreview(_ image: NSImage) {
        guard isScrollCapturing else { return }
        if scrollPreviewWindow == nil {
            scrollPreviewWindow = ScrollPreviewWindow()
        }
        scrollPreviewWindow?.updatePreview(image, anchorRect: selectionRect, screen: screen)
    }

    private func showScrollCaptureControl() {
        guard
            let hostSelectionView,
            let hostWindow = hostSelectionView.window,
            let scrollToolbar = toolbars.first(where: { $0.contains(.scrollCapture) }),
            let buttonFrame = scrollToolbar.scrollCaptureButtonFrame
        else {
            return
        }

        let frameInSelectionView = scrollToolbar.convert(buttonFrame, to: hostSelectionView)
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
        let hasFixedImage = overrideBaseImage != nil
        let isBlocked = isScrollCaptureBusy || isCropping
        // Once the editor is up, the canvas owns clicks inside the selection
        // rect for the entire session — drawing tools, adjust-mode handles,
        // and dragging existing annotations all go through it. The legacy
        // "click inside the selection moves the whole rect" gesture has
        // moved to a dedicated toolbar handle so adjust-mode clicks on
        // empty canvas don't get hijacked.
        // When beautify is on, handle hits go through `selectionChromeOverlay`
        // (which sits above the canvas); the SelectionView itself stays
        // available for any clicks that fall outside the gradient frame so the
        // user can still adjust the selection.
        hostSelectionView?.annotationToolActive = !isBlocked
        hostSelectionView?.selectionInteractionEnabled = !(isBlocked || hasPreview)
        canvasScrollView?.isInteractionEnabled = !isBlocked && ((activeTool != .none) || hasPreview || hasFixedImage || isBeautifyActive)
        updateSelectionChromePresentation()
        hostSelectionView?.needsDisplay = true
    }

    private func toolbarRect(in bounds: NSRect, size: NSSize) -> NSRect {
        EditorToolbarPlacement.primaryToolbarRect(
            referenceRect: outerVisualRect(in: bounds),
            in: bounds,
            size: size,
            topSafeInset: screen.safeAreaInsets.top
        )
    }

    /// Frame for the vertical side toolbar. Prefers the right of the
    /// selection, flips to the left when there's no room, and aligns its
    /// bottom edge with the selection.
    ///
    /// `avoiding` is the primary toolbar's frame, when it exists. The two
    /// bars are positioned independently against their own preferred
    /// anchors, so for a small selection near a screen edge the side
    /// toolbar can dip into the horizontal bar's row. When that happens we
    /// slide the side toolbar clear of the primary toolbar's band.
    private func sideToolbarRect(
        in bounds: NSRect,
        size: NSSize,
        avoiding primaryFrame: NSRect? = nil
    ) -> NSRect {
        EditorToolbarPlacement.sideToolbarRect(
            referenceRect: outerVisualRect(in: bounds),
            in: bounds,
            size: size,
            avoiding: primaryFrame
        )
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

let accentGreen = NSColor(red: 0, green: 212.0/255.0, blue: 106.0/255.0, alpha: 1.0)

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: keyEquivalent)
        target = self
        action = #selector(run)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}

final class EditorScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func scrollWheel(with event: NSEvent) {
        // Screen-backed annotations must stay aligned with the frozen desktop.
        // Only a taller, self-contained image (such as a scroll capture) pans.
        guard let canvas = editorCanvasView,
              canvas.hasPreviewImage || canvas.overrideBaseImage != nil,
              let documentView,
              documentView.frame.height > contentView.bounds.height + 0.5 else { return }
        super.scrollWheel(with: event)
    }

    weak var editorCanvasView: EditCanvasView?
    /// When `true`, every viewport click is captured (drawing tools, long
    /// screenshot preview, beautify chrome). When `false` the scroll view
    /// only forwards clicks claimed by the canvas (including empty space
    /// for marquee selection), leaving the surrounding viewport available
    /// to SelectionView and its resize handles.
    var isInteractionEnabled = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if isInteractionEnabled {
            return result
        }
        guard let canvas = editorCanvasView, let hit = result else { return nil }
        if hit === canvas || hit.isDescendant(of: canvas) {
            return hit
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func scrollToTop() {
        guard let documentView else { return }
        let topOffset = max(0, documentView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: topOffset))
        reflectScrolledClipView(contentView)
    }
}

/// A row (horizontal) or column (vertical) of editor buttons built from a
/// `[ToolbarItemID]`. Both the primary toolbar and the side toolbar are
/// instances of this class — only `orientation` and the item list differ.
class ToolbarView: NSView {
    enum Orientation { case horizontal, vertical }

    /// Button run geometry. `preferredSize` derives the capsule size from
    /// these so the dark background always wraps the buttons exactly.
    static let buttonSize: CGFloat = 40
    static let symbolPointSize: CGFloat = 18
    static let buttonSpacing: CGFloat = 6
    /// Inset along the main axis at both ends of the run.
    static let endPadding: CGFloat = 15
    /// Inset on the cross axis — keeps a 52pt-thick capsule around 40pt buttons.
    static let crossPadding: CGFloat = 6

    let orientation: Orientation
    private let items: [ToolbarItemID]

    /// Size that fits the current items in the current orientation.
    var preferredSize: NSSize {
        let n = items.count
        let run = CGFloat(n) * Self.buttonSize
            + CGFloat(max(0, n - 1)) * Self.buttonSpacing
            + Self.endPadding * 2
        let thickness = Self.buttonSize + Self.crossPadding * 2
        switch orientation {
        case .horizontal: return NSSize(width: max(run, thickness), height: thickness)
        case .vertical:   return NSSize(width: thickness, height: max(run, thickness))
        }
    }

    var onItemTriggered: ((ToolbarItemID) -> Void)?
    /// Press-and-drag callbacks for the "move selection" handle. The first
    /// fires on mouseDown so the controller can capture the starting rect;
    /// the second fires on every drag with the cumulative window-space
    /// delta from the press; the third fires on mouseUp.
    var onMoveSelectionStart: (() -> Void)?
    var onMoveSelectionDrag: ((CGSize) -> Void)?
    var onMoveSelectionEnd: (() -> Void)?

    /// Every button keyed by its id — drives selection state, enable/disable,
    /// and frame lookups. `MoveSelectionDragHandle` values are not `ToolButton`s.
    private var buttons: [ToolbarItemID: NSView] = [:]
    init(items: [ToolbarItemID], orientation: Orientation) {
        self.items = items
        self.orientation = orientation
        super.init(frame: NSRect(origin: .zero, size: .zero))
        setFrameSize(preferredSize)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateSelection(tool: EditTool) {
        for (id, view) in buttons {
            guard id.kind == .toggleTool, let btn = view as? ToolButton else { continue }
            btn.isSelected = (id.editTool == tool)
        }
    }

    /// Sets the active highlight on a stateful button (scroll capture,
    /// beautify). No-op if this toolbar doesn't hold the item.
    func setActive(_ active: Bool, for id: ToolbarItemID) {
        (buttons[id] as? ToolButton)?.isSelected = active
    }

    /// Enables/disables a button and dims it when disabled.
    func setEnabled(_ enabled: Bool, for id: ToolbarItemID) {
        guard let btn = buttons[id] as? ToolButton else { return }
        btn.isEnabled = enabled
        btn.alphaValue = enabled ? 1.0 : 0.35
    }

    /// `true` if this toolbar holds the given item.
    func contains(_ id: ToolbarItemID) -> Bool { buttons[id] != nil }

    /// Frame of an item's button in this toolbar's coordinate space.
    func frame(for id: ToolbarItemID) -> NSRect? { buttons[id]?.frame }

    // Convenience wrappers so callers don't repeat the id literals.
    func setScrollCaptureActive(_ active: Bool) { setActive(active, for: .scrollCapture) }
    func setScrollCaptureEnabled(_ enabled: Bool) { setEnabled(enabled, for: .scrollCapture) }
    func setBeautifyActive(_ active: Bool) { setActive(active, for: .beautify) }
    func setUndoEnabled(_ enabled: Bool) { setEnabled(enabled, for: .undo) }
    func setRedoEnabled(_ enabled: Bool) { setEnabled(enabled, for: .redo) }
    func setRecordingEnabled(_ enabled: Bool) {
        setEnabled(enabled, for: .record)
    }
    var scrollCaptureButtonFrame: NSRect? { frame(for: .scrollCapture) }

    private func setupButtons() {
        let size = Self.buttonSize
        let step = size + Self.buttonSpacing
        for (index, id) in items.enumerated() {
            let along = Self.endPadding + CGFloat(index) * step
            let frame: NSRect
            switch orientation {
            case .horizontal:
                frame = NSRect(x: along, y: Self.crossPadding, width: size, height: size)
            case .vertical:
                // AppKit y grows upward, so the first item sits at the top.
                let y = bounds.height - Self.endPadding - size - CGFloat(index) * step
                frame = NSRect(x: Self.crossPadding, y: y, width: size, height: size)
            }
            let view = makeButton(for: id, index: index, frame: frame)
            buttons[id] = view
            addSubview(view)
        }
    }

    private func makeButton(for id: ToolbarItemID, index: Int, frame: NSRect) -> NSView {
        // The move-selection handle is a press-drag gesture, not a tap target.
        if id.kind == .dragHandle {
            let handle = MoveSelectionDragHandle(frame: frame)
            handle.hoverTip = id.tooltip
            handle.onDragStart = { [weak self] in self?.onMoveSelectionStart?() }
            handle.onDrag = { [weak self] delta in self?.onMoveSelectionDrag?(delta) }
            handle.onDragEnd = { [weak self] in self?.onMoveSelectionEnd?() }
            return handle
        }

        let btn = ToolButton(
            frame: frame,
            symbolName: id.symbolName,
            normalColor: id.normalColor,
            selectedColor: id.selectedColor,
            symbolPointSize: Self.symbolPointSize,
            iconImage: id.iconImage(pointSize: Self.symbolPointSize)
        )
        btn.hoverTip = id.tooltip
        btn.setAccessibilityLabel(id.tooltip)
        btn.setAccessibilityIdentifier("capcap.toolbar.\(id.rawValue)")
        btn.target = self
        btn.action = #selector(buttonTapped(_:))
        btn.tag = index
        // Upload is unavailable until an upload provider is configured.
        if id == .upload {
            let hasProvider = Defaults.hasUsableUploadProvider
            btn.isEnabled = hasProvider
            btn.alphaValue = hasProvider ? 1.0 : 0.35
        }
        return btn
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }

    @objc private func buttonTapped(_ sender: ToolButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        let id = items[sender.tag]
        guard id != .moveSelection else { return }
        onItemTriggered?(id)
    }
}

// MARK: - Tool Button

class ToolButton: NSButton {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    /// Text shown by the dark hover tooltip. nil = no tip.
    var hoverTip: String?

    private let normalColor: NSColor
    private let selectedColor: NSColor
    private var hoverTrackingArea: NSTrackingArea?

    init(frame: NSRect, symbolName: String, normalColor: NSColor, selectedColor: NSColor, symbolPointSize: CGFloat = 14, iconImage: NSImage? = nil) {
        self.normalColor = normalColor
        self.selectedColor = selectedColor
        super.init(frame: frame)

        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)

        if let iconImage {
            image = iconImage
        } else if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
            // Keep the text tool's Aa glyph independent of the system language.
            let localizedImage = symbolName == "textformat" ? img.withLocale(Locale(identifier: "en")) : img
            image = localizedImage.withSymbolConfiguration(config)
        }

        contentTintColor = normalColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let tip = hoverTip, let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        ToolTipWindow.show(text: tip, anchor: frameOnScreen)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        ToolTipWindow.hide()
    }

    override func mouseDown(with event: NSEvent) {
        ToolTipWindow.hide()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolTipWindow.hide() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            contentTintColor = selectedColor
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            AdaptiveChrome.selectedFill.setFill()
            bgPath.fill()
        } else {
            contentTintColor = normalColor
        }
        // NSButtonCell lays out SF Symbols using their text alignment rect,
        // which excludes some ascenders/descenders. Its rendering can clip
        // those parts on a different backing scale. Draw the full symbol in
        // points and let NSImage rasterize for the current graphics context.
        guard let image else { return }
        let color = isSelected ? selectedColor : normalColor
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        let imageRect = NSRect(
            x: bounds.midX - image.size.width / 2,
            y: bounds.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        tinted.draw(in: imageRect, from: .zero, operation: .sourceOver,
                    fraction: !isEnabled ? 0.5 : (isHighlighted ? 0.65 : 1),
                    respectFlipped: true, hints: nil)
    }
}

// MARK: - Move-selection Drag Handle

/// Toolbar button that lets the user drag the entire selection rect by
/// pressing-and-holding it. Visually mirrors `ToolButton` so it sits in the
/// row consistently, but it acts as a drag handle rather than a tap target
/// — `mouseDown` starts a drag, `mouseDragged` reports cumulative deltas in
/// window coordinates, and `mouseUp` finalizes.
final class MoveSelectionDragHandle: NSView {
    var onDragStart: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnd: (() -> Void)?
    var hoverTip: String?

    private var pressStartLocation: NSPoint?
    private var isPressed: Bool = false {
        didSet { needsDisplay = true }
    }
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: NSCursor.openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let tip = hoverTip, let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        ToolTipWindow.show(text: tip, anchor: frameOnScreen)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        ToolTipWindow.hide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolTipWindow.hide() }
    }

    override func mouseDown(with event: NSEvent) {
        ToolTipWindow.hide()
        pressStartLocation = event.locationInWindow
        isPressed = true
        NSCursor.closedHand.set()
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStartLocation else { return }
        let delta = CGSize(
            width: event.locationInWindow.x - start.x,
            height: event.locationInWindow.y - start.y
        )
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        pressStartLocation = nil
        isPressed = false
        NSCursor.openHand.set()
        onDragEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            AdaptiveChrome.selectedFill.setFill()
            bg.fill()
        }

        let symbolName = "arrow.up.and.down.and.arrow.left.and.right"
        let config = NSImage.SymbolConfiguration(pointSize: ToolbarView.symbolPointSize, weight: .medium)
        guard let img = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Move selection"
        )?.withSymbolConfiguration(config) else { return }

        let tint = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        let drawRect = NSRect(
            x: bounds.midX - tint.size.width / 2,
            y: bounds.midY - tint.size.height / 2,
            width: tint.size.width,
            height: tint.size.height
        )
        tint.draw(in: drawRect)
    }
}

/// Persistent "press any key to finish" hint shown centered near the top of
/// the selection during auto-scroll. It is its own window so it can be
/// excluded from the ScreenCaptureKit capture — otherwise it would be baked
/// into every stitched frame of the long screenshot.
private final class ScrollCaptureHintWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 8
    /// Gap between the selection's top edge and the hint pill.
    private let topInset: CGFloat = 12

    init(text: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
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

        let container = AdaptiveChromeSurfaceView(style: .floating, cornerRadius: 8)

        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        container.addSubview(label)
        contentView = container
    }

    /// Size to the text and place top-center inside `selectionRect`
    /// (AppKit screen coordinates).
    func updateText(_ text: String, in selectionRect: NSRect) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        present(in: selectionRect)
    }

    func present(in selectionRect: NSRect) {
        label.sizeToFit()
        let textSize = label.frame.size
        let width = textSize.width + horizontalPadding * 2
        let height = textSize.height + verticalPadding * 2

        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label.setFrameOrigin(NSPoint(x: horizontalPadding, y: verticalPadding))

        let origin = NSPoint(
            x: selectionRect.midX - width / 2,
            y: selectionRect.maxY - topInset - height
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
        contentView = nil
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

    func showFinalizing() {
        guard let contentView else { return }
        contentView.subviews.forEach { $0.isHidden = true }
        let spinner = NSProgressIndicator(frame: NSRect(
            x: (contentView.bounds.width - 20) / 2,
            y: (contentView.bounds.height - 20) / 2, width: 20, height: 20
        ))
        spinner.style = .spinning
        spinner.setAccessibilityLabel(L10n.scrollCaptureFinalizing)
        contentView.addSubview(spinner)
        spinner.startAnimation(nil)
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
            normalColor: .labelColor,
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
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }
}

private final class RotationSubToolbar: NSView {
    var onRotate: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for clockwise in [false, true] {
            let button = ToolButton(
                frame: NSRect(x: clockwise ? 54 : 10, y: 4, width: 28, height: 28),
                symbolName: clockwise ? "rotate.right" : "rotate.left",
                normalColor: .labelColor, selectedColor: accentGreen
            )
            button.hoverTip = clockwise ? L10n.tipRotateRight : L10n.tipRotateLeft
            button.setAccessibilityLabel(button.hoverTip)
            button.target = self
            button.action = clockwise ? #selector(rotateRight) : #selector(rotateLeft)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }

    @objc private func rotateLeft() { onRotate?(false) }
    @objc private func rotateRight() { onRotate?(true) }
}

// MARK: - Crop Mode Control Window

/// Floating confirm button shown during crop mode. Stays on screen
/// regardless of how far the user scrolls the long screenshot.
private final class ScrollCropControlWindow: NSPanel {
    private static let windowSize = NSSize(width: 56, height: 44)

    init(onConfirm: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
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

        contentView = ScrollCropControlView(
            frame: NSRect(origin: .zero, size: Self.windowSize),
            onConfirm: onConfirm
        )
    }

    func positionAtBottom(of screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 36
        ))
    }

    func dismiss() {
        orderOut(nil)
        contentView = nil
    }
}

private final class ScrollCropControlView: NSView {
    private let onConfirm: () -> Void

    init(frame: NSRect, onConfirm: @escaping () -> Void) {
        self.onConfirm = onConfirm
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
            symbolName: "checkmark",
            normalColor: accentGreen,
            selectedColor: accentGreen
        )
        button.hoverTip = L10n.tipScrollCropConfirm
        button.target = self
        button.action = #selector(confirmTapped)
        addSubview(button)
    }

    @objc private func confirmTapped() {
        onConfirm()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        AdaptiveChrome.toolbarBackground.setFill()
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
        let container = AdaptiveChromeSurfaceView(
            style: .floating,
            cornerRadius: 8,
            borderWidth: 0.5
        )
        container.frame = containerRect
        container.autoresizingMask = [.width, .height]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.frame = containerRect.insetBy(dx: contentInset, dy: contentInset)
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        contentView = container
    }

    func updatePreview(_ image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        imageView.image = image
        setFrame(EditWindowController.scrollPreviewFrame(
            anchorRect: anchorRect,
            screenFrame: screen.visibleFrame
        ), display: true)

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

// MARK: - Emoji Sub-toolbar

private final class EmojiSubToolbar: NSView {
    static let preferredVisibleWidth: CGFloat = horizontalPad * 2
        + moreButtonSize
        + moreButtonGap
        + CGFloat(visibleEmojiCount) * itemSize
        + CGFloat(visibleEmojiCount - 1) * itemGap
    static let minimumVisibleWidth: CGFloat = preferredVisibleWidth

    var emojis: [String] {
        didSet { rebuildEmojiViews() }
    }
    var selectedEmoji: String? {
        didSet { updateSelection() }
    }
    var onEmojiSelected: ((String) -> Void)?
    var onMoreRequested: ((NSView) -> Void)?

    private let moreButton = MoreOptionsButton(
        frame: .zero,
        toolTip: L10n.tipMoreEmoji
    )
    private var emojiViews: [EmojiChoiceView] = []

    private static let visibleEmojiCount = 10
    private static let itemSize: CGFloat = 30
    private static let itemGap: CGFloat = 4
    private static let horizontalPad: CGFloat = 8
    private static let moreButtonSize: CGFloat = 30
    private static let moreButtonGap: CGFloat = 8

    init(frame: NSRect, emojis: [String], selectedEmoji: String?) {
        self.emojis = emojis
        self.selectedEmoji = selectedEmoji
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        moreButton.target = self
        moreButton.action = #selector(showMoreEmojiPicker)
        addSubview(moreButton)

        rebuildEmojiViews()
    }

    override func layout() {
        super.layout()

        let centerY = bounds.midY
        var x = Self.horizontalPad
        for view in emojiViews {
            view.frame = NSRect(
                x: x,
                y: centerY - Self.itemSize / 2,
                width: Self.itemSize,
                height: Self.itemSize
            )
            x += Self.itemSize + Self.itemGap
        }

        moreButton.frame = NSRect(
            x: bounds.maxX - Self.horizontalPad - Self.moreButtonSize,
            y: centerY - Self.moreButtonSize / 2,
            width: Self.moreButtonSize,
            height: Self.moreButtonSize
        )
    }

    private func rebuildEmojiViews() {
        for view in emojiViews {
            view.removeFromSuperview()
        }
        emojiViews.removeAll()

        for emoji in emojis.prefix(Self.visibleEmojiCount) {
            let item = EmojiChoiceView(
                frame: .zero,
                emoji: emoji,
                isSelected: emoji == selectedEmoji,
                fontSize: 19
            )
            item.onSelect = { [weak self] emoji in
                self?.onEmojiSelected?(emoji)
            }
            addSubview(item)
            emojiViews.append(item)
        }

        needsLayout = true
    }

    private func updateSelection() {
        for view in emojiViews {
            view.isSelected = view.emoji == selectedEmoji
        }
    }

    @objc private func showMoreEmojiPicker() {
        onMoreRequested?(moreButton)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }
}

private final class EmojiPickerView: NSView {
    static let preferredSize = NSSize(width: 520, height: 226)

    var selectedEmoji: String? {
        didSet { updateSelection() }
    }
    var onEmojiSelected: ((String) -> Void)?

    private let emojis: [String]
    private var choiceViews: [EmojiChoiceView] = []

    private static let gridColumns = 8
    private static let gridItemSize: CGFloat = 32
    private static let gridColumnGap: CGFloat = 25
    private static let gridRowGap: CGFloat = 8
    private static let topPad: CGFloat = 16
    private static let maxGridItems = 40

    init(frame: NSRect, emojis: [String], selectedEmoji: String?) {
        self.emojis = emojis
        self.selectedEmoji = selectedEmoji
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        wantsLayer = true

        let gridWidth = CGFloat(Self.gridColumns) * Self.gridItemSize
            + CGFloat(Self.gridColumns - 1) * Self.gridColumnGap
        let gridLeft = (bounds.width - gridWidth) / 2
        let gridTopY = bounds.maxY - Self.topPad - Self.gridItemSize

        for (index, emoji) in emojis.prefix(Self.maxGridItems).enumerated() {
            let row = index / Self.gridColumns
            let column = index % Self.gridColumns
            addChoice(
                emoji: emoji,
                frame: NSRect(
                    x: gridLeft + CGFloat(column) * (Self.gridItemSize + Self.gridColumnGap),
                    y: gridTopY - CGFloat(row) * (Self.gridItemSize + Self.gridRowGap),
                    width: Self.gridItemSize,
                    height: Self.gridItemSize
                ),
                fontSize: 23
            )
        }
    }

    private func addChoice(emoji: String, frame: NSRect, fontSize: CGFloat) {
        let item = EmojiChoiceView(
            frame: frame,
            emoji: emoji,
            isSelected: emoji == selectedEmoji,
            fontSize: fontSize
        )
        item.onSelect = { [weak self] emoji in
            self?.onEmojiSelected?(emoji)
        }
        addSubview(item)
        choiceViews.append(item)
    }

    private func updateSelection() {
        for view in choiceViews {
            view.isSelected = view.emoji == selectedEmoji
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        AdaptiveChrome.popoverBackground.setFill()
        path.fill()

        AdaptiveChrome.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class EmojiChoiceView: NSView {
    let emoji: String
    var onSelect: ((String) -> Void)?
    var isSelected: Bool {
        didSet { needsDisplay = true }
    }
    private let fontSize: CGFloat
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, emoji: String, isSelected: Bool, fontSize: CGFloat) {
        self.emoji = emoji
        self.isSelected = isSelected
        self.fontSize = fontSize
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(emoji)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHovering {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            (isSelected ? AdaptiveChrome.selectedFill : AdaptiveChrome.subtleFill).setFill()
            bg.fill()
            if isSelected {
                accentGreen.setStroke()
                bg.lineWidth = 1.4
                bg.stroke()
            }
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]
        let size = (emoji as NSString).size(withAttributes: attributes)
        let point = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        (emoji as NSString).draw(at: point, withAttributes: attributes)
    }
}

private final class MoreOptionsButton: NSButton {
    var isActive = false {
        didSet { needsDisplay = true }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(frame frameRect: NSRect, toolTip: String) {
        super.init(frame: frameRect)
        configure(toolTip: toolTip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(toolTip: String) {
        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        self.toolTip = toolTip
        setAccessibilityLabel(toolTip)
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        (cell as? NSButtonCell)?.highlightsBy = []

        if let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: toolTip) {
            self.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = isHovering || isHighlighted || isActive
        contentTintColor = isActive ? accentGreen : (emphasized ? .labelColor : .secondaryLabelColor)
        if emphasized {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            (isActive ? AdaptiveChrome.selectedFill : AdaptiveChrome.subtleFill).setFill()
            bg.fill()
            if isActive {
                accentGreen.setStroke()
                bg.lineWidth = 1.2
                bg.stroke()
            }
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Color + Size Sub-toolbar

private enum ShapeStrokePreviewShape {
    case rectangle
    case ellipse
}

private class ColorSizeSubToolbar: NSView {
    var currentColor: NSColor = EditorStyleDefaults.primaryColor
    var currentSize: CGFloat = 3.0
    var currentArrowStyle: ArrowStyle?
    var currentShapeFillMode: ShapeFillMode?
    var currentShapeStrokeStyle: ShapeStrokeStyle?
    var onColorChanged: ((NSColor) -> Void)?
    var onSizeBegan: (() -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?
    var onSizeEnded: (() -> Void)?
    var onArrowStyleChanged: ((ArrowStyle) -> Void)?
    var onShapeFillModeChanged: ((ShapeFillMode) -> Void)?
    var onShapeStrokeStyleChanged: ((ShapeStrokeStyle) -> Void)?

    private var sizeSlider: HUDSlider?
    private var colorButtons: [NSView] = []
    private var arrowStyleButtons: [ArrowStyleButtonView] = []
    private var shapeFillModeControl: ShapeFillModeSegmentedControl?
    private var shapeStrokeStyleButtons: [ShapeStrokeStyleButtonView] = []

    private let sizes: [CGFloat]
    private let sizeMinValue: CGFloat
    private let sizeMaxValue: CGFloat
    private let dynamicColor: NSColor?
    private let showsShapeFillModes: Bool
    private let showsShapeStrokeStyles: Bool
    private let shapeStrokePreviewShape: ShapeStrokePreviewShape
    private let baseColors: [NSColor] = EditorStyleDefaults.paletteColors
    private var colors: [NSColor] {
        guard let dynamicColor else { return baseColors }
        return baseColors + [dynamicColor]
    }

    private static let leadingPad: CGFloat = 12
    private static let sizeSliderWidth: CGFloat = 136
    private static let swatchSize: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let separatorGap: CGFloat = 6
    private static let arrowStyleGap: CGFloat = 8
    private static let arrowStyleButtonWidth: CGFloat = 27
    private static let arrowStyleButtonHeight: CGFloat = 20
    private static let arrowStyleButtonGap: CGFloat = 4
    private static let shapeButtonWidth: CGFloat = 27
    private static let shapeButtonHeight: CGFloat = 20
    private static let trailingPad: CGFloat = 12
    private static var baseColorCount: CGFloat { CGFloat(EditorStyleDefaults.paletteColors.count) }

    static func preferredWidth(
        sizes: [CGFloat],
        dynamicColor: NSColor?,
        showsShapeFillModes: Bool,
        showsArrowStyles: Bool = false,
        showsShapeStrokeStyles: Bool = false,
        shapeStrokePreviewShape: ShapeStrokePreviewShape = .rectangle
    ) -> CGFloat {
        var x = leadingPad
        if showsArrowStyles {
            let styleCount = CGFloat(ArrowStyle.allCases.count)
            x += styleCount * arrowStyleButtonWidth + max(styleCount - 1, 0) * arrowStyleButtonGap
            x += separatorGap + 1 + arrowStyleGap
        }

        if showsShapeStrokeStyles {
            let styleCount = CGFloat(shapeStrokeStyles(for: shapeStrokePreviewShape).count)
            x += styleCount * shapeButtonWidth + max(styleCount - 1, 0) * arrowStyleButtonGap
            x += separatorGap + 1 + arrowStyleGap
        }

        if !sizes.isEmpty {
            x += sizeSliderWidth
            x += 8 + 1 + 9
        }

        let colorCount = baseColorCount + (dynamicColor == nil ? 0.0 : 1.0)
        x += colorCount * swatchSize + max(colorCount - 1, 0) * swatchGap

        if showsShapeFillModes {
            x += separatorGap + 1 + arrowStyleGap
            x += ShapeFillModeSegmentedControl.preferredWidth()
        }

        return ceil(x + trailingPad)
    }

    private static func shapeStrokeStyles(for previewShape: ShapeStrokePreviewShape) -> [ShapeStrokeStyle] {
        switch previewShape {
        case .rectangle:
            return ShapeStrokeStyle.allCases
        case .ellipse:
            return ShapeStrokeStyle.allCases.filter { $0 != .rounded }
        }
    }

    init(
        frame: NSRect,
        sizes: [CGFloat] = [2, 4, 6],
        currentColor: NSColor = .red,
        dynamicColor: NSColor? = nil,
        currentSize: CGFloat = 3.0,
        sizeMinValue: CGFloat = CGFloat(Defaults.editorLineWidthMin),
        sizeMaxValue: CGFloat = CGFloat(Defaults.editorLineWidthMax),
        shapeFillMode: ShapeFillMode? = nil,
        shapeStrokeStyle: ShapeStrokeStyle? = nil,
        shapeStrokePreviewShape: ShapeStrokePreviewShape = .rectangle,
        arrowStyle: ArrowStyle? = nil
    ) {
        self.sizes = sizes
        self.sizeMinValue = sizeMinValue
        self.sizeMaxValue = max(sizeMinValue, sizeMaxValue)
        self.currentColor = currentColor
        self.dynamicColor = dynamicColor
        self.currentSize = min(max(currentSize, sizeMinValue), max(sizeMinValue, sizeMaxValue))
        self.currentShapeFillMode = shapeFillMode
        self.currentShapeStrokeStyle = shapeStrokeStyle
        self.currentArrowStyle = arrowStyle
        self.showsShapeFillModes = shapeFillMode != nil
        self.showsShapeStrokeStyles = shapeStrokeStyle != nil
        self.shapeStrokePreviewShape = shapeStrokePreviewShape
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x = Self.leadingPad
        let midY = bounds.midY

        func addStyleSeparator() {
            x += Self.separatorGap
            addSubview(AdaptiveSeparatorView(frame: NSRect(
                x: x, y: 6, width: 1, height: bounds.height - 12
            )))
            x += 1 + Self.arrowStyleGap
        }

        // Match the mosaic toolbar: choose the style before its size slider.
        if currentArrowStyle != nil {
            for style in ArrowStyle.allCases {
                let button = ArrowStyleButtonView(
                    frame: NSRect(
                        x: x,
                        y: midY - Self.arrowStyleButtonHeight / 2,
                        width: Self.arrowStyleButtonWidth,
                        height: Self.arrowStyleButtonHeight
                    ),
                    style: style,
                    isSelected: currentArrowStyle == style
                )
                let click = NSClickGestureRecognizer(target: self, action: #selector(arrowStyleTapped(_:)))
                button.addGestureRecognizer(click)
                addSubview(button)
                arrowStyleButtons.append(button)
                x += Self.arrowStyleButtonWidth + Self.arrowStyleButtonGap
            }
            x -= Self.arrowStyleButtonGap
            addStyleSeparator()
        }

        if showsShapeStrokeStyles {
            for style in Self.shapeStrokeStyles(for: shapeStrokePreviewShape) {
                let button = ShapeStrokeStyleButtonView(
                    frame: NSRect(
                        x: x,
                        y: midY - Self.shapeButtonHeight / 2,
                        width: Self.shapeButtonWidth,
                        height: Self.shapeButtonHeight
                    ),
                    style: style,
                    previewShape: shapeStrokePreviewShape,
                    isSelected: currentShapeStrokeStyle == style
                )
                let click = NSClickGestureRecognizer(target: self, action: #selector(shapeStrokeStyleTapped(_:)))
                button.addGestureRecognizer(click)
                addSubview(button)
                shapeStrokeStyleButtons.append(button)
                x += Self.shapeButtonWidth + Self.arrowStyleButtonGap
            }
            x -= Self.arrowStyleButtonGap
            addStyleSeparator()
        }

        if !sizes.isEmpty {
            let slider = HUDSlider(
                value: Double(currentSize),
                minValue: Double(sizeMinValue),
                maxValue: Double(sizeMaxValue),
                target: self,
                action: #selector(sizeSliderChanged(_:))
            )
            slider.isContinuous = true
            slider.frame = NSRect(
                x: x,
                y: midY - HUDSlider.preferredHeight / 2,
                width: Self.sizeSliderWidth,
                height: HUDSlider.preferredHeight
            )
            slider.onEditingBegan = { [weak self] in self?.onSizeBegan?() }
            slider.onEditingEnded = { [weak self] in self?.onSizeEnded?() }
            addSubview(slider)
            sizeSlider = slider
            x += Self.sizeSliderWidth
        }

        // Separator only when there's a size section to separate from.
        if !sizes.isEmpty {
            x += 8
            let sep = AdaptiveSeparatorView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
            addSubview(sep)
            x += 1 + 9
        }

        // Color swatches. The dynamic picked color uses an ink-bottle glyph
        // rather than another static-looking palette dot.
        let swatchSize: CGFloat = ColorSizeSubToolbar.swatchSize
        for (i, color) in colors.enumerated() {
            let style: ColorSwatchView.Style = (dynamicColor != nil && i == baseColors.count)
                ? .pickedInkBottle
                : .paletteDot
            let swatch = ColorSwatchView(
                frame: NSRect(x: x, y: midY - swatchSize/2, width: swatchSize, height: swatchSize),
                color: color,
                isSelected: colorsMatch(color, currentColor),
                style: style
            )
            if style == .pickedInkBottle {
                swatch.hoverTip = L10n.tipPickedInkBottle
            }
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(colorTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            colorButtons.append(swatch)
            x += swatchSize + ColorSizeSubToolbar.swatchGap
        }

        let lastSectionRightEdge = x - ColorSizeSubToolbar.swatchGap

        if showsShapeFillModes {
            let fillSepX = lastSectionRightEdge + ColorSizeSubToolbar.separatorGap
            let fillSep = AdaptiveSeparatorView(frame: NSRect(x: fillSepX, y: 6, width: 1, height: bounds.height - 12))
            addSubview(fillSep)

            x = fillSepX + 1 + ColorSizeSubToolbar.arrowStyleGap
            let controlWidth = ShapeFillModeSegmentedControl.preferredWidth()
            let control = ShapeFillModeSegmentedControl(
                frame: NSRect(
                    x: x,
                    y: midY - ShapeFillModeSegmentedControl.preferredHeight / 2,
                    width: controlWidth,
                    height: ShapeFillModeSegmentedControl.preferredHeight
                ),
                selectedMode: currentShapeFillMode ?? .none
            )
            control.onSelect = { [weak self] mode in
                self?.currentShapeFillMode = mode
                self?.onShapeFillModeChanged?(mode)
            }
            addSubview(control)
            shapeFillModeControl = control
        }
    }

    @objc private func sizeSliderChanged(_ sender: HUDSlider) {
        currentSize = min(max(CGFloat(sender.doubleValue), sizeMinValue), sizeMaxValue)
        onSizeChanged?(currentSize)
    }

    @objc private func colorTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? ColorSwatchView else { return }
        let index = view.itemIndex
        let paletteColors = colors
        guard index < paletteColors.count else { return }
        currentColor = paletteColors[index]
        onColorChanged?(currentColor)
        updateColorSelection()
    }

    @objc private func arrowStyleTapped(_ gesture: NSGestureRecognizer) {
        ToolTipWindow.hide()
        guard let view = gesture.view as? ArrowStyleButtonView else { return }
        currentArrowStyle = view.style
        onArrowStyleChanged?(view.style)
        updateArrowStyleSelection()
    }

    @objc private func shapeStrokeStyleTapped(_ gesture: NSGestureRecognizer) {
        ToolTipWindow.hide()
        guard let view = gesture.view as? ShapeStrokeStyleButtonView else { return }
        currentShapeStrokeStyle = view.style
        onShapeStrokeStyleChanged?(view.style)
        updateShapeStrokeStyleSelection()
    }

    private func updateColorSelection() {
        let paletteColors = colors
        for (i, view) in colorButtons.enumerated() where i < paletteColors.count {
            (view as? ColorSwatchView)?.isSelected = colorsMatch(paletteColors[i], currentColor)
        }
    }

    private func updateArrowStyleSelection() {
        for view in arrowStyleButtons {
            view.isSelected = view.style == currentArrowStyle
        }
    }

    private func updateShapeFillModeSelection() {
        shapeFillModeControl?.selectedMode = currentShapeFillMode ?? .none
    }

    private func updateShapeStrokeStyleSelection() {
        for view in shapeStrokeStyleButtons {
            view.isSelected = view.style == currentShapeStrokeStyle
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
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }
}

// MARK: - Mosaic Sub-toolbar

private class MosaicSubToolbar: NSView {
    private var currentStyle: MosaicStyle
    private var currentBlockSize: CGFloat
    private var currentBlurRadius: CGFloat
    var onAdjustmentBegan: (() -> Void)?
    var onSettingsChanged: ((MosaicStyle, CGFloat, CGFloat) -> Void)?
    var onAdjustmentEnded: (() -> Void)?

    private var slider: HUDSlider!
    private var styleButtons: [ToolButton] = []

    static let preferredWidth: CGFloat = 252
    private static let leadingPad: CGFloat = 12
    private static let buttonSize: CGFloat = 28
    private static let sliderWidth: CGFloat = 154

    init(frame: NSRect, style: MosaicStyle, blockSize: CGFloat, blurRadius: CGFloat) {
        self.currentStyle = style
        self.currentBlockSize = blockSize
        self.currentBlurRadius = blurRadius
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x = Self.leadingPad
        let midY = bounds.midY

        for (index, style) in [MosaicStyle.pixelate, .blur].enumerated() {
            let tip = style == .pixelate ? L10n.tipMosaic : L10n.mosaicBlur
            let blurIcon: NSImage? = style == .blur ? NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                NSGradient(
                    starting: NSColor.black,
                    ending: NSColor.black.withAlphaComponent(0)
                )?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
                return true
            } : nil
            let button = ToolButton(
                frame: NSRect(x: x, y: midY - Self.buttonSize / 2,
                              width: Self.buttonSize, height: Self.buttonSize),
                symbolName: "square.grid.3x3.fill",
                normalColor: .secondaryLabelColor,
                selectedColor: accentGreen,
                iconImage: blurIcon
            )
            button.tag = index
            button.hoverTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = #selector(styleChanged(_:))
            addSubview(button)
            styleButtons.append(button)
            x += Self.buttonSize
        }

        x += 8
        let separator = NSView(frame: NSRect(x: x, y: midY - 9, width: 1, height: 18))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = AdaptiveChrome.separator.cgColor
        addSubview(separator)
        x += 10

        let s = HUDSlider(
            value: Double(currentBlockSize),
            minValue: Defaults.mosaicBlockSizeMin,
            maxValue: Defaults.mosaicBlockSizeMax,
            target: self,
            action: #selector(sliderChanged(_:))
        )
        s.isContinuous = true
        s.frame = NSRect(
            x: x,
            y: midY - HUDSlider.preferredHeight / 2,
            width: Self.sliderWidth,
            height: HUDSlider.preferredHeight
        )
        s.onEditingBegan = { [weak self] in self?.onAdjustmentBegan?() }
        s.onEditingEnded = { [weak self] in self?.onAdjustmentEnded?() }
        addSubview(s)
        slider = s
        updateControls()
    }

    @objc private func styleChanged(_ sender: ToolButton) {
        let style: MosaicStyle = sender.tag == 0 ? .pixelate : .blur
        guard style != currentStyle else { return }
        onAdjustmentBegan?()
        currentStyle = style
        updateControls()
        onSettingsChanged?(currentStyle, currentBlockSize, currentBlurRadius)
        onAdjustmentEnded?()
    }

    private func updateControls() {
        let isBlur = currentStyle == .blur
        for (index, button) in styleButtons.enumerated() {
            button.isSelected = (index == 1) == isBlur
            button.setAccessibilityValue(button.isSelected ? 1 : 0)
        }
        slider.minValue = isBlur ? Defaults.mosaicBlurRadiusMin : Defaults.mosaicBlockSizeMin
        slider.maxValue = isBlur ? Defaults.mosaicBlurRadiusMax : Defaults.mosaicBlockSizeMax
        slider.doubleValue = Double(isBlur ? currentBlurRadius : currentBlockSize)
        let tip = isBlur ? L10n.mosaicBlurAmount : L10n.mosaicGranularity
        slider.toolTip = tip
        slider.setAccessibilityLabel(tip)
    }

    @objc private func sliderChanged(_ sender: HUDSlider) {
        let value = CGFloat(min(max(sender.doubleValue, sender.minValue), sender.maxValue))
        if currentStyle == .blur {
            currentBlurRadius = value
        } else {
            currentBlockSize = value
        }
        onSettingsChanged?(currentStyle, currentBlockSize, currentBlurRadius)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }
}

// MARK: - Text Sub-toolbar

/// Text-tool sub-toolbar — color swatches plus a 10–100 font-size slider.
private class TextSubToolbar: NSView {
    var currentColor: NSColor = .red
    var currentFontSize: CGFloat = CGFloat(Defaults.lastTextFontSize)
    var currentFontName: String? = Defaults.textFontName
    var strokeEnabled: Bool = false
    var calloutEnabled: Bool = false
    var onColorChanged: ((NSColor) -> Void)?
    /// Fired when the user grabs the slider thumb (mouseDown phase).
    var onFontSizeBegan: (() -> Void)?
    /// Fired on every slider tick during a drag.
    var onFontSizeChanged: ((CGFloat) -> Void)?
    /// Fired when the user releases the slider (mouseUp phase).
    var onFontSizeEnded: (() -> Void)?
    /// Fired when the outline checkbox is toggled.
    var onStrokeChanged: ((Bool) -> Void)?
    /// Fired when the callout checkbox is toggled.
    var onCalloutChanged: ((Bool) -> Void)?
    /// Fired when a font family is picked. nil = the system default.
    var onFontNameChanged: ((String?) -> Void)?
    /// Fired after the font menu is dismissed so the editor can take focus back.
    var onFontMenuClosed: (() -> Void)?

    private var colorButtons: [NSView] = []
    private var fontButton: HUDPopupButton!
    private var slider: HUDSlider!
    private var strokeCheckbox: HUDCheckboxButton!
    private var calloutCheckbox: HUDCheckboxButton!

    private let dynamicColor: NSColor?
    private let baseColors: [NSColor] = EditorStyleDefaults.paletteColors
    private var colors: [NSColor] {
        guard let dynamicColor else { return baseColors }
        return baseColors + [dynamicColor]
    }

    // Layout metrics, shared between `setup()` and `preferredWidth` so the
    // view is always wide enough for everything it lays out.
    private static let leadingPad: CGFloat = 12
    private static let fontButtonWidth: CGFloat = 116
    private static let fontButtonHeight: CGFloat = 22
    /// Gap between a control and the separator that follows it, mirroring the
    /// `slider -> separator` spacing already used further down the row.
    private static let sectionGap: CGFloat = 8
    /// Gap between a separator and the control that follows it.
    private static let postSeparatorGap: CGFloat = 9
    private static let sliderWidth: CGFloat = 150
    private static let swatchSize: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let separatorGap: CGFloat = 6
    private static let checkboxGap: CGFloat = 8
    private static let trailingPad: CGFloat = 12
    private static var baseColorCount: CGFloat { CGFloat(EditorStyleDefaults.paletteColors.count) }

    /// Left edge of the font-size slider — the font picker sits before it.
    private static var sliderStartX: CGFloat {
        leadingPad + fontButtonWidth + sectionGap + 1 + postSeparatorGap
    }

    /// Right edge of the last color swatch — the swatch row's extent.
    private static func swatchRowEnd(hasDynamicColor: Bool) -> CGFloat {
        let colorCount = baseColorCount + (hasDynamicColor ? 1.0 : 0.0)
        return sliderStartX + sliderWidth + 8 + 1 + 9
            + colorCount * swatchSize + max(colorCount - 1, 0) * swatchGap
    }

    private static func checkboxWidth(title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return 16 + 8 + textWidth
    }

    private static var strokeCheckboxWidth: CGFloat {
        checkboxWidth(title: L10n.textStrokeEffect)
    }

    private static var calloutCheckboxWidth: CGFloat {
        checkboxWidth(title: L10n.textCalloutEffect)
    }

    static func preferredWidth(dynamicColor: NSColor?) -> CGFloat {
        swatchRowEnd(hasDynamicColor: dynamicColor != nil)
            + separatorGap + 1 + checkboxGap
            + strokeCheckboxWidth + checkboxGap + calloutCheckboxWidth
            + trailingPad
    }

    init(
        frame: NSRect,
        currentColor: NSColor,
        currentFontSize: CGFloat,
        currentFontName: String?,
        dynamicColor: NSColor? = nil,
        strokeEnabled: Bool,
        calloutEnabled: Bool
    ) {
        self.currentColor = currentColor
        self.currentFontSize = currentFontSize
        self.currentFontName = currentFontName
        self.dynamicColor = dynamicColor
        self.strokeEnabled = strokeEnabled
        self.calloutEnabled = calloutEnabled
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x: CGFloat = TextSubToolbar.leadingPad
        let midY = bounds.midY

        // Font family picker. Fixed width with a truncating title so a long
        // family name can never push the rest of the row out of the HUD.
        let fontPicker = HUDPopupButton(
            frame: NSRect(
                x: x,
                y: midY - TextSubToolbar.fontButtonHeight / 2,
                width: TextSubToolbar.fontButtonWidth,
                height: TextSubToolbar.fontButtonHeight
            ),
            target: self,
            action: #selector(fontButtonClicked(_:))
        )
        fontPicker.titleText = FontCatalog.title(for: currentFontName)
        fontPicker.setAccessibilityLabel(L10n.textFontLabel)
        addSubview(fontPicker)
        fontButton = fontPicker
        x += TextSubToolbar.fontButtonWidth + TextSubToolbar.sectionGap

        // Vertical separator between the font picker and the size slider.
        let fontSep = AdaptiveSeparatorView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
        addSubview(fontSep)
        x += 1 + TextSubToolbar.postSeparatorGap

        // Font-size slider.
        let s = HUDSlider(
            value: Double(currentFontSize),
            minValue: Defaults.textFontSizeMin,
            maxValue: Defaults.textFontSizeMax,
            target: self,
            action: #selector(sliderChanged(_:))
        )
        s.isContinuous = true
        s.frame = NSRect(
            x: x,
            y: midY - HUDSlider.preferredHeight / 2,
            width: TextSubToolbar.sliderWidth,
            height: HUDSlider.preferredHeight
        )
        s.onEditingBegan = { [weak self] in self?.onFontSizeBegan?() }
        s.onEditingEnded = { [weak self] in self?.onFontSizeEnded?() }
        addSubview(s)
        slider = s
        x += TextSubToolbar.sliderWidth + 8

        // Vertical separator between size controls and color swatches.
        let sep = AdaptiveSeparatorView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
        addSubview(sep)
        x += 1 + 9

        // Color swatches. The dynamic picked color uses an ink-bottle glyph
        // rather than another static-looking palette dot.
        let swatchSize: CGFloat = TextSubToolbar.swatchSize
        for (i, color) in colors.enumerated() {
            let style: ColorSwatchView.Style = (dynamicColor != nil && i == baseColors.count)
                ? .pickedInkBottle
                : .paletteDot
            let swatch = ColorSwatchView(
                frame: NSRect(x: x, y: midY - swatchSize / 2, width: swatchSize, height: swatchSize),
                color: color,
                isSelected: colorsMatch(color, currentColor),
                style: style
            )
            if style == .pickedInkBottle {
                swatch.hoverTip = L10n.tipPickedInkBottle
            }
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(colorTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            colorButtons.append(swatch)
            x += swatchSize + TextSubToolbar.swatchGap
        }

        // Vertical separator between color swatches and the outline checkbox.
        let lastSwatchRightEdge = x - TextSubToolbar.swatchGap
        let strokeSepX = lastSwatchRightEdge + TextSubToolbar.separatorGap
        let strokeSep = AdaptiveSeparatorView(frame: NSRect(x: strokeSepX, y: 6, width: 1, height: bounds.height - 12))
        addSubview(strokeSep)

        // Outline checkbox.
        let checkboxHeight: CGFloat = 20
        let checkbox = HUDCheckboxButton(
            frame: NSRect(
                x: strokeSepX + 1 + TextSubToolbar.checkboxGap,
                y: midY - checkboxHeight / 2,
                width: TextSubToolbar.strokeCheckboxWidth,
                height: checkboxHeight
            ),
            title: L10n.textStrokeEffect,
            target: self,
            action: #selector(strokeCheckboxChanged(_:))
        )
        checkbox.state = strokeEnabled ? .on : .off
        addSubview(checkbox)
        strokeCheckbox = checkbox

        let calloutX = checkbox.frame.maxX + TextSubToolbar.checkboxGap
        let calloutCheckbox = HUDCheckboxButton(
            frame: NSRect(
                x: calloutX,
                y: midY - checkboxHeight / 2,
                width: TextSubToolbar.calloutCheckboxWidth,
                height: checkboxHeight
            ),
            title: L10n.textCalloutEffect,
            target: self,
            action: #selector(calloutCheckboxChanged(_:))
        )
        calloutCheckbox.state = calloutEnabled ? .on : .off
        addSubview(calloutCheckbox)
        self.calloutCheckbox = calloutCheckbox

    }

    @objc private func fontButtonClicked(_ sender: HUDPopupButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let systemItem = ClosureMenuItem(title: L10n.textFontSystemDefault) { [weak self] in
            self?.selectFontName(nil)
        }
        systemItem.state = currentFontName == nil ? .on : .off
        menu.addItem(systemItem)
        menu.addItem(.separator())

        for family in FontCatalog.families {
            let item = ClosureMenuItem(title: FontCatalog.displayName(for: family)) { [weak self] in
                self?.selectFontName(family)
            }
            item.attributedTitle = FontCatalog.previewTitle(for: family)
            item.state = family == currentFontName ? .on : .off
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
        onFontMenuClosed?()
    }

    private func selectFontName(_ fontName: String?) {
        currentFontName = fontName
        fontButton?.titleText = FontCatalog.title(for: fontName)
        onFontNameChanged?(fontName)
    }

    @objc private func strokeCheckboxChanged(_ sender: HUDCheckboxButton) {
        strokeEnabled = sender.state == .on
        onStrokeChanged?(strokeEnabled)
    }

    @objc private func calloutCheckboxChanged(_ sender: HUDCheckboxButton) {
        calloutEnabled = sender.state == .on
        onCalloutChanged?(calloutEnabled)
    }

    @objc private func sliderChanged(_ sender: HUDSlider) {
        let raw = CGFloat(sender.doubleValue)
        let clamped = max(CGFloat(Defaults.textFontSizeMin), min(CGFloat(Defaults.textFontSizeMax), raw))

        currentFontSize = clamped
        onFontSizeChanged?(clamped)
    }

    @objc private func colorTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? ColorSwatchView else { return }
        let index = view.itemIndex
        let paletteColors = colors
        guard index < paletteColors.count else { return }
        currentColor = paletteColors[index]
        onColorChanged?(currentColor)
        for (i, v) in colorButtons.enumerated() where i < paletteColors.count {
            (v as? ColorSwatchView)?.isSelected = colorsMatch(paletteColors[i], currentColor)
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
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }
}

/// Shared hover behaviour for the custom-drawn style choices.
private class StyleOptionView: NSView {
    var hoverTip: String? {
        didSet { setAccessibilityLabel(hoverTip) }
    }
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let hoverTip, let window else { return }
        let frameOnScreen = window.convertToScreen(convert(bounds, to: nil))
        ToolTipWindow.show(text: hoverTip, anchor: frameOnScreen)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        ToolTipWindow.hide()
    }

    override func mouseDown(with event: NSEvent) {
        ToolTipWindow.hide()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolTipWindow.hide() }
    }
}

private final class ArrowStyleButtonView: StyleOptionView {
    let style: ArrowStyle
    var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, style: ArrowStyle, isSelected: Bool) {
        self.style = style
        self.isSelected = isSelected
        super.init(frame: frame)
        switch style {
        case .tapered: hoverTip = L10n.arrowStyleTapered
        case .doubleEnded: hoverTip = L10n.arrowStyleDoubleEnded
        case .line: hoverTip = L10n.arrowStyleLine
        case .dotTail: hoverTip = L10n.arrowStyleDotTail
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = isSelected ? accentGreen : NSColor.secondaryLabelColor
        color.setFill()
        color.setStroke()

        let start = NSPoint(x: bounds.minX + 3, y: bounds.midY)
        let end = NSPoint(x: bounds.maxX - 3, y: bounds.midY)

        switch style {
        case .tapered:
            let path = NSBezierPath()
            let headLength: CGFloat = 8
            let headHalf: CGFloat = 4.5
            let neckHalf: CGFloat = 2.3
            let tailHalf: CGFloat = 1.1
            let baseX = end.x - headLength
            let neckX = end.x - headLength * 0.7
            path.move(to: end)
            path.line(to: NSPoint(x: baseX, y: end.y + headHalf))
            path.line(to: NSPoint(x: neckX, y: end.y + neckHalf))
            path.line(to: NSPoint(x: start.x, y: start.y + tailHalf))
            path.line(to: NSPoint(x: start.x, y: start.y - tailHalf))
            path.line(to: NSPoint(x: neckX, y: end.y - neckHalf))
            path.line(to: NSPoint(x: baseX, y: end.y - headHalf))
            path.close()
            path.fill()

        case .doubleEnded:
            let headLength: CGFloat = 7.5
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: start.x + headLength, y: start.y))
            shaft.line(to: NSPoint(x: end.x - headLength, y: end.y))
            shaft.lineWidth = 2
            shaft.lineCapStyle = .round
            shaft.stroke()
            drawRoundedHead(tip: end, unitX: 1, length: headLength, width: 6)
            drawRoundedHead(tip: start, unitX: -1, length: headLength, width: 6)

        case .line:
            let headLength: CGFloat = 7.5
            let shaft = NSBezierPath()
            shaft.move(to: start)
            shaft.line(to: NSPoint(x: end.x - headLength, y: end.y))
            shaft.lineWidth = 2
            shaft.lineCapStyle = .round
            shaft.stroke()
            drawRoundedHead(tip: end, unitX: 1, length: headLength, width: 6)

        case .dotTail:
            let radius: CGFloat = 3.4
            let headLength: CGFloat = 7.5
            let shaft = NSBezierPath()
            shaft.move(to: start)
            shaft.line(to: NSPoint(x: end.x - headLength, y: end.y))
            shaft.lineWidth = 2
            shaft.lineCapStyle = .round
            shaft.stroke()
            NSBezierPath(ovalIn: NSRect(
                x: start.x - radius,
                y: start.y - radius,
                width: radius * 2,
                height: radius * 2
            )).fill()
            drawRoundedHead(tip: end, unitX: 1, length: headLength, width: 6)
        }
    }

    private func drawRoundedHead(tip: NSPoint, unitX: CGFloat, length: CGFloat, width: CGFloat) {
        let head = arrowHead(tip: tip, unitX: unitX, length: length, width: width)
        head.lineJoinStyle = .round
        head.lineWidth = 0.9
        head.fill()
        head.stroke()
    }

    private func arrowHead(tip: NSPoint, unitX: CGFloat, length: CGFloat, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let baseX = tip.x - unitX * length
        path.move(to: tip)
        path.line(to: NSPoint(x: baseX, y: tip.y + width / 2))
        path.line(to: NSPoint(x: baseX, y: tip.y - width / 2))
        path.close()
        return path
    }
}

// MARK: - Color Swatch View

private class ColorSwatchView: NSView {
    enum Style {
        case paletteDot
        case pickedInkBottle
    }

    let color: NSColor
    private let style: Style
    var hoverTip: String?
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0
    private var hoverTrackingArea: NSTrackingArea?

    init(frame: NSRect, color: NSColor, isSelected: Bool, style: Style = .paletteDot) {
        self.color = color
        self.isSelected = isSelected
        self.style = style
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let tip = hoverTip, let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        ToolTipWindow.show(text: tip, anchor: frameOnScreen)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        ToolTipWindow.hide()
    }

    override func mouseDown(with event: NSEvent) {
        ToolTipWindow.hide()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolTipWindow.hide() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if style == .pickedInkBottle {
            drawInkBottle()
            return
        }

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

    private func drawInkBottle() {
        let unit = min(bounds.width, bounds.height) / 18.0
        let origin = NSPoint(
            x: bounds.midX - 9.0 * unit,
            y: bounds.midY - 9.0 * unit
        )

        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(
                x: origin.x + x * unit,
                y: origin.y + y * unit,
                width: width * unit,
                height: height * unit
            )
        }

        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }

        let bodyRect = rect(4.5, 4.0, 9.0, 9.8)
        let bodyPath = NSBezierPath(
            roundedRect: bodyRect,
            xRadius: 2.2 * unit,
            yRadius: 2.2 * unit
        )

        AdaptiveChrome.subtleFill.setFill()
        bodyPath.fill()

        let inkPath = NSBezierPath()
        let inset = 0.75 * unit
        let inkBottom = bodyRect.minY + inset
        let inkLeft = bodyRect.minX + inset
        let inkRight = bodyRect.maxX - inset
        let inkTop = bodyRect.minY + bodyRect.height * 0.58
        inkPath.move(to: NSPoint(x: inkLeft, y: inkBottom))
        inkPath.line(to: NSPoint(x: inkLeft, y: inkTop))
        inkPath.curve(
            to: NSPoint(x: inkRight, y: inkTop - 0.2 * unit),
            controlPoint1: NSPoint(x: bodyRect.minX + bodyRect.width * 0.36, y: inkTop + 1.15 * unit),
            controlPoint2: NSPoint(x: bodyRect.minX + bodyRect.width * 0.62, y: inkTop - 1.05 * unit)
        )
        inkPath.line(to: NSPoint(x: inkRight, y: inkBottom))
        inkPath.close()

        NSGraphicsContext.current?.saveGraphicsState()
        bodyPath.addClip()
        color.setFill()
        inkPath.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let neckRect = rect(7.0, 12.7, 4.0, 2.0)
        let neckPath = NSBezierPath(roundedRect: neckRect, xRadius: 0.7 * unit, yRadius: 0.7 * unit)
        NSColor.secondaryLabelColor.setFill()
        neckPath.fill()

        let capRect = rect(6.2, 14.2, 5.6, 1.8)
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 0.8 * unit, yRadius: 0.8 * unit)
        NSColor.labelColor.setFill()
        capPath.fill()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: bodyRect.minX + 2.5 * unit, y: bodyRect.minY + 2.1 * unit))
        highlight.line(to: NSPoint(x: bodyRect.minX + 2.5 * unit, y: bodyRect.maxY - 2.3 * unit))
        NSColor.quaternaryLabelColor.setStroke()
        highlight.lineWidth = 1
        highlight.lineCapStyle = .round
        highlight.stroke()

        NSColor.secondaryLabelColor.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        AdaptiveChrome.border.setStroke()
        capPath.lineWidth = 0.6
        capPath.stroke()
    }
}

// MARK: - HUD Slider

final class HUDSlider: NSControl {
    var minValue: Double
    var maxValue: Double
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?

    override var doubleValue: Double {
        get { value }
        set { setValue(newValue, notify: false) }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isDragging = false
            }
            needsDisplay = true
        }
    }

    private var value: Double
    private var isDragging = false {
        didSet { needsDisplay = true }
    }

    static let preferredHeight: CGFloat = 24
    private let trackLeftHeight: CGFloat = 5
    private let trackRightHeight: CGFloat = 14
    private let trackCornerRadius: CGFloat = 3
    private let knobHeight: CGFloat = 20
    private let knobMinWidth: CGFloat = 34
    private let knobHorizontalPadding: CGFloat = 12
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    init(
        frame: NSRect = .zero,
        value: Double,
        minValue: Double,
        maxValue: Double,
        target: AnyObject?,
        action: Selector?
    ) {
        self.minValue = minValue
        self.maxValue = maxValue
        self.value = min(max(value, minValue), maxValue)
        super.init(frame: frame)
        self.target = target
        self.action = action
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

    override func draw(_ dirtyRect: NSRect) {
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.35
        let trackRect = currentTrackRect
        let trackPath = trapezoidPath(
            in: trackRect,
            leftHeight: trackLeftHeight,
            rightHeight: trackRightHeight
        )
        AdaptiveChrome.subtleFill.withAlphaComponent(enabledAlpha).setFill()
        trackPath.fill()

        let knobCenterX = trackRect.minX + normalizedValue * trackRect.width
        if knobCenterX > trackRect.minX {
            let fraction = normalizedValue
            let fillRightHeight = interpolatedTrackHeight(at: fraction)
            let fillPath = trapezoidPath(
                in: NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: knobCenterX - trackRect.minX,
                    height: trackRect.height
                ),
                leftHeight: trackLeftHeight,
                rightHeight: fillRightHeight
            )
            accentGreen.withAlphaComponent(0.18 * enabledAlpha).setFill()
            fillPath.fill()
        }

        AdaptiveChrome.border.withAlphaComponent(enabledAlpha).setStroke()
        trackPath.lineWidth = 1.5
        trackPath.stroke()

        let knobWidth = currentKnobWidth
        let knobRect = NSRect(
            x: knobCenterX - knobWidth / 2,
            y: floor(bounds.midY - knobHeight / 2),
            width: knobWidth,
            height: knobHeight
        )
        let knobPath = NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobHeight / 2,
            yRadius: knobHeight / 2
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24 * enabledAlpha)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.controlBackgroundColor.withAlphaComponent(enabledAlpha).setFill()
        knobPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        AdaptiveChrome.border.withAlphaComponent(enabledAlpha).setStroke()
        knobPath.lineWidth = 0.6
        knobPath.stroke()

        drawValue(in: knobRect, enabledAlpha: enabledAlpha)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isDragging = true
        onEditingBegan?()
        updateValue(with: event, notify: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        updateValue(with: event, notify: isContinuous)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            isDragging = false
            return
        }
        updateValue(with: event, notify: true)
        isDragging = false
        onEditingEnded?()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let fineStep = max((maxValue - minValue) / 100, 0.1)
        let coarseStep = max((maxValue - minValue) / 20, fineStep)
        let step = event.modifierFlags.contains(.shift) ? coarseStep : fineStep
        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_DownArrow:
            onEditingBegan?()
            setValue(value - step, notify: true)
            onEditingEnded?()
        case kVK_RightArrow, kVK_UpArrow:
            onEditingBegan?()
            setValue(value + step, notify: true)
            onEditingEnded?()
        default:
            super.keyDown(with: event)
        }
    }

    private var normalizedValue: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((value - minValue) / (maxValue - minValue))
    }

    private var currentKnobWidth: CGFloat {
        let samples = [
            displayText(for: minValue),
            displayText(for: maxValue),
            displayText(for: value),
        ]
        let maxWidth = samples
            .map { ceil(($0 as NSString).size(withAttributes: [.font: valueFont]).width) }
            .max() ?? 0
        return max(knobMinWidth, maxWidth + knobHorizontalPadding)
    }

    private var currentTrackRect: NSRect {
        let knobWidth = currentKnobWidth
        return NSRect(
            x: knobWidth / 2,
            y: floor(bounds.midY - trackRightHeight / 2),
            width: max(1, bounds.width - knobWidth),
            height: trackRightHeight
        )
    }

    private func updateValue(with event: NSEvent, notify: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let trackRect = currentTrackRect
        let normalized = max(0, min(1, (point.x - trackRect.minX) / trackRect.width))
        setValue(minValue + Double(normalized) * (maxValue - minValue), notify: notify)
    }

    private func setValue(_ newValue: Double, notify: Bool) {
        value = min(max(newValue, minValue), maxValue)
        needsDisplay = true
        if notify, let action {
            sendAction(action, to: target)
        }
    }

    private func trapezoidPath(in rect: NSRect, leftHeight: CGFloat, rightHeight: CGFloat) -> NSBezierPath {
        let leftHalf = leftHeight / 2
        let rightHalf = rightHeight / 2
        return roundedPolygonPath(
            points: [
                NSPoint(x: rect.minX, y: rect.midY + leftHalf),
                NSPoint(x: rect.maxX, y: rect.midY + rightHalf),
                NSPoint(x: rect.maxX, y: rect.midY - rightHalf),
                NSPoint(x: rect.minX, y: rect.midY - leftHalf),
            ],
            radius: trackCornerRadius
        )
    }

    private func roundedPolygonPath(points: [NSPoint], radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count > 2, radius > 0 else {
            if let first = points.first {
                path.move(to: first)
                for point in points.dropFirst() {
                    path.line(to: point)
                }
                path.close()
            }
            return path
        }

        for index in points.indices {
            let current = points[index]
            let previous = points[(index - 1 + points.count) % points.count]
            let next = points[(index + 1) % points.count]
            let previousVector = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
            let nextVector = CGVector(dx: next.x - current.x, dy: next.y - current.y)
            let previousLength = hypot(previousVector.dx, previousVector.dy)
            let nextLength = hypot(nextVector.dx, nextVector.dy)
            guard previousLength > 0, nextLength > 0 else { continue }

            let cornerDistance = min(radius, previousLength / 2, nextLength / 2)
            let start = NSPoint(
                x: current.x + previousVector.dx / previousLength * cornerDistance,
                y: current.y + previousVector.dy / previousLength * cornerDistance
            )
            let end = NSPoint(
                x: current.x + nextVector.dx / nextLength * cornerDistance,
                y: current.y + nextVector.dy / nextLength * cornerDistance
            )

            if index == points.startIndex {
                path.move(to: start)
            } else {
                path.line(to: start)
            }
            path.curve(to: end, controlPoint1: current, controlPoint2: current)
        }
        path.close()
        return path
    }

    private func interpolatedTrackHeight(at fraction: CGFloat) -> CGFloat {
        trackLeftHeight + (trackRightHeight - trackLeftHeight) * max(0, min(1, fraction))
    }

    private func drawValue(in rect: NSRect, enabledAlpha: CGFloat) {
        let text = displayText(for: value)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: valueFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(enabledAlpha),
            ]
        )
        let textSize = attributed.size()
        let textRect = NSRect(
            x: floor(rect.midX - textSize.width / 2),
            y: floor(rect.midY - textSize.height / 2),
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )
        attributed.draw(in: textRect)
    }

    private func displayText(for rawValue: Double) -> String {
        "\(Int(rawValue.rounded()))"
    }
}

private final class ShapeFillModeSegmentedControl: NSView {
    static let preferredHeight: CGFloat = 24
    private static let minSegmentWidth: CGFloat = 54
    private static let segmentHorizontalPadding: CGFloat = 18
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let modes = ShapeFillMode.allCases

    var selectedMode: ShapeFillMode {
        didSet { needsDisplay = true }
    }
    var onSelect: ((ShapeFillMode) -> Void)?

    init(frame: NSRect, selectedMode: ShapeFillMode) {
        self.selectedMode = selectedMode
        super.init(frame: frame)
        toolTip = "\(L10n.shapeFillEffect) (F)"
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func preferredWidth() -> CGFloat {
        segmentWidths().reduce(0, +)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let mode = mode(atX: point.x) else { return }
        selectedMode = mode
        onSelect?(mode)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let background = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        AdaptiveChrome.cardBackground.setFill()
        background.fill()

        let widths = Self.segmentWidths()
        var x = rect.minX
        for (index, mode) in Self.modes.enumerated() {
            let width = widths[index]
            let segmentRect = NSRect(x: x, y: rect.minY, width: width, height: rect.height)
            if mode == selectedMode {
                let selected = NSBezierPath(roundedRect: segmentRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
                accentGreen.setFill()
                selected.fill()
            } else if index > 0 {
                AdaptiveChrome.separator.setStroke()
                let sep = NSBezierPath()
                sep.move(to: NSPoint(x: x, y: rect.minY + 4))
                sep.line(to: NSPoint(x: x, y: rect.maxY - 4))
                sep.lineWidth = 1
                sep.stroke()
            }
            drawTitle(for: mode, in: segmentRect)
            x += width
        }

        AdaptiveChrome.border.setStroke()
        background.lineWidth = 1
        background.stroke()
    }

    private static func segmentWidths() -> [CGFloat] {
        modes.map { mode in
            let textWidth = ceil((title(for: mode) as NSString).size(withAttributes: [.font: font]).width)
            return max(minSegmentWidth, textWidth + segmentHorizontalPadding)
        }
    }

    private static func title(for mode: ShapeFillMode) -> String {
        switch mode {
        case .none: return L10n.shapeFillNone
        case .opaque: return L10n.shapeFillOpaque
        case .translucent: return L10n.shapeFillTranslucent
        }
    }

    private func mode(atX targetX: CGFloat) -> ShapeFillMode? {
        let widths = Self.segmentWidths()
        var x: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if targetX >= x && targetX <= x + width {
                return Self.modes[index]
            }
            x += width
        }
        return nil
    }

    private func drawTitle(for mode: ShapeFillMode, in rect: NSRect) {
        let selected = mode == selectedMode
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
        ]
        let title = Self.title(for: mode) as NSString
        let size = title.size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        title.draw(at: point, withAttributes: attributes)
    }
}

private final class ShapeStrokeStyleButtonView: StyleOptionView {
    let style: ShapeStrokeStyle
    let previewShape: ShapeStrokePreviewShape
    var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, style: ShapeStrokeStyle, previewShape: ShapeStrokePreviewShape, isSelected: Bool) {
        self.style = style
        self.previewShape = previewShape
        self.isSelected = isSelected
        super.init(frame: frame)
        switch style {
        case .standard:
            hoverTip = previewShape == .rectangle ? L10n.tipRectangle : L10n.tipEllipse
        case .rounded:
            hoverTip = L10n.shapeStyleRounded
        case .handDrawn:
            hoverTip = L10n.shapeStyleHandDrawn
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = isSelected ? accentGreen : NSColor.secondaryLabelColor

        if isSelected {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            accentGreen.withAlphaComponent(0.12).setFill()
            bg.fill()
        }

        switch style {
        case .standard:
            drawStandardIcon(color: color)
        case .rounded:
            switch previewShape {
            case .rectangle:
                drawRoundedRectangleIcon(color: color)
            case .ellipse:
                drawStandardIcon(color: color)
            }
        case .handDrawn:
            switch previewShape {
            case .rectangle:
                drawHandDrawnRectangleIcon(color: color)
            case .ellipse:
                drawHandDrawnCircleIcon(color: color)
            }
        }
    }

    private func drawStandardIcon(color: NSColor) {
        color.setStroke()
        switch previewShape {
        case .rectangle:
            let rect = bounds.insetBy(dx: 6, dy: 4.5)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.9
            path.stroke()
        case .ellipse:
            let side = min(bounds.width, bounds.height) - 8
            let rect = NSRect(
                x: bounds.midX - side / 2,
                y: bounds.midY - side / 2,
                width: side,
                height: side
            )
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1.9
            path.stroke()
        }
    }

    private func drawRoundedRectangleIcon(color: NSColor) {
        color.setStroke()
        let rect = bounds.insetBy(dx: 6, dy: 4.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4.3, yRadius: 4.3)
        path.lineWidth = 1.9
        path.stroke()
    }

    private func drawHandDrawnRectangleIcon(color: NSColor) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        let outerRect = bounds.insetBy(dx: 4.4, dy: 3.4)
        let innerRect = NSRect(
            x: outerRect.minX + 4.2,
            y: outerRect.minY + 3.2,
            width: outerRect.width - 7.4,
            height: outerRect.height - 5.5
        )
        let outerRadius: CGFloat = 5.2
        let innerRadius: CGFloat = 2.6
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: outerRadius, yRadius: outerRadius)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)
        fillHandDrawnPreviewRing(outer: outer, inner: inner, color: color)
    }

    private func drawHandDrawnCircleIcon(color: NSColor) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        let outerRect = NSRect(
            x: bounds.midX - 9.4,
            y: bounds.midY - 6.9,
            width: 18.8,
            height: 13.8
        )
        let innerRect = NSRect(
            x: outerRect.minX + 3.0,
            y: outerRect.minY + 2.35,
            width: outerRect.width - 5.7,
            height: outerRect.height - 5.25
        )
        let outer = NSBezierPath(ovalIn: outerRect)
        let inner = NSBezierPath(ovalIn: innerRect)
        fillHandDrawnPreviewRing(outer: outer, inner: inner, color: color)
    }

    private func fillHandDrawnPreviewRing(outer: NSBezierPath, inner: NSBezierPath, color: NSColor) {
        let shape = NSBezierPath()
        shape.append(outer)
        shape.append(inner)
        shape.windingRule = .evenOdd
        color.setFill()
        shape.fill()
    }
}

// MARK: - HUD Checkbox

/// HUD-styled pop-up button used inside the floating sub-toolbars.
///
/// Visual language matches `HUDCheckboxButton`: 12pt medium label in
/// `labelColor`, `AdaptiveChrome.subtleFill` background with an
/// `AdaptiveChrome.border` outline, so it adapts to light and dark exactly like
/// the checkboxes and separators sitting next to it. The title truncates and a
/// trailing chevron marks it as a menu.
private final class HUDPopupButton: NSButton {
    private let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let horizontalPad: CGFloat = 8
    private let chevronSize: CGFloat = 9
    private let chevronGap: CGFloat = 6

    var hoverTip: String?

    var titleText: String = "" {
        didSet {
            hoverTip = titleText
            setAccessibilityValue(titleText)
            needsDisplay = true
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(frame frameRect: NSRect, target: AnyObject?, action: Selector?) {
        super.init(frame: frameRect)
        self.title = ""
        self.target = target
        self.action = action
        setButtonType(.momentaryChange)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        (cell as? NSButtonCell)?.highlightsBy = []
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        guard let tip = hoverTip, !tip.isEmpty, let window else { return }
        let frameOnScreen = window.convertToScreen(convert(bounds, to: nil))
        ToolTipWindow.show(text: tip, anchor: frameOnScreen)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        ToolTipWindow.hide()
    }

    override func mouseDown(with event: NSEvent) {
        ToolTipWindow.hide()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolTipWindow.hide() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = isHovering || isHighlighted
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)

        // The adaptive chrome colors already carry their own alpha (subtleFill
        // is 8-10% ink, border 16%). `withAlphaComponent` REPLACES that alpha
        // rather than scaling it, so re-applying it here painted a near-opaque
        // black slab in light mode and a near-opaque white one in dark mode.
        // Use them unmodified, exactly like MoreOptionsButton and ToolButton.
        (emphasized ? AdaptiveChrome.selectedFill : AdaptiveChrome.subtleFill).setFill()
        box.fill()
        AdaptiveChrome.border.setStroke()
        box.lineWidth = 1
        box.stroke()

        let foreground = isEnabled
            ? NSColor.labelColor
            : NSColor.labelColor.withAlphaComponent(0.35)

        // Hand-drawn chevron rather than a tinted SF Symbol image: an
        // NSImage drawing handler runs outside the view's drawing appearance,
        // so `labelColor` inside it resolved against the wrong appearance.
        let chevronCenterX = bounds.maxX - horizontalPad - chevronSize / 2
        let halfChevron = chevronSize / 2
        // NSButton draws flipped, so "down" is +y there and -y in a plain view.
        let chevronDrop = halfChevron * 0.45 * (isFlipped ? 1 : -1)
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: chevronCenterX - halfChevron, y: bounds.midY - chevronDrop))
        chevron.line(to: NSPoint(x: chevronCenterX, y: bounds.midY + chevronDrop))
        chevron.line(to: NSPoint(x: chevronCenterX + halfChevron, y: bounds.midY - chevronDrop))
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        foreground.setStroke()
        chevron.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(
            string: titleText,
            attributes: [
                .font: labelFont,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
            ]
        )
        let textHeight = ceil(attributed.size().height)
        let textRect = NSRect(
            x: horizontalPad,
            y: floor(bounds.midY - textHeight / 2),
            width: max(0, chevronCenterX - halfChevron - chevronGap - horizontalPad),
            height: textHeight
        )
        attributed.draw(in: textRect)
    }
}

private final class HUDCheckboxButton: NSButton {
    private let label: String
    private let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let boxSize: CGFloat = 16

    init(frame: NSRect, title: String, target: AnyObject?, action: Selector?) {
        self.label = title
        super.init(frame: frame)
        self.title = ""
        self.target = target
        self.action = action
        setButtonType(.toggle)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.35
        let boxRect = NSRect(
            x: 0,
            y: floor(bounds.midY - boxSize / 2),
            width: boxSize,
            height: boxSize
        )
        let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4)

        if state == .on {
            accentGreen.withAlphaComponent(enabledAlpha).setFill()
        } else {
            AdaptiveChrome.subtleFill
                .withAlphaComponent((isHighlighted ? 1.0 : 0.72) * enabledAlpha)
                .setFill()
        }
        boxPath.fill()

        AdaptiveChrome.border.withAlphaComponent(enabledAlpha).setStroke()
        boxPath.lineWidth = 1
        boxPath.stroke()

        if state == .on {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: boxRect.minX + 4.0, y: boxRect.midY + 0.5))
            check.line(to: NSPoint(x: boxRect.minX + 7.0, y: boxRect.midY + 3.5))
            check.line(to: NSPoint(x: boxRect.maxX - 3.5, y: boxRect.midY - 4.0))
            check.lineWidth = 2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor(white: 0.08, alpha: enabledAlpha).setStroke()
            check.stroke()
        }

        let attributed = NSAttributedString(
            string: label,
            attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(enabledAlpha),
            ]
        )
        let textSize = attributed.size()
        let textRect = NSRect(
            x: boxRect.maxX + 8,
            y: floor(bounds.midY - textSize.height / 2),
            width: max(0, bounds.width - boxRect.maxX - 8),
            height: ceil(textSize.height)
        )
        attributed.draw(in: textRect)
    }
}

// MARK: - Beautify Sub-toolbar

private class BeautifySubToolbar: NSView {
    var onPresetSelected: ((BeautifyPreset) -> Void)?
    var onMoreRequested: ((NSView) -> Void)?
    var currentPresetID: String? {
        didSet { updateSelection() }
    }

    var onShadowSizeChanged: ((CGFloat) -> Void)?
    var onShadowSizeEditingBegan: (() -> Void)?
    var onShadowSizeEditingEnded: (() -> Void)?

    private var swatchButtons: [BeautifySwatchView] = []
    private(set) var presets: [BeautifyPreset]
    private let initialShadowSize: CGFloat
    private let screen: NSScreen
    private let moreButton = MoreOptionsButton(
        frame: .zero,
        toolTip: L10n.tipMoreBeautifyPresets
    )
    private var shadowSizeSlider: HUDSlider?
    private let swatchDiameter: CGFloat = BeautifySubToolbar.swatchDiameter
    private let swatchSpacing: CGFloat = BeautifySubToolbar.swatchSpacing
    private let innerPadding: CGFloat = BeautifySubToolbar.innerPadding
    private let sliderWidth: CGFloat = BeautifySubToolbar.sliderWidth
    private let sliderHeight: CGFloat = BeautifySubToolbar.sliderHeight

    private static let swatchDiameter: CGFloat = 24
    private static let swatchSpacing: CGFloat = 8
    private static let innerPadding: CGFloat = 12
    private static let sectionGap: CGFloat = 6
    private static let separatorWidth: CGFloat = 1
    private static let moreButtonSize: CGFloat = 30
    private static let sliderWidth: CGFloat = 120
    private static let sliderHeight: CGFloat = 20
    private static let trailingPadding: CGFloat = 12

    init(
        frame: NSRect,
        presets: [BeautifyPreset],
        screen: NSScreen,
        initialShadowSize: CGFloat = BeautifyRenderer.shadowSizeDefault
    ) {
        self.presets = presets
        self.screen = screen
        self.initialShadowSize = initialShadowSize
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func preferredWidth(presetCount: Int) -> CGFloat {
        let swatches = CGFloat(presetCount) * swatchDiameter
            + CGFloat(max(presetCount - 1, 0)) * swatchSpacing
        let moreButtonSection = sectionGap + moreButtonSize
        let separatedSlider = sectionGap + separatorWidth + sectionGap
            + sliderWidth
        return innerPadding + swatches + moreButtonSection + separatedSlider
            + trailingPadding
    }

    private func setup() {
        rebuildSwatches()

        var x = innerPadding
            + CGFloat(presets.count) * swatchDiameter
            + CGFloat(max(presets.count - 1, 0)) * swatchSpacing
        let midY = bounds.midY
        x += Self.sectionGap

        moreButton.frame = NSRect(
            x: x,
            y: midY - Self.moreButtonSize / 2,
            width: Self.moreButtonSize,
            height: Self.moreButtonSize
        )
        moreButton.target = self
        moreButton.action = #selector(showMorePresets)
        addSubview(moreButton)
        x = addSeparator(after: moreButton.frame.maxX)

        let slider = HUDSlider(
            value: Double(initialShadowSize),
            minValue: Double(BeautifyRenderer.shadowSizeMin),
            maxValue: Double(BeautifyRenderer.shadowSizeMax),
            target: self,
            action: #selector(shadowSizeSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.frame = NSRect(
            x: x,
            y: midY - sliderHeight / 2,
            width: sliderWidth,
            height: sliderHeight
        )
        slider.toolTip = L10n.beautifyShadowSizeHint
        slider.setAccessibilityLabel(L10n.shadowSizeLabel)
        slider.onEditingBegan = { [weak self] in self?.onShadowSizeEditingBegan?() }
        slider.onEditingEnded = { [weak self] in self?.onShadowSizeEditingEnded?() }
        addSubview(slider)
        shadowSizeSlider = slider

        updateSelection()
    }

    func updatePresets(_ presets: [BeautifyPreset]) {
        self.presets = presets
        rebuildSwatches()
    }

    private func rebuildSwatches() {
        for swatch in swatchButtons {
            swatch.removeFromSuperview()
        }
        swatchButtons.removeAll()

        var x: CGFloat = innerPadding
        let midY = bounds.midY
        for (index, preset) in presets.enumerated() {
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
            swatch.itemIndex = index
            if preset.isWallpaper {
                BeautifyRenderer.loadWallpaperImage(for: screen) { [weak swatch] image in
                    swatch?.wallpaperThumbnail = image
                }
            }
            let click = NSClickGestureRecognizer(target: self, action: #selector(swatchTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            swatchButtons.append(swatch)
            x += swatchDiameter + swatchSpacing
        }
        updateSelection()
    }

    private func addSeparator(after rightEdge: CGFloat) -> CGFloat {
        let separatorX = rightEdge + Self.sectionGap
        let separator = AdaptiveSeparatorView(
            frame: NSRect(
                x: separatorX,
                y: 6,
                width: Self.separatorWidth,
                height: bounds.height - 12
            )
        )
        addSubview(separator)
        return separatorX + Self.separatorWidth + Self.sectionGap
    }

    @objc private func swatchTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? BeautifySwatchView else { return }
        let index = view.itemIndex
        guard index < presets.count else { return }
        let preset = presets[index]
        currentPresetID = preset.id
        onPresetSelected?(preset)
    }

    @objc private func shadowSizeSliderChanged(_ sender: HUDSlider) {
        let clamped = max(
            BeautifyRenderer.shadowSizeMin,
            min(BeautifyRenderer.shadowSizeMax, CGFloat(sender.doubleValue))
        )
        onShadowSizeChanged?(clamped)
    }

    @objc private func showMorePresets() {
        onMoreRequested?(moreButton)
    }

    private func updateSelection() {
        for swatch in swatchButtons {
            swatch.isSelected = (swatch.preset.id == currentPresetID)
        }
        moreButton.isActive = currentPresetID.map { selectedID in
            !presets.contains(where: { $0.id == selectedID })
        } ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        AdaptiveChrome.toolbarBackground.setFill()
        path.fill()
    }
}

private final class BeautifyPresetPickerView: NSView {
    var selectedPresetID: String? {
        didSet { updateSelection() }
    }
    var onPresetSelected: ((BeautifyPreset) -> Void)?

    private let presets: [BeautifyPreset]
    private let screen: NSScreen
    private var swatchViews: [BeautifySwatchView] = []

    private static let gridColumns = 6
    private static let swatchDiameter: CGFloat = 32
    private static let columnGap: CGFloat = 18
    private static let rowGap: CGFloat = 12
    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 18
    private static let maxGridItems = 24

    static func preferredSize(itemCount: Int) -> NSSize {
        let visibleCount = min(max(itemCount, 1), maxGridItems)
        let rowCount = (visibleCount + gridColumns - 1) / gridColumns
        let height = verticalPadding * 2
            + CGFloat(rowCount) * swatchDiameter
            + CGFloat(max(rowCount - 1, 0)) * rowGap
        return NSSize(width: 318, height: height)
    }

    init(
        frame: NSRect,
        presets: [BeautifyPreset],
        screen: NSScreen,
        selectedPresetID: String?
    ) {
        self.presets = presets
        self.screen = screen
        self.selectedPresetID = selectedPresetID
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        wantsLayer = true

        let firstRowY = bounds.maxY - Self.verticalPadding - Self.swatchDiameter
        for (index, preset) in presets.prefix(Self.maxGridItems).enumerated() {
            let row = index / Self.gridColumns
            let column = index % Self.gridColumns
            let swatch = BeautifySwatchView(
                frame: NSRect(
                    x: Self.horizontalPadding
                        + CGFloat(column) * (Self.swatchDiameter + Self.columnGap),
                    y: firstRowY
                        - CGFloat(row) * (Self.swatchDiameter + Self.rowGap),
                    width: Self.swatchDiameter,
                    height: Self.swatchDiameter
                ),
                preset: preset,
                isSelected: preset.id == selectedPresetID
            )
            swatch.itemIndex = index
            if preset.isWallpaper {
                BeautifyRenderer.loadWallpaperImage(for: screen) { [weak swatch] image in
                    swatch?.wallpaperThumbnail = image
                }
            }
            let click = NSClickGestureRecognizer(target: self, action: #selector(swatchTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            swatchViews.append(swatch)
        }
    }

    @objc private func swatchTapped(_ gesture: NSGestureRecognizer) {
        guard let swatch = gesture.view as? BeautifySwatchView else { return }
        let index = swatch.itemIndex
        guard presets.indices.contains(index) else { return }
        let preset = presets[index]
        selectedPresetID = preset.id
        onPresetSelected?(preset)
    }

    private func updateSelection() {
        for swatch in swatchViews {
            swatch.isSelected = swatch.preset.id == selectedPresetID
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        AdaptiveChrome.popoverBackground.setFill()
        path.fill()

        AdaptiveChrome.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private class BeautifySwatchView: NSView {
    let preset: BeautifyPreset
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0
    var wallpaperThumbnail: NSImage? {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, preset: BeautifyPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
        super.init(frame: frame)
        toolTip = preset.displayName
        setAccessibilityLabel(preset.displayName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isSelected ? 1 : 2
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let clipPath = NSBezierPath(ovalIn: circleRect)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()

        if preset.isTransparent {
            BeautifyRenderer.drawCheckerboard(in: circleRect, square: 4)
        } else if preset.isWallpaper, let wpImage = wallpaperThumbnail {
            wpImage.draw(in: circleRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else if preset.isWallpaper {
            // Fallback: draw a landscape-like icon
            NSColor(red: 0.4, green: 0.65, blue: 0.45, alpha: 1).setFill()
            circleRect.fill()
            let sky = NSRect(x: circleRect.origin.x, y: circleRect.midY,
                             width: circleRect.width, height: circleRect.height / 2)
            NSColor(red: 0.55, green: 0.75, blue: 0.92, alpha: 1).setFill()
            sky.fill()
        } else if let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) {
            gradient.draw(in: circleRect, angle: preset.angleDegrees)
        } else {
            preset.startColor.setFill()
            circleRect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Subtle outer border keeps both light and dark presets visible
        let border = NSBezierPath(ovalIn: circleRect)
        AdaptiveChrome.border.setStroke()
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

// MARK: - Selection Chrome Overlay

/// Sits above the editor's `canvasScrollView` (so the dashed border + handles
/// stay visible even when beautify expands the canvas frame with a gradient
/// background). Empty space falls through; only handle hits are claimed, and
/// they drive `SelectionView`'s external resize API so the rest of the editor
/// reuses the existing resize → relayout pipeline.
final class SelectionChromeOverlay: NSView {
    weak var selectionView: SelectionView?

    private(set) var selectionRectInView: NSRect = .zero
    private(set) var isActiveAndVisible: Bool = false

    private let accentColor = NSColor(red: 0, green: 212.0/255.0, blue: 106.0/255.0, alpha: 1.0)
    private let handleSize: CGFloat = 8
    private let handleHitSize: CGFloat = 12
    private let borderWidth: CGFloat = 2.0
    private let dashPattern: [CGFloat] = [6, 4]

    private var dragHandle: SelectionView.HandlePosition?
    private var dragOriginalRect: NSRect = .zero

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(rect: NSRect, active: Bool) {
        let changed = (rect != selectionRectInView) || (active != isActiveAndVisible)
        selectionRectInView = rect
        isActiveAndVisible = active
        if changed {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isActiveAndVisible else { return }
        let positions = SelectionView.handlePositions(for: selectionRectInView)
        for (index, handle) in SelectionView.HandlePosition.allCases.enumerated() {
            let position = positions[index]
            let cursorRect = NSRect(
                x: position.x - handleHitSize / 2,
                y: position.y - handleHitSize / 2,
                width: handleHitSize,
                height: handleHitSize
            ).intersection(bounds)
            if !cursorRect.isNull {
                addCursorRect(
                    cursorRect,
                    cursor: SelectionView.cursorForHandle(handle)
                )
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActiveAndVisible else { return nil }
        // `point` is in the superview's coordinate space.
        let local = convert(point, from: superview)
        guard SelectionView.hitTestHandle(
            point: local,
            rect: selectionRectInView,
            hitSize: handleHitSize
        ) != nil else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = SelectionView.hitTestHandle(
            point: point,
            rect: selectionRectInView,
            hitSize: handleHitSize
        ) else { return }
        dragHandle = handle
        dragOriginalRect = selectionRectInView
        SelectionView.setCursorForHandle(handle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = dragHandle, let selectionView else { return }
        SelectionView.setCursorForHandle(handle)
        let point = convert(event.locationInWindow, from: nil)
        selectionView.resizeByExternalDrag(
            handle: handle,
            originalRect: dragOriginalRect,
            currentPoint: point
        )
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            dragHandle = nil
            updateCursor(at: point)
        }
        guard dragHandle != nil, let selectionView else { return }
        selectionView.finalizeExternalResize()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActiveAndVisible else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: NSPoint) {
        guard isActiveAndVisible else { return }
        if let handle = SelectionView.hitTestHandle(
            point: point,
            rect: selectionRectInView,
            hitSize: handleHitSize
        ) {
            SelectionView.setCursorForHandle(handle)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActiveAndVisible,
              selectionRectInView.width > 0,
              selectionRectInView.height > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let rect = selectionRectInView
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(borderWidth)
        context.setLineDash(phase: 0, lengths: dashPattern)
        context.stroke(rect.insetBy(dx: -1, dy: -1))
        context.setLineDash(phase: 0, lengths: [])

        for pos in SelectionView.handlePositions(for: rect) {
            let handleRect = NSRect(
                x: pos.x - handleSize / 2,
                y: pos.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            context.setFillColor(accentColor.cgColor)
            context.fillEllipse(in: handleRect)
        }

        // The SelectionView draws its own size label underneath, but the
        // editor image/beautify frame covers it. Re-draw it here, above the
        // frame, preserving the original-pixel label used by fixed images.
        SelectionView.drawSizeLabel(
            context: context,
            rect: rect,
            text: selectionView?.selectionSizeLabelOverride
        )
    }
}
