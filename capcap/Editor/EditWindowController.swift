import AppKit
import QuartzCore

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
    private var currentBeautifyPadding: CGFloat = CGFloat(Defaults.lastBeautifyPadding)
    private var currentBeautifyShadowEnabled: Bool = Defaults.lastBeautifyShadowEnabled

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
    private let overrideBaseImage: NSImage?

    /// Single-window capture with the WindowServer's real alpha silhouette.
    /// Used as the base image and annotation clip mask for clicked-window
    /// captures so the final corners match the system window exactly.
    private let windowBaseImage: NSImage?

    // Scroll capture state
    private var scrollCapturer: ScrollCapturer?
    private var isScrollCapturing = false
    private var scrollCaptureControlWindow: ScrollCaptureControlWindow?
    private var scrollPreviewWindow: ScrollPreviewWindow?
    /// Persistent "press any key to finish" hint shown inside the selection
    /// during auto-scroll. Excluded from the capture so it never appears in
    /// the stitched long screenshot.
    private var scrollCaptureHintWindow: ScrollCaptureHintWindow?
    private var autoScroller: AutoScroller?
    /// Backup monitor for key presses while capcap is deactivated for
    /// auto-scroll, so any key stops scrolling and moves on to crop mode.
    private var scrollCaptureKeyMonitor: Any?

    // Crop mode state — shown between scroll capture and the editor so the
    // user can trim any content auto-scroll over-shot.
    private var isCropping = false
    private var scrollCropView: ScrollCropView?
    private var scrollCropControlWindow: ScrollCropControlWindow?

    // Drawing properties
    private var currentColor: NSColor = .red
    private var currentLineWidth: CGFloat = 3.0
    private var currentMosaicBlockSize: CGFloat = 12.0
    private var currentFontSize: CGFloat = CGFloat(Defaults.lastTextFontSize)
    /// Whether new text annotations get a contrast outline.
    private var currentTextStroke: Bool = Defaults.lastTextStroke
    /// Whether new rectangle/ellipse annotations are filled.
    private var currentShapeFill: Bool = Defaults.lastShapeFill
    /// Marker keeps its own color/size slot so toggling between pen and
    /// marker preserves each tool's last-used choice.
    private var currentMarkerColor: NSColor = NSColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
    private var currentMarkerLineWidth: CGFloat = 4.0
    /// Last color sampled from the toolbar eyedropper. Persisted locally and
    /// shown as an ink-bottle control for color-capable annotation tools.
    private var pickedColorSwatch: NSColor?
    /// Active system eyedropper session. AppKit does not expose a direct
    /// cancel API, so teardown cancels it by posting Escape.
    private var activeColorSampler: NSColorSampler?

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
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.captureRect = captureRect
        self.screen = screen
        self.selectionRect = selectionRect
        self.selectionViewRect = selectionViewRect
        self.hostSelectionView = hostSelectionView
        self.preSnapshot = preSnapshot
        self.overrideBaseImage = overrideBaseImage
        self.windowBaseImage = windowBaseImage
        self.isWindowCapture = isWindowCapture
        self.onRecordingSelection = onRecordingSelection
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onComplete = onComplete
        self.pickedColorSwatch = Self.color(fromHex: Defaults.lastPickedColorHex)
    }

    func show() {
        guard let hostSelectionView else {
            onComplete(nil)
            requestFocusReturn()
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
        canvas.overrideBaseImage = overrideBaseImage
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

        let container = BeautifyContainerView(canvasView: canvas)
        container.autoresizingMask = []

        scrollView.documentView = container
        scrollView.editorCanvasView = canvas
        scrollView.isInteractionEnabled = false

        self.canvasScrollView = scrollView
        self.canvasView = canvas
        self.beautifyContainerView = container
        hostSelectionView.addSubview(scrollView)

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
        updateHistoryButtons(canUndo: canvas.canUndo, canRedo: canvas.canRedo)
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

        if overrideBaseImage != nil || onRecordingSelection == nil {
            toolbars.forEach { $0.setScrollCaptureEnabled(false) }
            toolbars.forEach { $0.setRecordingEnabled(false) }
        }
    }

    /// Injects the controller's action callbacks into a toolbar. Both the
    /// primary and the side toolbar share the same wiring — a tool behaves
    /// identically regardless of which bar it was dragged to.
    private func wireToolbarCallbacks(_ tv: ToolbarView) {
        tv.onToolSelected = { [weak self] tool in self?.selectTool(tool) }
        tv.onUndo = { [weak self] in _ = self?.canvasView?.undo() }
        tv.onRedo = { [weak self] in _ = self?.canvasView?.redo() }
        tv.onColorPicker = { [weak self] in self?.runColorPicker() }
        tv.onScrollCapture = { [weak self] in self?.toggleScrollCapture() }
        tv.onBeautify = { [weak self] in self?.toggleBeautify() }
        tv.onOCR = { [weak self] in self?.performOCR() }
        tv.onScreenshotTranslate = { [weak self] in self?.performScreenshotTranslation() }
        tv.onSave = { [weak self] in self?.save() }
        tv.onUpload = { [weak self] in self?.upload() }
        tv.onPin = { [weak self] in self?.pin() }
        tv.onRecord = { [weak self] in self?.record() }
        tv.onClose = { [weak self] in self?.close() }
        tv.onConfirm = { [weak self] in self?.confirm() }
        tv.onMoveSelectionStart = { [weak self] in self?.handleMoveSelectionStart() }
        tv.onMoveSelectionDrag = { [weak self] delta in self?.handleMoveSelectionDrag(delta: delta) }
        tv.onMoveSelectionEnd = { [weak self] in self?.handleMoveSelectionEnd() }
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

    /// Frame the option sub-toolbars (color/size, text, beautify) anchor
    /// against — the primary toolbar when it exists, otherwise the side
    /// toolbar, so options still appear if the user emptied the primary bar.
    private var subToolbarAnchorFrame: NSRect? {
        toolbarView?.frame ?? sideToolbarView?.frame
    }

    func updateLayout(selectionRect: NSRect, selectionViewRect: NSRect, captureRect: CGRect) {
        self.selectionRect = selectionRect
        self.selectionViewRect = selectionViewRect
        self.captureRect = captureRect

        if !isWindowCapture {
            canvasView?.windowBaseImage = nil
        }

        canvasView?.updateViewportSize(selectionViewRect.size)
        beautifyContainerView?.canvasSizeDidChange()
        canvasView?.captureRect = captureRect
        canvasView?.captureScreen = screen

        if isBeautifyActive {
            canvasView?.beautifyCornerRadius = isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius
            beautifyContainerView?.setInnerShadowCornerRadius(
                isWindowCapture ? WindowEffects.cornerRadiusPoints : BeautifyRenderer.innerCornerRadius
            )
            beautifyContainerView?.setInnerShadowInset(
                isWindowCapture ? BeautifyRenderer.windowInnerShadowInset : 0
            )
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

        repositionFloatingChrome()
    }

    private func selectTool(_ tool: EditTool) {
        // Beautify stays active — tools and beautify coexist so the user
        // can draw on top of the beautified live preview.

        if tool != .none {
            canvasView?.clearMultiSelection()
        }
        activeTool = tool
        canvasView?.activeTool = tool
        canvasView?.currentColor = currentColor
        canvasView?.currentLineWidth = currentLineWidth
        canvasView?.currentMosaicBlockSize = currentMosaicBlockSize
        canvasView?.currentFontSize = currentFontSize
        canvasView?.currentShapeFill = currentShapeFill
        toolbars.forEach { $0.updateSelection(tool: tool) }
        updateEditorInteractionState()

        // Marker has its own color/size slot so it doesn't fight the pen
        // when the user toggles between them. Push current values down so
        // the canvas reflects the toolbar selection.
        canvasView?.currentMarkerColor = currentMarkerColor
        canvasView?.currentMarkerLineWidth = currentMarkerLineWidth

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

        if activeTool != tool {
            // selectTool rebuilds the sub-toolbar; the seeded values flow in.
            selectTool(tool)
        } else {
            // Same tool — rebuild the sub-toolbar to refresh displayed values.
            showSubToolbar(for: tool)
        }
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
        case is NumberAnnotation: return .numbered
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
            currentTextStroke = t.hasStroke
        case let p as PenAnnotation:
            currentColor = p.color
            currentLineWidth = p.lineWidth
        case let m as MarkerAnnotation:
            currentMarkerColor = m.color
            currentMarkerLineWidth = m.lineWidth
        case let r as RectAnnotation:
            currentColor = r.color
            currentLineWidth = r.lineWidth
            currentShapeFill = r.filled
        case let e as EllipseAnnotation:
            currentColor = e.color
            currentLineWidth = e.lineWidth
            currentShapeFill = e.filled
        case let a as ArrowAnnotation:
            currentColor = a.color
            currentLineWidth = a.lineWidth
        case let l as LineAnnotation:
            currentColor = l.color
            currentLineWidth = l.lineWidth
        case let n as NumberAnnotation:
            currentColor = n.color
        default:
            break
        }
    }

    private func showSubToolbar(for tool: EditTool) {
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil

        switch tool {
        case .pen, .arrow, .line:
            showColorSizeSubToolbar(
                sizes: [2, 4, 6],
                dynamicColor: pickedColorSwatch,
                currentSize: currentLineWidth,
                onSize: { [weak self] size in
                    self?.currentLineWidth = size
                    self?.canvasView?.currentLineWidth = size
                }
            )
        case .rectangle, .ellipse:
            showColorSizeSubToolbar(
                sizes: [2, 4, 6],
                dynamicColor: pickedColorSwatch,
                currentSize: currentLineWidth,
                width: ColorSizeSubToolbar.preferredWidth(
                    sizes: [2, 4, 6],
                    dynamicColor: pickedColorSwatch,
                    showsFillCheckbox: true
                ),
                onSize: { [weak self] size in
                    self?.currentLineWidth = size
                    self?.canvasView?.currentLineWidth = size
                },
                fillEnabled: currentShapeFill,
                onFill: { [weak self] enabled in
                    self?.setShapeFillEnabled(enabled)
                }
            )
        case .marker:
            showColorSizeSubToolbar(
                sizes: [3, 5, 8],
                currentColor: currentMarkerColor,
                dynamicColor: pickedColorSwatch,
                currentSize: currentMarkerLineWidth,
                onColor: { [weak self] color in
                    self?.currentMarkerColor = color
                    self?.canvasView?.currentMarkerColor = color
                },
                onSize: { [weak self] size in
                    self?.currentMarkerLineWidth = size
                    self?.canvasView?.currentMarkerLineWidth = size
                }
            )
        case .text:
            showTextSubToolbar()
        case .numbered:
            showColorSizeSubToolbar(
                sizes: [],
                dynamicColor: pickedColorSwatch,
                currentSize: 0,
                width: pickedColorSwatch == nil ? 200 : 225
            )
        case .mosaic, .eraser:
            // These tools have no sub-toolbar — drag a rectangle on canvas.
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
        width: CGFloat = 300,
        onColor: ((NSColor) -> Void)? = nil,
        onSize: ((CGFloat) -> Void)? = nil,
        fillEnabled: Bool? = nil,
        onFill: ((Bool) -> Void)? = nil
    ) {
        guard let hostSelectionView, let toolbarFrame = subToolbarAnchorFrame else { return }
        let offset: CGFloat = isBeautifyActive ? (36 + 4) : 0
        let subRect = subToolbarRect(
            width: width,
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
            fillEnabled: fillEnabled
        )
        view.onColorChanged = { [weak self] color in
            if let onColor {
                onColor(color)
            } else {
                self?.currentColor = color
                self?.canvasView?.currentColor = color
            }
            // Push the same color onto whatever annotation is currently
            // selected. With no selection this is a no-op, so the call is
            // safe to make from every tool's color path.
            self?.canvasView?.mutateSelectedAnnotationAtomic { $0.withColor(color) }
        }
        view.onSizeChanged = { [weak self] size in
            onSize?(size)
            self?.canvasView?.mutateSelectedAnnotationAtomic { $0.withLineWidth(size) }
        }
        view.onFillChanged = onFill
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
            dynamicColor: pickedColorSwatch,
            strokeEnabled: currentTextStroke
        )
        view.onColorChanged = { [weak self] color in
            self?.currentColor = color
            self?.canvasView?.currentColor = color
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
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        subToolbarView = view
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
    /// beautify toggles, preset/padding changes, or the user resizes the
    /// selection.
    private func repositionFloatingChrome() {
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
        selectionChromeOverlay?.update(
            rect: selectionViewRect,
            active: isBeautifyActive && canvasView?.hasPreviewImage != true
        )
    }

    // MARK: - Move-selection drag handle

    /// Original selection rect captured at the moment the user pressed the
    /// move-selection drag handle. Per-frame deltas are applied against
    /// this so the rect doesn't drift if a frame is missed.
    private var moveSelectionStartRect: NSRect = .zero

    private func handleMoveSelectionStart() {
        canvasView?.commitActiveTextEditing()
        moveSelectionStartRect = hostSelectionView?.currentSelectionRect ?? .zero
    }

    private func handleMoveSelectionDrag(delta: CGSize) {
        hostSelectionView?.moveByExternalDrag(
            deltaFromOriginal: delta,
            originalRect: moveSelectionStartRect
        )
    }

    private func handleMoveSelectionEnd() {
        hostSelectionView?.finalizeExternalDrag()
        moveSelectionStartRect = .zero
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
        guard let canvasView, let container = beautifyContainerView else {
            return
        }
        let preset = BeautifyPreset.defaultPreset

        // Beautify and annotation tools coexist — don't clear the active tool.

        // The canvas draws its content (previewImage or externalBaseImage)
        // inside the beautify card. Normal selections use a fixed card clip;
        // clicked-window captures use the window's own rounded alpha mask.
        canvasView.beautifyCornerRadius = isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius
        container.setInnerShadowCornerRadius(
            isWindowCapture ? WindowEffects.cornerRadiusPoints : BeautifyRenderer.innerCornerRadius
        )
        container.setInnerShadowInset(
            isWindowCapture ? BeautifyRenderer.windowInnerShadowInset : 0
        )
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
        container.setPadding(currentBeautifyPadding)
        container.setShadowEnabled(currentBeautifyShadowEnabled)
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
        currentBeautifyPreset = nil

        canvasView.beautifyCornerRadius = nil
        canvasView.externalBaseImage = nil

        container.setBeautify(preset: nil)
        container.setPadding(nil)
        container.setInnerShadowCornerRadius(BeautifyRenderer.innerCornerRadius)
        container.setInnerShadowInset(0)
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

    private func applyBeautifyPadding(_ padding: CGFloat) {
        currentBeautifyPadding = padding
        Defaults.lastBeautifyPadding = Double(padding)
        beautifyContainerView?.setPadding(padding)
        updateCanvasFrameForBeautify()
        repositionFloatingChrome()
        canvasView?.needsDisplay = true
    }

    private func applyBeautifyShadowEnabled(_ enabled: Bool) {
        currentBeautifyShadowEnabled = enabled
        Defaults.lastBeautifyShadowEnabled = enabled
        beautifyContainerView?.setShadowEnabled(enabled)
        canvasView?.needsDisplay = true
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

        beautifySubToolbarView?.removeFromSuperview()

        let width = BeautifySubToolbar.preferredWidth(presetCount: BeautifyPreset.defaults.count)
        let height: CGFloat = 36
        let subRect = subToolbarRect(
            width: width,
            height: height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds
        )

        let view = BeautifySubToolbar(
            frame: subRect,
            presets: BeautifyPreset.defaults,
            screen: screen,
            initialPadding: currentBeautifyPadding,
            initialShadowEnabled: currentBeautifyShadowEnabled
        )
        view.currentPresetID = preset.id
        view.onPresetSelected = { [weak self] selected in
            self?.applyBeautifyPreset(selected)
        }
        view.onPaddingChanged = { [weak self] padding in
            self?.applyBeautifyPadding(padding)
        }
        view.onShadowEnabledChanged = { [weak self] enabled in
            self?.applyBeautifyShadowEnabled(enabled)
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
        else {
            return
        }

        if isBeautifyActive {
            canvasScrollView.frame = outerVisualRect(in: hostSelectionView.bounds)
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
        let p = container.customPadding ?? BeautifyRenderer.padding(for: container.innerImageSize)
        return NSRect(
            x: selectionViewRect.minX - p,
            y: selectionViewRect.minY - p,
            width: outer.width,
            height: outer.height
        )
    }

    // MARK: - Scroll Capture

    private func toggleScrollCapture() {
        // Scroll capture only makes sense for live screen content; in
        // image-edit mode there's nothing to scroll.
        if overrideBaseImage != nil { return }
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

        // Scroll capture is fully automatic — without Accessibility access
        // capcap cannot post scroll events, so there is nothing to capture.
        guard AutoScroller.isPermitted else {
            AutoScroller.requestPermission()
            ToastWindow.show(message: L10n.autoScrollPermissionNeeded, on: screen)
            return
        }

        isScrollCapturing = true
        activeTool = .none
        canvasView?.activeTool = .none
        toolbars.forEach { $0.updateSelection(tool: .none) }
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        toolbars.forEach { $0.setScrollCaptureActive(true) }
        hostSelectionView?.scrollCaptureActive = true
        updateEditorInteractionState()
        // The first SCK capture runs synchronously on the main thread inside
        // ScrollCapturer.init, blocking the run loop on a semaphore. Without
        // forcing the view to redraw + commit here, the window backing store
        // still shows the pre-scroll-capture chrome (green dashed border and
        // corner handles), which would appear baked into the first frame and
        // get carried into the stitched output.
        hostSelectionView?.display()
        CATransaction.flush()

        // Show the persistent hint inside the selection *before* the capturer
        // takes its first (synchronous) frame, then exclude its window from the
        // capture so it never bleeds into the stitched long screenshot.
        let hintWindow = ScrollCaptureHintWindow()
        hintWindow.present(in: selectionRect)
        scrollCaptureHintWindow = hintWindow

        let capturer = ScrollCapturer(
            rect: captureRect,
            screen: screen,
            excludingWindowNumbers: [CGWindowID(max(0, hintWindow.windowNumber))]
        )
        capturer.onPreviewUpdated = { [weak self] image in
            self?.updateScrollPreview(image)
        }
        scrollCapturer = capturer
        installScrollCaptureKeyMonitor()
        showScrollCaptureControl()
        toolbars.forEach { $0.isHidden = true }
        // The overlay stays click-through so capcap's synthetic auto-scroll
        // events reach the page underneath. The user's own trackpad / wheel
        // and click input over the selection is dropped by AutoScroller's
        // event tap, which tells synthetic events apart from manual ones.
        hostSelectionView?.window?.ignoresMouseEvents = true
        NSApp.deactivate()
        startAutoScroll(capturer: capturer)
    }

    /// Runs constant-speed automatic scrolling over the capture region. The
    /// cursor is left unconstrained so the user can reach the stop button;
    /// the synthetic scroll events are aimed at the region by event location.
    private func startAutoScroll(capturer: ScrollCapturer) {
        // Scroll ~15% of the capture height per step. Smaller steps give
        // ~85% inter-frame overlap, which keeps the Vision-based
        // translational image registration well inside its reliable range
        // even on pages with repetitive content or imperfectly-detected
        // sticky elements. Larger steps caused visible content skips in
        // testing.
        let stepPoints = max(60, min(180, selectionRect.height * 0.15))
        let center = CGPoint(x: captureRect.midX, y: captureRect.midY)

        let scroller = AutoScroller(
            centerPoint: center,
            blockingRect: captureRect,
            stepPixels: Int(stepPoints),
            onKeyPressed: { [weak self] in
                guard let self, self.isScrollCapturing else { return }
                self.stopScrollCapture()
            }
        )
        autoScroller = scroller
        scroller.start(
            captureStep: {
                switch capturer.captureSynchronously(expectedShiftPoints: stepPoints) {
                case .appended: return .progressed
                case .noNewContent: return .stalled
                case .atFrameLimit: return .finished
                }
            },
            onFinished: { [weak self] in
                guard let self, self.isScrollCapturing else { return }
                self.stopScrollCapture()
            }
        )
    }

    private func stopScrollCapture() {
        isScrollCapturing = false
        autoScroller?.stop()
        autoScroller = nil
        removeScrollCaptureKeyMonitor()
        scrollCaptureControlWindow?.dismiss()
        scrollCaptureControlWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        scrollCaptureHintWindow?.dismiss()
        scrollCaptureHintWindow = nil
        hostSelectionView?.window?.ignoresMouseEvents = false
        hostSelectionView?.scrollCaptureActive = false
        hostSelectionView?.needsDisplay = true
        toolbars.forEach { $0.setScrollCaptureActive(false) }

        guard let stitchedImage = scrollCapturer?.stopAndStitch() else {
            scrollCapturer = nil
            toolbars.forEach { $0.isHidden = false }
            updateEditorInteractionState()
            bringEditorToFront()
            return
        }
        scrollCapturer = nil

        // Auto-scroll often over-shoots the end of a page, so route the
        // stitched result through crop mode before handing it to the editor.
        enterCropMode(with: stitchedImage)
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
        canvasView?.loadPreviewImage(image)
        beautifyContainerView?.canvasSizeDidChange()
        canvasScrollView?.scrollToTop()
        toolbars.forEach { $0.isHidden = false }
        updateEditorInteractionState()
        bringEditorToFront()
    }

    private func confirmCrop() {
        guard isCropping, let cropView = scrollCropView else {
            exitCropMode()
            return
        }

        let cropped = cropView.croppedImage()
        exitCropMode()
        canvasView?.loadPreviewImage(cropped)
        beautifyContainerView?.canvasSizeDidChange()
        canvasScrollView?.scrollToTop()
        updateEditorInteractionState()
        ToastWindow.show(message: L10n.mergedLongScreenshot, on: screen)
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
        canvasView?.commitActiveTextEditing()
        guard let finalImage = currentCompositeImage() else { return }

        tearDown()
        onComplete(nil)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = defaultImageSaveFilename()

        if savePanel.runModal() == .OK, let url = savePanel.url {
            if let pngData = finalImage.pngDataPreservingBacking() {
                try? pngData.write(to: url)
            }
        }
        requestFocusReturn()
    }

    private func defaultImageSaveFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "capcap-\(formatter.string(from: date)).png"
    }

    private func upload() {
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
        canvasView?.commitActiveTextEditing()
        let baseImage = canvasView?.resolveBaseImageForEditing() ?? currentCompositeImage()
        let anchorRect = selectionRect
        let targetScreen = screen
        tearDown()
        onComplete(nil)
        guard let baseImage else { return }
        OCRTranslatePanel.presentTextRecognition(image: baseImage, anchorRect: anchorRect, screen: targetScreen)
    }

    /// Screenshot-translation action: uses OCR internally, but only shows the
    /// translated result to the user.
    private func performScreenshotTranslation() {
        canvasView?.commitActiveTextEditing()
        let baseImage = canvasView?.resolveBaseImageForEditing() ?? currentCompositeImage()
        let anchorRect = selectionRect
        let targetScreen = screen
        tearDown()
        onComplete(nil)
        guard let baseImage else { return }
        OCRTranslatePanel.presentScreenshotTranslation(image: baseImage, anchorRect: anchorRect, screen: targetScreen)
    }

    private func pin() {
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

    private func setShapeFillEnabled(_ enabled: Bool) {
        currentShapeFill = enabled
        canvasView?.currentShapeFill = enabled
        Defaults.lastShapeFill = enabled
        canvasView?.mutateSelectedAnnotationAtomic { $0.withFill(enabled) }
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

    /// Trigger the system color sampler (loupe). The picked color's hex is
    /// copied to the clipboard and the color becomes the toolbar ink-bottle
    /// color for color-capable tools. It does not directly change the active
    /// tool color.
    private func runColorPicker() {
        canvasView?.commitActiveTextEditing()
        guard activeColorSampler == nil else { return }
        let sampler = NSColorSampler()
        activeColorSampler = sampler
        sampler.show { [weak self, weak sampler] picked in
            guard let self, self.activeColorSampler === sampler else { return }
            self.activeColorSampler = nil
            guard let picked else { return }
            let rgb = picked.usingColorSpace(.sRGB) ?? picked
            let r = Int(round(max(0, min(1, rgb.redComponent)) * 255))
            let g = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
            let b = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            let swatchColor = NSColor(
                srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)

            HistoryManager.shared.addColor(hex: hex)
            Defaults.lastPickedColorHex = hex
            self.pickedColorSwatch = swatchColor
            if self.toolUsesPickedColorSwatch(self.activeTool) {
                self.showSubToolbar(for: self.activeTool)
            }
            ToastWindow.show(message: L10n.colorCopied(hex), on: self.screen)
        }
    }

    private func cancelActiveColorSampler() {
        guard activeColorSampler != nil else { return }
        activeColorSampler = nil
        Self.postEscapeKeyEvent()
    }

    private static func postEscapeKeyEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let escapeKeyCode = CGKeyCode(53)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func confirmFromKeyboard() {
        // The clipboard hotkey during auto-scroll stops scrolling and moves to
        // crop mode; during crop mode it confirms the crop. It must not copy to
        // the clipboard until the user is actually in the editor.
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

    /// Save-to-file (⌘S) entry point — mirrors `confirmFromKeyboard`'s phased
    /// behavior so the hotkey works regardless of which stage the editor is in.
    func saveFromKeyboard() {
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

    func undoFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCapturing, !isCropping else { return false }
        return canvasView?.undoFromKeyboard(for: event) ?? false
    }

    func redoFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCapturing, !isCropping else { return false }
        return canvasView?.redoFromKeyboard(for: event) ?? false
    }

    func handleAnnotationClipboardShortcutFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCapturing, !isCropping else { return false }
        return canvasView?.handleAnnotationClipboardShortcutFromKeyboard(for: event) ?? false
    }

    func nudgeSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCapturing, !isCropping else { return false }
        return canvasView?.nudgeSelectedAnnotationFromKeyboard(for: event) ?? false
    }

    func deleteSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCapturing, !isCropping else { return false }
        return canvasView?.deleteSelectedAnnotationFromKeyboard(for: event) ?? false
    }

    func handleEditorShortcutFromKeyboard(for event: NSEvent) -> Bool {
        guard !isScrollCapturing, !isCropping else { return false }
        guard let shortcut = EditorKeyboardShortcut(event: event) else { return false }

        switch shortcut {
        case .select:
            selectTool(.none)
        case .tool(let tool):
            selectTool(tool)
        case .fill:
            return toggleShapeFillFromKeyboard()
        case .pin:
            pin()
        case .close:
            close()
        }
        return true
    }

    private func toggleShapeFillFromKeyboard() -> Bool {
        guard activeTool == .rectangle || activeTool == .ellipse else { return false }
        setShapeFillEnabled(!currentShapeFill)
        showSubToolbar(for: activeTool)
        return true
    }

    private func confirm() {
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
        cancelActiveColorSampler()
        isScrollCapturing = false
        autoScroller?.stop()
        autoScroller = nil
        removeScrollCaptureKeyMonitor()
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
        canvasView = nil
        selectionChromeOverlay?.removeFromSuperview()
        selectionChromeOverlay = nil
        hostSelectionView?.annotationToolActive = false
        hostSelectionView?.selectionInteractionEnabled = true
        hostSelectionView?.scrollCaptureActive = false
        toolbars.forEach { $0.isHidden = false; $0.removeFromSuperview() }
        toolbarView = nil
        sideToolbarView = nil
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
        var fallbackBaseImage: NSImage?
        if canvasView?.hasPreviewImage == true {
            fallbackBaseImage = nil
        } else if let overrideBaseImage {
            fallbackBaseImage = overrideBaseImage
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
            beautifyPadding: isBeautifyActive ? currentBeautifyPadding : nil,
            beautifyShadowEnabled: isBeautifyActive ? currentBeautifyShadowEnabled : true,
            wallpaperImage: isBeautifyActive ? beautifyContainerView?.wallpaperImage : nil,
            annotationClipMask: annotationClipMask,
            beautifyInnerClipRadius: isBeautifyActive && isWindowCapture ? nil : BeautifyRenderer.innerCornerRadius,
            beautifyInnerShadowCornerRadius: isBeautifyActive && isWindowCapture
                ? WindowEffects.cornerRadiusPoints
                : BeautifyRenderer.innerCornerRadius,
            beautifyInnerShadowInset: isBeautifyActive && isWindowCapture
                ? BeautifyRenderer.windowInnerShadowInset
                : 0
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

    private func windowShapedBaseImage(from image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        guard isWindowCapture, canvasView?.hasPreviewImage != true else { return image }
        return windowBaseImage ?? WindowEffects.roundedCorners(image)
    }

    /// While auto-scroll runs capcap is deactivated, so a local key monitor
    /// would not fire. The event tap in `AutoScroller` is the primary path;
    /// this global monitor is a fallback if the tap could not be installed.
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
        if scrollPreviewWindow == nil {
            scrollPreviewWindow = ScrollPreviewWindow()
        }
        scrollPreviewWindow?.updatePreview(image, anchorRect: selectionRect)
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
        // Once the editor is up, the canvas owns clicks inside the selection
        // rect for the entire session — drawing tools, adjust-mode handles,
        // and dragging existing annotations all go through it. The legacy
        // "click inside the selection moves the whole rect" gesture has
        // moved to a dedicated toolbar handle so adjust-mode clicks on
        // empty canvas don't get hijacked.
        hostSelectionView?.annotationToolActive = !isScrollCapturing
        // When beautify is on, handle hits go through `selectionChromeOverlay`
        // (which sits above the canvas); the SelectionView itself stays
        // available for any clicks that fall outside the gradient frame so the
        // user can still adjust the selection.
        hostSelectionView?.selectionInteractionEnabled = !(isScrollCapturing || hasPreview)
        canvasScrollView?.isInteractionEnabled = (activeTool != .none) || hasPreview || isBeautifyActive
        hostSelectionView?.needsDisplay = true
    }

    private func toolbarRect(in bounds: NSRect, size: NSSize) -> NSRect {
        let width = size.width
        let height = size.height
        let margin: CGFloat = 8

        let referenceRect = outerVisualRect(in: bounds)
        let x = clampedX(
            referenceRect.midX - width / 2,
            width: width,
            in: bounds,
            margin: margin
        )
        var y = referenceRect.minY - height - margin
        if y < margin {
            y = min(referenceRect.maxY + margin, bounds.maxY - height - margin)
        }
        y = max(margin, min(bounds.maxY - height - margin, y))

        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Frame for the vertical side toolbar. Prefers the right of the
    /// selection, flips to the left when there's no room, and stays
    /// vertically centered on the selection.
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
        let width = size.width
        let height = size.height
        let margin: CGFloat = 8

        let referenceRect = outerVisualRect(in: bounds)
        var x = referenceRect.maxX + margin
        if x + width > bounds.maxX - margin {
            x = referenceRect.minX - width - margin
        }
        x = max(margin, min(bounds.maxX - width - margin, x))

        var y = referenceRect.midY - height / 2
        y = max(margin, min(bounds.maxY - height - margin, y))

        var rect = NSRect(x: x, y: y, width: width, height: height)

        if let primary = primaryFrame, rect.intersects(primary) {
            // Try to sit fully above the primary toolbar's band; fall back
            // to below it when there isn't enough headroom.
            let above = primary.maxY + margin
            if above + height <= bounds.maxY - margin {
                rect.origin.y = above
            } else {
                rect.origin.y = max(margin, primary.minY - margin - height)
            }
        }

        return rect
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

private enum EditorKeyboardShortcut {
    case select
    case tool(EditTool)
    case fill
    case pin
    case close

    init?(event: NSEvent) {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return nil }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
            return nil
        }

        switch key {
        case "v": self = .select
        case "r": self = .tool(.rectangle)
        case "o": self = .tool(.ellipse)
        case "l": self = .tool(.line)
        case "a": self = .tool(.arrow)
        case "d": self = .tool(.pen)
        case "h": self = .tool(.marker)
        case "m": self = .tool(.mosaic)
        case "e": self = .tool(.eraser)
        case "f": self = .fill
        case "t": self = .tool(.text)
        case "n": self = .tool(.numbered)
        case "p": self = .pin
        case "x": self = .close
        default: return nil
        }
    }
}

// MARK: - Main Toolbar View

let accentGreen = NSColor(red: 0, green: 212.0/255.0, blue: 106.0/255.0, alpha: 1.0)

private final class EditorScrollView: NSScrollView {
    weak var editorCanvasView: EditCanvasView?
    /// When `true`, every viewport click is captured (drawing tools, long
    /// screenshot preview, beautify chrome). When `false` the scroll view
    /// only forwards clicks that the canvas itself claimed, so empty
    /// viewport clicks fall through to the SelectionView underneath where
    /// its resize handles live.
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
    static let buttonSize: CGFloat = 32
    static let buttonSpacing: CGFloat = 6
    /// Inset along the main axis at both ends of the run.
    static let endPadding: CGFloat = 15
    /// Inset on the cross axis — keeps a 44pt-thick capsule around 32pt buttons.
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

    var onToolSelected: ((EditTool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onColorPicker: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onBeautify: (() -> Void)?
    var onOCR: (() -> Void)?
    var onScreenshotTranslate: (() -> Void)?
    var onSave: (() -> Void)?
    var onUpload: (() -> Void)?
    var onPin: (() -> Void)?
    var onRecord: (() -> Void)?
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?
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
    /// Last tool the controller selected. Tracked so a second click on the
    /// already-selected tool button toggles back to "no tool" (adjust mode).
    private var currentTool: EditTool = .none

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
        currentTool = tool
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
            selectedColor: id.selectedColor
        )
        btn.hoverTip = id.tooltip
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
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }

    @objc private func buttonTapped(_ sender: ToolButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        let id = items[sender.tag]
        switch id {
        case .rectangle, .ellipse, .arrow, .line, .pen, .marker, .mosaic, .eraser, .magnifier, .numbered, .text:
            guard let tool = id.editTool else { return }
            // Click an already-selected tool to deselect it and enter adjust
            // mode (no tool, but existing marks remain draggable).
            onToolSelected?(tool == currentTool ? .none : tool)
        case .colorPicker:   onColorPicker?()
        case .undo:          onUndo?()
        case .redo:          onRedo?()
        case .scrollCapture: onScrollCapture?()
        case .beautify:      onBeautify?()
        case .ocr:           onOCR?()
        case .screenshotTranslate: onScreenshotTranslate?()
        case .save:          onSave?()
        case .upload:        onUpload?()
        case .pin:           onPin?()
        case .record:        onRecord?()
        case .close:         onClose?()
        case .confirm:       onConfirm?()
        case .moveSelection: break  // handled by MoveSelectionDragHandle
        }
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
            NSColor.white.withAlphaComponent(0.15).setFill()
            bgPath.fill()
        } else {
            contentTintColor = normalColor
        }
        super.draw(dirtyRect)
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
            NSColor.white.withAlphaComponent(0.15).setFill()
            bg.fill()
        }

        let symbolName = "arrow.up.and.down.and.arrow.left.and.right"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let img = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Move selection"
        )?.withSymbolConfiguration(config) else { return }

        let tint = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.set()
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

    init() {
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

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 8

        label.stringValue = L10n.scrollCaptureHint
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        container.addSubview(label)
        contentView = container
    }

    /// Size to the text and place top-center inside `selectionRect`
    /// (AppKit screen coordinates).
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
    var currentSize: CGFloat = 3.0
    var fillEnabled: Bool = false
    var onColorChanged: ((NSColor) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?
    var onFillChanged: ((Bool) -> Void)?

    private var sizeButtons: [NSView] = []
    private var colorButtons: [NSView] = []
    private var fillCheckbox: HUDCheckboxButton?

    private let sizes: [CGFloat]
    private let dynamicColor: NSColor?
    private let showsFillCheckbox: Bool
    private let baseColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),   // Red
        NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),    // Blue
        NSColor(red: 0.0, green: 0.83, blue: 0.42, alpha: 1.0),   // Green
        NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),     // Yellow
        NSColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 1.0), // #D77757
        .white,
        NSColor(white: 0.5, alpha: 1.0),                           // Gray
        .black,
    ]
    private var colors: [NSColor] {
        guard let dynamicColor else { return baseColors }
        return baseColors + [dynamicColor]
    }

    private static let leadingPad: CGFloat = 12
    private static let swatchSize: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let separatorGap: CGFloat = 6
    private static let checkboxGap: CGFloat = 8
    private static let trailingPad: CGFloat = 12
    private static let baseColorCount: CGFloat = 8

    private static func fillCheckboxWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((L10n.shapeFillEffect as NSString).size(withAttributes: [.font: font]).width)
        return 16 + 8 + textWidth
    }

    static func preferredWidth(
        sizes: [CGFloat],
        dynamicColor: NSColor?,
        showsFillCheckbox: Bool
    ) -> CGFloat {
        var x = leadingPad
        for i in sizes.indices {
            x += 6 + CGFloat(i) * 4 + 10
        }
        if !sizes.isEmpty {
            x += 8 + 1 + 9
        }

        let colorCount = baseColorCount + (dynamicColor == nil ? 0.0 : 1.0)
        x += colorCount * swatchSize + max(colorCount - 1, 0) * swatchGap

        if showsFillCheckbox {
            x += separatorGap + 1 + checkboxGap + fillCheckboxWidth()
        }

        return ceil(x + trailingPad)
    }

    init(
        frame: NSRect,
        sizes: [CGFloat] = [2, 4, 6],
        currentColor: NSColor = .red,
        dynamicColor: NSColor? = nil,
        currentSize: CGFloat = 3.0,
        fillEnabled: Bool? = nil
    ) {
        self.sizes = sizes
        self.currentColor = currentColor
        self.dynamicColor = dynamicColor
        self.currentSize = currentSize
        self.fillEnabled = fillEnabled ?? false
        self.showsFillCheckbox = fillEnabled != nil
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
                isSelected: abs(currentSize - size) < 0.5
            )
            dot.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(sizeTapped(_:)))
            dot.addGestureRecognizer(click)
            addSubview(dot)
            sizeButtons.append(dot)
            x += dotSize + 10
        }

        // Separator only when there's a size section to separate from.
        if !sizes.isEmpty {
            x += 8
            let sep = NSView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
            addSubview(sep)
            x += 9
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

        if showsFillCheckbox {
            let lastSwatchRightEdge = x - ColorSizeSubToolbar.swatchGap
            let fillSepX = lastSwatchRightEdge + ColorSizeSubToolbar.separatorGap
            let fillSep = NSView(frame: NSRect(x: fillSepX, y: 6, width: 1, height: bounds.height - 12))
            fillSep.wantsLayer = true
            fillSep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
            addSubview(fillSep)

            let checkboxHeight: CGFloat = 20
            let checkbox = HUDCheckboxButton(
                frame: NSRect(
                    x: fillSepX + 1 + ColorSizeSubToolbar.checkboxGap,
                    y: midY - checkboxHeight / 2,
                    width: ColorSizeSubToolbar.fillCheckboxWidth(),
                    height: checkboxHeight
                ),
                title: L10n.shapeFillEffect,
                target: self,
                action: #selector(fillCheckboxChanged(_:))
            )
            checkbox.state = fillEnabled ? .on : .off
            checkbox.toolTip = "\(L10n.shapeFillEffect) (F)"
            addSubview(checkbox)
            fillCheckbox = checkbox
        }
    }

    @objc private func sizeTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? SizeDotView else { return }
        let index = view.itemIndex
        guard index < sizes.count else { return }
        currentSize = sizes[index]
        onSizeChanged?(currentSize)
        updateSizeSelection()
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

    @objc private func fillCheckboxChanged(_ sender: HUDCheckboxButton) {
        fillEnabled = sender.state == .on
        onFillChanged?(fillEnabled)
    }

    private func updateSizeSelection() {
        for (i, view) in sizeButtons.enumerated() {
            (view as? SizeDotView)?.isSelected = abs(currentSize - sizes[i]) < 0.5
        }
    }

    private func updateColorSelection() {
        let paletteColors = colors
        for (i, view) in colorButtons.enumerated() where i < paletteColors.count {
            (view as? ColorSwatchView)?.isSelected = colorsMatch(paletteColors[i], currentColor)
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

// MARK: - Text Sub-toolbar

/// Text-tool sub-toolbar — color swatches plus a 10–100 font-size slider.
/// Replaces the discrete size dots used by other tools because text scales
/// over a wide range and a slider is the natural fit.
private class TextSubToolbar: NSView {
    var currentColor: NSColor = .red
    var currentFontSize: CGFloat = CGFloat(Defaults.lastTextFontSize)
    var strokeEnabled: Bool = false
    var onColorChanged: ((NSColor) -> Void)?
    /// Fired when the user grabs the slider thumb (mouseDown phase).
    var onFontSizeBegan: (() -> Void)?
    /// Fired on every slider tick during a drag.
    var onFontSizeChanged: ((CGFloat) -> Void)?
    /// Fired when the user releases the slider (mouseUp phase).
    var onFontSizeEnded: (() -> Void)?
    /// Fired when the outline checkbox is toggled.
    var onStrokeChanged: ((Bool) -> Void)?

    private var colorButtons: [NSView] = []
    private var slider: NSSlider!
    private var sizeLabel: NSTextField!
    private var strokeCheckbox: HUDCheckboxButton!

    private let dynamicColor: NSColor?
    private let baseColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),   // Red
        NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),    // Blue
        NSColor(red: 0.0, green: 0.83, blue: 0.42, alpha: 1.0),   // Green
        NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),     // Yellow
        NSColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 1.0), // #D77757
        .white,
        NSColor(white: 0.5, alpha: 1.0),                           // Gray
        .black,
    ]
    private var colors: [NSColor] {
        guard let dynamicColor else { return baseColors }
        return baseColors + [dynamicColor]
    }

    // Layout metrics, shared between `setup()` and `preferredWidth` so the
    // view is always wide enough for everything it lays out.
    private static let leadingPad: CGFloat = 12
    private static let labelWidth: CGFloat = 28
    private static let sliderWidth: CGFloat = 130
    private static let swatchSize: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let separatorGap: CGFloat = 6
    private static let checkboxGap: CGFloat = 8
    private static let trailingPad: CGFloat = 12
    private static let baseColorCount: CGFloat = 8

    /// Right edge of the last color swatch — the swatch row's extent.
    private static func swatchRowEnd(hasDynamicColor: Bool) -> CGFloat {
        let colorCount = baseColorCount + (hasDynamicColor ? 1.0 : 0.0)
        return leadingPad + labelWidth + 6 + sliderWidth + 8 + 1 + 9
            + colorCount * swatchSize + max(colorCount - 1, 0) * swatchGap
    }

    private static func checkboxWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((L10n.textStrokeEffect as NSString).size(withAttributes: [.font: font]).width)
        return 16 + 8 + textWidth
    }

    static func preferredWidth(dynamicColor: NSColor?) -> CGFloat {
        swatchRowEnd(hasDynamicColor: dynamicColor != nil)
            + separatorGap + 1 + checkboxGap + checkboxWidth() + trailingPad
    }

    init(
        frame: NSRect,
        currentColor: NSColor,
        currentFontSize: CGFloat,
        dynamicColor: NSColor? = nil,
        strokeEnabled: Bool
    ) {
        self.currentColor = currentColor
        self.currentFontSize = currentFontSize
        self.dynamicColor = dynamicColor
        self.strokeEnabled = strokeEnabled
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

        // Numeric value label, kept narrow so a 3-digit value (e.g. "100") fits.
        let labelWidth: CGFloat = 28
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .right
        label.frame = NSRect(x: x, y: midY - 8, width: labelWidth, height: 16)
        addSubview(label)
        sizeLabel = label
        x += labelWidth + 6

        // Font-size slider.
        let sliderWidth: CGFloat = 130
        let sliderHeight: CGFloat = 20
        let s = NSSlider(
            value: Double(currentFontSize),
            minValue: Defaults.textFontSizeMin,
            maxValue: Defaults.textFontSizeMax,
            target: self,
            action: #selector(sliderChanged(_:))
        )
        s.isContinuous = true
        s.frame = NSRect(x: x, y: midY - sliderHeight / 2, width: sliderWidth, height: sliderHeight)
        addSubview(s)
        slider = s
        x += sliderWidth + 8

        // Vertical separator between size controls and color swatches.
        let sep = NSView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
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
        let strokeSep = NSView(frame: NSRect(x: strokeSepX, y: 6, width: 1, height: bounds.height - 12))
        strokeSep.wantsLayer = true
        strokeSep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(strokeSep)

        // Outline checkbox.
        let checkboxHeight: CGFloat = 20
        let checkbox = HUDCheckboxButton(
            frame: NSRect(
                x: strokeSepX + 1 + TextSubToolbar.checkboxGap,
                y: midY - checkboxHeight / 2,
                width: TextSubToolbar.checkboxWidth(),
                height: checkboxHeight
            ),
            title: L10n.textStrokeEffect,
            target: self,
            action: #selector(strokeCheckboxChanged(_:))
        )
        checkbox.state = strokeEnabled ? .on : .off
        addSubview(checkbox)
        strokeCheckbox = checkbox

        updateSizeLabel()
    }

    @objc private func strokeCheckboxChanged(_ sender: HUDCheckboxButton) {
        strokeEnabled = sender.state == .on
        onStrokeChanged?(strokeEnabled)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let raw = CGFloat(sender.doubleValue)
        let clamped = max(CGFloat(Defaults.textFontSizeMin), min(CGFloat(Defaults.textFontSizeMax), raw))

        // NSSlider sends its action on mouseDown / mouseDragged / mouseUp.
        // We use the current event phase to bookend a single drag with
        // onFontSizeBegan / onFontSizeEnded so the canvas can batch the
        // entire drag into a single undo entry.
        let phase = NSApp.currentEvent?.type
        if phase == .leftMouseDown {
            onFontSizeBegan?()
        }

        currentFontSize = clamped
        updateSizeLabel()
        onFontSizeChanged?(clamped)

        if phase == .leftMouseUp {
            onFontSizeEnded?()
        }
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

    private func updateSizeLabel() {
        sizeLabel.stringValue = "\(Int(currentFontSize.rounded()))"
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

        NSColor.white.withAlphaComponent(0.12).setFill()
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
        NSColor.white.withAlphaComponent(0.58).setFill()
        neckPath.fill()

        let capRect = rect(6.2, 14.2, 5.6, 1.8)
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 0.8 * unit, yRadius: 0.8 * unit)
        NSColor.white.withAlphaComponent(0.88).setFill()
        capPath.fill()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: bodyRect.minX + 2.5 * unit, y: bodyRect.minY + 2.1 * unit))
        highlight.line(to: NSPoint(x: bodyRect.minX + 2.5 * unit, y: bodyRect.maxY - 2.3 * unit))
        NSColor.white.withAlphaComponent(0.42).setStroke()
        highlight.lineWidth = 1
        highlight.lineCapStyle = .round
        highlight.stroke()

        NSColor.white.withAlphaComponent(0.82).setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        NSColor.black.withAlphaComponent(0.22).setStroke()
        capPath.lineWidth = 0.6
        capPath.stroke()
    }
}

// MARK: - HUD Slider

private final class HUDSlider: NSControl {
    var minValue: Double
    var maxValue: Double

    override var doubleValue: Double {
        get { value }
        set { setValue(newValue, notify: false) }
    }

    private var value: Double
    private var isDragging = false {
        didSet { needsDisplay = true }
    }

    private let knobDiameter: CGFloat = 18
    private let trackHeight: CGFloat = 5

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

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.35
        let trackRect = NSRect(
            x: knobDiameter / 2,
            y: floor(bounds.midY - trackHeight / 2),
            width: max(1, bounds.width - knobDiameter),
            height: trackHeight
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        NSColor.white.withAlphaComponent(0.14 * enabledAlpha).setFill()
        trackPath.fill()

        let knobCenterX = trackRect.minX + normalizedValue * trackRect.width
        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: max(0, knobCenterX - trackRect.minX),
            height: trackRect.height
        )
        if fillRect.width > 0 {
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
            NSColor.controlAccentColor.withAlphaComponent(enabledAlpha).setFill()
            fillPath.fill()
        }

        let knobRect = NSRect(
            x: knobCenterX - knobDiameter / 2,
            y: bounds.midY - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter
        )
        let knobPath = NSBezierPath(ovalIn: knobRect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18 * enabledAlpha)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(white: isDragging ? 0.92 : 0.86, alpha: enabledAlpha).setFill()
        knobPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.08 * enabledAlpha).setStroke()
        knobPath.lineWidth = 1
        knobPath.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        updateValue(with: event, notify: true)
    }

    override func mouseDragged(with event: NSEvent) {
        updateValue(with: event, notify: isContinuous)
    }

    override func mouseUp(with event: NSEvent) {
        updateValue(with: event, notify: true)
        isDragging = false
    }

    private var normalizedValue: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((value - minValue) / (maxValue - minValue))
    }

    private func updateValue(with event: NSEvent, notify: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let trackMinX = knobDiameter / 2
        let trackWidth = max(1, bounds.width - knobDiameter)
        let normalized = max(0, min(1, (point.x - trackMinX) / trackWidth))
        setValue(minValue + Double(normalized) * (maxValue - minValue), notify: notify)
    }

    private func setValue(_ newValue: Double, notify: Bool) {
        value = min(max(newValue, minValue), maxValue)
        needsDisplay = true
        if notify, let action {
            sendAction(action, to: target)
        }
    }
}

// MARK: - HUD Checkbox

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
            NSColor.white.withAlphaComponent((isHighlighted ? 0.24 : 0.16) * enabledAlpha).setFill()
        }
        boxPath.fill()

        NSColor.white.withAlphaComponent(0.18 * enabledAlpha).setStroke()
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
                .foregroundColor: NSColor.white.withAlphaComponent(0.9 * enabledAlpha),
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
    var currentPresetID: String? {
        didSet { updateSelection() }
    }

    var onPaddingChanged: ((CGFloat) -> Void)?
    var onShadowEnabledChanged: ((Bool) -> Void)?

    private var swatchButtons: [BeautifySwatchView] = []
    private let presets: [BeautifyPreset]
    private let initialPadding: CGFloat
    private let initialShadowEnabled: Bool
    private let screen: NSScreen
    private var paddingSlider: HUDSlider?
    private var shadowCheckbox: HUDCheckboxButton?
    private let swatchDiameter: CGFloat = 24
    private let swatchSpacing: CGFloat = 8
    private let innerPadding: CGFloat = 12
    private let sliderWidth: CGFloat = 120
    private let sliderHeight: CGFloat = 20
    private let checkboxWidth: CGFloat = BeautifySubToolbar.preferredCheckboxWidth()
    private let checkboxHeight: CGFloat = 20

    init(
        frame: NSRect,
        presets: [BeautifyPreset],
        screen: NSScreen,
        initialPadding: CGFloat = BeautifyRenderer.paddingSliderDefault,
        initialShadowEnabled: Bool = true
    ) {
        self.presets = presets
        self.screen = screen
        self.initialPadding = initialPadding
        self.initialShadowEnabled = initialShadowEnabled
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
        let checkboxWidth: CGFloat = preferredCheckboxWidth()
        let trailingPad: CGFloat = 12
        let swatches = CGFloat(presetCount) * diameter + CGFloat(max(presetCount - 1, 0)) * spacing
        return innerPad + swatches + separatorGap + sliderWidth + separatorGap + checkboxWidth + trailingPad
    }

    private static func preferredCheckboxWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((L10n.beautifyShadowEffect as NSString).size(withAttributes: [.font: font]).width)
        return max(104, 16 + 8 + textWidth)
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
        let slider = HUDSlider(
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

        let shadowSepX = sliderX + sliderWidth + 5
        let shadowSep = NSView(frame: NSRect(x: shadowSepX, y: 6, width: 1, height: bounds.height - 12))
        shadowSep.wantsLayer = true
        shadowSep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(shadowSep)

        let checkbox = HUDCheckboxButton(
            frame: NSRect(
                x: shadowSepX + 1 + 6,
                y: midY - checkboxHeight / 2,
                width: checkboxWidth,
                height: checkboxHeight
            ),
            title: L10n.beautifyShadowEffect,
            target: self,
            action: #selector(shadowCheckboxChanged(_:))
        )
        checkbox.state = initialShadowEnabled ? .on : .off
        addSubview(checkbox)
        shadowCheckbox = checkbox
    }

    @objc private func swatchTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? BeautifySwatchView else { return }
        let index = view.itemIndex
        guard index < presets.count else { return }
        let preset = presets[index]
        currentPresetID = preset.id
        onPresetSelected?(preset)
    }

    @objc private func paddingSliderChanged(_ sender: HUDSlider) {
        let clamped = max(
            BeautifyRenderer.paddingSliderMin,
            min(BeautifyRenderer.paddingSliderMax, CGFloat(sender.doubleValue))
        )
        onPaddingChanged?(clamped)
    }

    @objc private func shadowCheckboxChanged(_ sender: NSButton) {
        onShadowEnabledChanged?(sender.state == .on)
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
    var wallpaperThumbnail: NSImage? {
        didSet { needsDisplay = true }
    }

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

        if preset.isWallpaper, let wpImage = wallpaperThumbnail {
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
        let point = convert(event.locationInWindow, from: nil)
        selectionView.resizeByExternalDrag(
            handle: handle,
            originalRect: dragOriginalRect,
            currentPoint: point
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragHandle = nil }
        guard dragHandle != nil, let selectionView else { return }
        selectionView.finalizeExternalResize()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActiveAndVisible else { return }
        let point = convert(event.locationInWindow, from: nil)
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
        // beautify gradient frame covers it. Re-draw it here, above the frame.
        SelectionView.drawSizeLabel(context: context, rect: rect)
    }
}
