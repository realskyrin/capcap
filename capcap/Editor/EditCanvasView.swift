import AppKit

enum EditTool {
    case none
    case pen
    case marker
    case mosaic
    case rectangle
    case ellipse
    case arrow
    case numbered
    case text
    case scrollCapture
}

class EditCanvasView: NSView {
    var captureRect: CGRect?
    var captureScreen: NSScreen?
    var preSnapshot: CGImage?
    var activeTool: EditTool = .none {
        didSet {
            if oldValue == .text, activeTool != .text {
                activeTextField?.commit()
            }
            // Tool change can affect what counts as "interactive area" — refresh
            // cursor immediately under the current mouse position.
            refreshCursorAtCurrentLocation()
        }
    }
    private(set) var previewImage: NSImage?

    /// When non-nil, `draw(_:)` clips its drawing to a rounded rect of this
    /// radius. Used by the beautify flow so the canvas content shows with
    /// rounded corners matching the container's frame.
    var beautifyCornerRadius: CGFloat?

    /// Fallback base image used during live drawing when `previewImage` is
    /// nil. The beautify flow sets this to a snapshot of the current screen
    /// area so the user sees the actual content under the gradient frame
    /// (without it, normal screenshots show only gradient because the editor
    /// overlay is transparent over the desktop passthrough).
    var externalBaseImage: NSImage?

    // Current drawing properties (set by toolbar)
    var currentColor: NSColor = .red {
        didSet { activeTextField?.textColor = currentColor }
    }
    var currentLineWidth: CGFloat = 3.0
    /// Base width for the marker brush. Drawn at `× MarkerAnnotation.brushScale`.
    var currentMarkerLineWidth: CGFloat = 4.0
    /// Marker uses a separate color slot so switching tools keeps the
    /// highlighter's yellow without overriding the pen's red, and vice-versa.
    var currentMarkerColor: NSColor = NSColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
    var currentMosaicBlockSize: CGFloat = 12.0
    var currentFontSize: CGFloat = 24.0 {
        didSet {
            guard let field = activeTextField else { return }
            field.font = NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
            field.sizeToFitText()
        }
    }

    // Annotations stack (supports undo)
    private var annotations: [Annotation] = []

    // In-progress drawing state
    private var currentPenPath: NSBezierPath?
    private var currentMarkerPath: NSBezierPath?
    private var currentMosaicPoints: [NSPoint] = []
    private var mosaicBaseImage: NSImage?
    private var shapeStart: NSPoint?
    private var shapeCurrent: NSPoint?
    private var numberCounter: Int = 1
    private var activeTextField: EditableTextField?
    /// When editing an existing text annotation, we remove it from the
    /// `annotations` array so it isn't drawn under the editor and stash the
    /// original here. On commit it's discarded; on cancel/Esc it's reinserted
    /// at its original index.
    private var editingOriginalAnnotation: TextAnnotation?
    private var editingOriginalIndex: Int?
    /// Active drag interaction on a committed annotation. Captured in
    /// `mouseDown` regardless of which tool is active — clicking on any
    /// existing draggable annotation always starts a drag, so the user can
    /// reposition marks without first deselecting their tool.
    private var dragState: DragState?
    /// Pending number creation. `start` is the click point (badge center);
    /// `current` follows the drag, becoming the arrow tip on commit. When
    /// the cursor never moves, tip stays at start so the badge commits
    /// without an arrow.
    private var pendingNumberCreate: PendingNumberCreate?
    /// Pending text creation — same idea as number, plus a `wasEditing` flag
    /// so a click that just committed an in-progress field doesn't pop a new
    /// one.
    private var pendingTextCreate: PendingTextCreate?
    private let dragThreshold: CGFloat = 4
    /// Index of the annotation showing selection chrome (rotate / curve
    /// handles). nil when no annotation is selected. Cleared whenever a
    /// drawing tool is activated or an undo / commit invalidates the index.
    private var selectedIndex: Int? {
        didSet {
            if oldValue != selectedIndex { needsDisplay = true }
        }
    }
    private var handleDragState: HandleDragState?

    private struct DragState {
        let index: Int
        let startMouse: NSPoint
        let original: Annotation
        var didDrag: Bool
    }

    private struct PendingTextCreate {
        let point: NSPoint
        let wasEditing: Bool
    }

    private struct PendingNumberCreate {
        let start: NSPoint
        var current: NSPoint
    }

    /// Active drag on a selection handle (rotate / curve / number tip). The
    /// original annotation is captured so escape-style cancellations
    /// (e.g. tool switch mid-drag) can restore it cleanly.
    private struct HandleDragState {
        enum Kind { case rotate, curve, tip }
        let kind: Kind
        let index: Int
        let original: Annotation
        let startMouse: NSPoint
        /// For rotate: the angle from annotation center to startMouse,
        /// captured at mouseDown so the rotation delta is anchored.
        let startAngle: CGFloat
        /// For rotate: the original rotation captured at mouseDown.
        let startRotation: CGFloat
    }

    private static let rotateHandleSize: CGFloat = 22
    private static let rotateHandleOffset: CGFloat = 22
    private static let curveHandleSize: CGFloat = 14
    private static let tipHandleSize: CGFloat = 14
    private static let actionButtonSize: CGFloat = 22
    private static let selectionBoxPad: CGFloat = 6

    private var trackingArea: NSTrackingArea?

    var hasPreviewImage: Bool { previewImage != nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While a tool is active or a preview is loaded, the canvas always
        // captures clicks (drawing surface or scroll viewport).
        if activeTool != .none || hasPreviewImage {
            return super.hitTest(point)
        }
        // In adjust mode we want to capture clicks that land on either an
        // existing draggable annotation, a drag handle (rotate / curve /
        // tip), or an action button (delete / edit). Handles and buttons
        // can sit outside the annotation body — without this, the click
        // falls through to the SelectionView and we never see a mouseDown.
        let local = convert(point, from: superview)
        if hitTestAnnotation(at: local) != nil {
            return super.hitTest(point)
        }
        if hitTestSelectionHandle(at: local) != nil {
            return super.hitTest(point)
        }
        if hitTestSelectionAction(at: local) != nil {
            return super.hitTest(point)
        }
        return nil
    }

    /// Re-enter inline edit mode for an existing text annotation by removing
    /// the original from the canvas and creating a fresh editable text field
    /// at the same position with the same text pre-filled. On commit the new
    /// content replaces it; on cancel the original is reinserted.
    ///
    /// **Deferred to the next runloop tick on purpose.** Calling
    /// `makeFirstResponder` from inside a mouseDown stack frame can cause
    /// AppKit to immediately resign the new field once the surrounding
    /// mouse-event dispatch finishes — `controlTextDidEndEditing` then fires
    /// and our commit handler tears the field back down before the user
    /// sees it. Posting async lets the click finish dispatching first; the
    /// field is then created against a quiescent run loop and stays put.
    private func reEditTextAnnotation(at index: Int, annotation: TextAnnotation) {
        // The source annotation is briefly removed from the array while the
        // editor is open, so any stale selection on it would point at the
        // wrong row. Drop it before starting the edit.
        selectedIndex = nil
        DispatchQueue.main.async { [weak self] in
            self?.beginTextEditing(
                bottomLeft: annotation.origin,
                fontSize: annotation.fontSize,
                color: annotation.color,
                initialText: annotation.text,
                replacingIndex: index
            )
        }
    }

    // MARK: - Undo

    func undo() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        // If it was a number annotation, decrement counter
        if removed is NumberAnnotation {
            numberCounter = max(1, numberCounter - 1)
        }
        // Drop the selection if it pointed at the removed annotation (or
        // beyond the new array end after the removal).
        if let idx = selectedIndex, idx >= annotations.count {
            selectedIndex = nil
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Action buttons (delete / edit) — clicked, not dragged.
        if let action = hitTestSelectionAction(at: point), let idx = selectedIndex {
            activeTextField?.commit()
            switch action {
            case .delete:
                annotations.remove(at: idx)
                selectedIndex = nil
                needsDisplay = true
                refreshCursorAtCurrentLocation()
            case .edit:
                if let textAnnotation = annotations[idx] as? TextAnnotation {
                    reEditTextAnnotation(at: idx, annotation: textAnnotation)
                }
            }
            return
        }

        // Selection handles (rotate / curve / tip) take priority over body
        // drags so the user can grab a handle that visually overlaps the
        // annotation it controls.
        if let kind = hitTestSelectionHandle(at: point), let idx = selectedIndex {
            activeTextField?.commit()
            let original = annotations[idx]
            let center = NSPoint(x: original.boundingRect.midX, y: original.boundingRect.midY)
            let startAngle = atan2(point.y - center.y, point.x - center.x)
            handleDragState = HandleDragState(
                kind: kind,
                index: idx,
                original: original,
                startMouse: point,
                startAngle: startAngle,
                startRotation: original.rotation
            )
            NSCursor.closedHand.set()
            return
        }

        // Universal: clicking on any draggable existing annotation starts a
        // drag, regardless of which tool is selected (or none). Drawing tools
        // only take over for clicks on empty canvas.
        if let idx = hitTestAnnotation(at: point) {
            // Commit any in-progress text edit before grabbing something else.
            activeTextField?.commit()
            dragState = DragState(
                index: idx,
                startMouse: point,
                original: annotations[idx],
                didDrag: false
            )
            // Attach the selection to whatever the user just grabbed —
            // works in any tool so the user can immediately adjust the mark.
            selectedIndex = idx
            NSCursor.closedHand.set()
            return
        }

        // Click on empty canvas: clear any current selection so adjust-mode
        // chrome dismisses; the active tool then takes over (if any).
        selectedIndex = nil

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .scrollCapture:
            return

        case .pen:
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: point)
            currentPenPath = path

        case .marker:
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: point)
            currentMarkerPath = path

        case .mosaic:
            mosaicBaseImage = resolveBaseImageForEditing()
            currentMosaicPoints = [point]

        case .rectangle, .ellipse, .arrow:
            shapeStart = point
            shapeCurrent = point

        case .numbered:
            pendingNumberCreate = PendingNumberCreate(start: point, current: point)

        case .text:
            let wasEditing = activeTextField != nil
            activeTextField?.commit()
            pendingTextCreate = PendingTextCreate(point: point, wasEditing: wasEditing)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let state = handleDragState {
            applyHandleDrag(state: state, currentMouse: point)
            return
        }

        if var state = dragState {
            if !state.didDrag {
                let distance = hypot(point.x - state.startMouse.x, point.y - state.startMouse.y)
                guard distance >= dragThreshold else { return }
                state.didDrag = true
                dragState = state
            }
            let delta = NSPoint(
                x: point.x - state.startMouse.x,
                y: point.y - state.startMouse.y
            )
            if state.index < annotations.count {
                annotations[state.index] = state.original.translated(by: delta)
                needsDisplay = true
            }
            return
        }

        // Number tool: drag pulls an arrow tip out of the badge — preview
        // it live and commit on mouseUp.
        if var pending = pendingNumberCreate {
            pending.current = point
            pendingNumberCreate = pending
            needsDisplay = true
            return
        }
        // Text: drag away from the pending click cancels (no editor opens).
        if let pending = pendingTextCreate {
            if hypot(point.x - pending.point.x, point.y - pending.point.y) >= dragThreshold {
                pendingTextCreate = nil
            }
            return
        }

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .scrollCapture, .numbered, .text:
            return

        case .pen:
            currentPenPath?.line(to: point)
            needsDisplay = true

        case .marker:
            currentMarkerPath?.line(to: point)
            needsDisplay = true

        case .mosaic:
            currentMosaicPoints.append(point)
            needsDisplay = true

        case .rectangle, .ellipse, .arrow:
            shapeCurrent = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 0. Handle drag (rotate / curve) — commit current state and exit.
        if handleDragState != nil {
            handleDragState = nil
            needsDisplay = true
            refreshCursorAtCurrentLocation()
            return
        }

        // 1. Drag interaction on existing annotation. In any tool, a click
        // (with or without drag) keeps the annotation selected so the
        // adjust-mode chrome appears. Drag also moves it.
        if let state = dragState {
            dragState = nil
            selectedIndex = state.index
            refreshCursorAtCurrentLocation()
            return
        }

        // 2. Pending number create — commits whether or not the user dragged.
        // No drag (or short drag) → no arrow. Drag past the minimum arrow
        // distance → tip is the drag end and an arrow points at it.
        if let pending = pendingNumberCreate {
            pendingNumberCreate = nil
            let dragDist = hypot(
                pending.current.x - pending.start.x,
                pending.current.y - pending.start.y
            )
            let tip: NSPoint? = dragDist >= NumberAnnotation.arrowMinDistance
                ? pending.current
                : nil
            annotations.append(NumberAnnotation(
                center: pending.start,
                tip: tip,
                number: numberCounter,
                color: currentColor
            ))
            numberCounter += 1
            needsDisplay = true
            refreshCursorAtCurrentLocation()
            return
        }

        // 3. Pending text create (skip if same click just committed an edit)
        if let pending = pendingTextCreate {
            pendingTextCreate = nil
            if !pending.wasEditing {
                beginTextEditing(
                    bottomLeft: newTextOrigin(forClickAt: pending.point, fontSize: currentFontSize),
                    fontSize: currentFontSize,
                    color: currentColor
                )
            }
            return
        }

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .scrollCapture, .numbered, .text:
            return

        case .pen:
            if let path = currentPenPath {
                annotations.append(PenAnnotation(
                    path: path,
                    color: currentColor,
                    lineWidth: currentLineWidth
                ))
                currentPenPath = nil
            }

        case .marker:
            if let path = currentMarkerPath {
                annotations.append(MarkerAnnotation(
                    path: path,
                    color: currentMarkerColor,
                    lineWidth: currentMarkerLineWidth
                ))
                currentMarkerPath = nil
            }

        case .mosaic:
            if !currentMosaicPoints.isEmpty, let baseImage = mosaicBaseImage {
                let brushRadius = currentMosaicBlockSize * 1.5
                if let region = MosaicTool.createMosaicRegion(
                    points: currentMosaicPoints,
                    brushRadius: brushRadius,
                    imageSize: bounds.size,
                    baseImage: baseImage,
                    blockSize: currentMosaicBlockSize
                ) {
                    annotations.append(MosaicAnnotation(
                        rect: region.rect,
                        pixelatedImage: region.pixelatedImage
                    ))
                }
                currentMosaicPoints = []
            }

        case .rectangle:
            if let start = shapeStart, let end = shapeCurrent {
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    annotations.append(RectAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .ellipse:
            if let start = shapeStart, let end = shapeCurrent {
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    annotations.append(EllipseAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .arrow:
            if let start = shapeStart, let end = shapeCurrent {
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 5 {
                    annotations.append(ArrowAnnotation(
                        startPoint: start,
                        endPoint: end,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil
        }

        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let didClip: Bool
        if let radius = beautifyCornerRadius {
            context.saveGState()
            let clipPath = CGPath(
                roundedRect: bounds,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.addPath(clipPath)
            context.clip()
            didClip = true
        } else {
            didClip = false
        }

        if let image = previewImage ?? externalBaseImage {
            image.draw(in: NSRect(origin: .zero, size: bounds.size))
        }

        // Draw all committed annotations (rotation applied via helper)
        for annotation in annotations {
            annotation.drawApplyingTransforms(in: context, bounds: bounds)
        }

        // Selection chrome — drawn on top so it's always reachable.
        if let idx = selectedIndex, idx < annotations.count {
            drawSelectionHandles(for: annotations[idx], in: context)
        }

        // Draw in-progress pen stroke
        if let path = currentPenPath {
            currentColor.setStroke()
            path.lineWidth = currentLineWidth
            path.stroke()
        }

        // Draw in-progress marker stroke (semi-transparent, brush × 6).
        if let path = currentMarkerPath {
            NSGraphicsContext.saveGraphicsState()
            let stroke = currentMarkerColor.withAlphaComponent(1.0)
            stroke.setStroke()
            path.lineWidth = currentMarkerLineWidth * MarkerAnnotation.brushScale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            context.setAlpha(MarkerAnnotation.markerAlpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            path.stroke()
            context.endTransparencyLayer()
            context.setAlpha(1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Draw in-progress shape preview
        if let start = shapeStart, let current = shapeCurrent {
            context.setStrokeColor(currentColor.cgColor)
            context.setLineWidth(currentLineWidth)

            switch activeTool {
            case .rectangle:
                let rect = rectFromTwoPoints(start, current)
                context.stroke(rect)
            case .ellipse:
                let rect = rectFromTwoPoints(start, current)
                context.strokeEllipse(in: rect)
            case .arrow:
                // Draw line preview
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: current)
                context.strokePath()
                // Draw arrowhead preview
                let dx = current.x - start.x
                let dy = current.y - start.y
                let length = sqrt(dx * dx + dy * dy)
                if length > 0 {
                    let headLength: CGFloat = max(12, currentLineWidth * 4)
                    let headWidth: CGFloat = max(8, currentLineWidth * 3)
                    let unitX = dx / length
                    let unitY = dy / length
                    let baseX = current.x - unitX * headLength
                    let baseY = current.y - unitY * headLength
                    context.setFillColor(currentColor.cgColor)
                    context.move(to: current)
                    context.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
                    context.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
                    context.closePath()
                    context.fillPath()
                }
            default:
                break
            }
        }

        // Draw number-tool preview while dragging — committed lazily on
        // mouseUp, but the user expects to see the badge + arrow track the
        // cursor live like the arrow tool does.
        if let pending = pendingNumberCreate {
            let tip: NSPoint? = (pending.current == pending.start) ? nil : pending.current
            let preview = NumberAnnotation(
                center: pending.start,
                tip: tip,
                number: numberCounter,
                color: currentColor
            )
            preview.draw(in: context, bounds: bounds)
        }

        // Draw mosaic preview (points being brushed)
        if !currentMosaicPoints.isEmpty {
            let brushRadius = currentMosaicBlockSize * 1.5
            context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            for point in currentMosaicPoints {
                context.fillEllipse(in: NSRect(
                    x: point.x - brushRadius,
                    y: point.y - brushRadius,
                    width: brushRadius * 2,
                    height: brushRadius * 2
                ))
            }
        }

        if didClip {
            context.restoreGState()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasPreviewImage else {
            super.scrollWheel(with: event)
            return
        }

        enclosingScrollView?.scrollWheel(with: event)
    }

    // MARK: - Composite

    func compositeImage(
        fallbackBaseImage: NSImage?,
        beautifyPreset: BeautifyPreset? = nil,
        beautifyPadding: CGFloat? = nil,
        wallpaperImage: NSImage? = nil
    ) -> NSImage? {
        guard let baseImage = previewImage ?? fallbackBaseImage else { return nil }

        let innerImage: NSImage
        if annotations.isEmpty {
            innerImage = baseImage
        } else if
            let compositeRep = baseImage.bitmapImageRepPreservingBacking(),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: compositeRep)
        {
            // compositeRep is created from baseImage's CGImage, so it already
            // contains the base image pixels. We only need to draw annotations
            // on top — do NOT call baseImage.draw here or you'll double-composite.
            let imageBounds = NSRect(origin: .zero, size: baseImage.size)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            graphicsContext.imageInterpolation = .high

            let context = graphicsContext.cgContext
            for annotation in annotations {
                annotation.drawApplyingTransforms(in: context, bounds: imageBounds)
            }

            NSGraphicsContext.restoreGraphicsState()

            let merged = NSImage(size: baseImage.size)
            merged.addRepresentation(compositeRep)
            innerImage = merged
        } else {
            innerImage = baseImage
        }

        if let preset = beautifyPreset {
            let pad = beautifyPadding ?? BeautifyRenderer.paddingSliderDefault
            return BeautifyRenderer.render(
                innerImage: innerImage,
                preset: preset,
                padding: pad,
                wallpaperImage: wallpaperImage
            )
        }
        return innerImage
    }

    func loadPreviewImage(_ image: NSImage) {
        cancelInFlightInteraction()
        previewImage = image
        mosaicBaseImage = nil
        setFrameSize(image.size)
        needsDisplay = true
    }

    func updateViewportSize(_ size: NSSize) {
        guard !hasPreviewImage else { return }
        setFrameSize(size)
        needsDisplay = true
    }

    // MARK: - Helpers

    func resolveBaseImageForEditing() -> NSImage? {
        if let previewImage {
            return previewImage
        }

        if let snapshot = preSnapshot, let rect = captureRect, let screen = captureScreen {
            if let cropped = ScreenCapturer.crop(from: snapshot, captureRect: rect, screen: screen) {
                return cropped
            }
        }

        guard let rect = captureRect, let screen = captureScreen else { return nil }
        return ScreenCapturer.capture(rect: rect, screen: screen)
    }

    private func cancelInFlightInteraction() {
        currentPenPath = nil
        currentMarkerPath = nil
        currentMosaicPoints = []
        mosaicBaseImage = nil
        shapeStart = nil
        shapeCurrent = nil
        dragState = nil
        handleDragState = nil
        pendingNumberCreate = nil
        pendingTextCreate = nil
        selectedIndex = nil
        activeTextField?.cancel()
    }

    /// Topmost annotation under `point` that the user can grab. Mosaic is
    /// excluded — it's treated as "pasted on" once placed.
    private func hitTestAnnotation(at point: NSPoint) -> Int? {
        for i in annotations.indices.reversed() {
            if annotations[i].containsPoint(point) {
                return i
            }
        }
        return nil
    }

    /// Force-commit any in-progress text. Called by the controller when
    /// switching tools or activating actions like save/confirm so the
    /// floating editor's contents make it into the composite.
    func commitActiveTextEditing() {
        activeTextField?.commit()
    }

    var isTextEditing: Bool {
        activeTextField != nil
    }

    private func newTextOrigin(forClickAt point: NSPoint, fontSize: CGFloat) -> NSPoint {
        let font = TextAnnotation.font(forSize: fontSize)
        return NSPoint(
            x: point.x,
            y: point.y - TextAnnotation.lineHeight(for: font)
        )
    }

    private func beginTextEditing(
        bottomLeft: NSPoint,
        fontSize: CGFloat,
        color: NSColor,
        initialText: String = "",
        replacingIndex: Int? = nil
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let lineHeight = TextAnnotation.lineHeight(for: font)

        // Hide the source annotation while editing so it isn't drawn under
        // the field. Stash it for cancel-restore.
        if let idx = replacingIndex,
           idx < annotations.count,
           let original = annotations[idx] as? TextAnnotation {
            annotations.remove(at: idx)
            editingOriginalAnnotation = original
            editingOriginalIndex = idx
            needsDisplay = true
        } else {
            editingOriginalAnnotation = nil
            editingOriginalIndex = nil
        }

        let initialWidth: CGFloat = 80
        let fieldRect = NSRect(
            x: bottomLeft.x,
            y: bottomLeft.y,
            width: initialWidth,
            height: lineHeight
        )

        let field = EditableTextField(frame: fieldRect)
        field.font = font
        field.textColor = color
        field.stringValue = initialText
        field.onCommit = { [weak self, weak field] text in
            self?.handleTextCommit(text: text, field: field)
        }
        field.onCancel = { [weak self, weak field] in
            self?.handleTextCancel(field: field)
        }

        addSubview(field)
        activeTextField = field
        field.sizeToFitText()
        window?.makeFirstResponder(field)
        // Pre-select existing text directly on the cell editor.
        //
        // NEVER use `field.selectText(nil)` here — it internally calls
        // `makeFirstResponder` AGAIN on the field, which makes AppKit tear
        // down the just-built cell editor and rebuild it. Tearing it down
        // fires `controlTextDidEndEditing`, which our delegate treats as a
        // user commit and removes the field from the view hierarchy before
        // the user ever sees it. Reaching into `currentEditor()` and setting
        // `selectedRange` manipulates the same NSText proxy without going
        // back through the responder dance.
        if !initialText.isEmpty, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (initialText as NSString).length)
        }
    }

    private func handleTextCommit(text: String, field: EditableTextField?) {
        guard let field else { return }
        field.removeFromSuperview()
        if activeTextField === field { activeTextField = nil }
        if activeTool == .text {
            window?.makeFirstResponder(self)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let font = field.font ?? NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
            let newAnnotation = TextAnnotation(
                text: text,
                origin: NSPoint(x: field.frame.minX, y: field.frame.minY),
                color: field.textColor ?? currentColor,
                fontSize: font.pointSize
            )
            if let idx = editingOriginalIndex {
                let safeIdx = min(idx, annotations.count)
                annotations.insert(newAnnotation, at: safeIdx)
            } else {
                annotations.append(newAnnotation)
            }
        }
        editingOriginalAnnotation = nil
        editingOriginalIndex = nil
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    private func handleTextCancel(field: EditableTextField?) {
        guard let field else { return }
        field.removeFromSuperview()
        if activeTextField === field { activeTextField = nil }
        if activeTool == .text {
            window?.makeFirstResponder(self)
        }

        if let original = editingOriginalAnnotation, let idx = editingOriginalIndex {
            let safeIdx = min(idx, annotations.count)
            annotations.insert(original, at: safeIdx)
        }
        editingOriginalAnnotation = nil
        editingOriginalIndex = nil
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    private func rectFromTwoPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    // MARK: - Selection handles

    /// Padded bounding rect (unrotated) used as the dashed selection box and
    /// as the anchor for the rotate / delete / edit handles.
    private func selectionBox(for annotation: Annotation) -> NSRect {
        annotation.boundingRect.insetBy(
            dx: -EditCanvasView.selectionBoxPad,
            dy: -EditCanvasView.selectionBoxPad
        )
    }

    /// Apply the annotation's rotation (around its bounding-rect mid) to a
    /// point expressed in the unrotated frame, returning the canvas-space
    /// position. Used to place screen-space chrome (rotation handle, delete
    /// button) at corners that follow the rotated annotation.
    private func rotated(_ point: NSPoint, for annotation: Annotation) -> NSPoint {
        let rect = annotation.boundingRect
        let cx = rect.midX
        let cy = rect.midY
        let rot = annotation.supportsRotation ? annotation.rotation : 0
        let dx = point.x - cx
        let dy = point.y - cy
        let cosR = cos(rot)
        let sinR = sin(rot)
        return NSPoint(
            x: cx + dx * cosR - dy * sinR,
            y: cy + dx * sinR + dy * cosR
        )
    }

    /// Center of the rotation handle in canvas coordinates. Sits above the
    /// annotation's (rotated) top-center so it tracks the annotation as it
    /// rotates and stays visible at any angle.
    private func rotationHandleCenter(for annotation: Annotation) -> NSPoint {
        let box = selectionBox(for: annotation)
        let unrotatedTop = NSPoint(
            x: box.midX,
            y: box.maxY + EditCanvasView.rotateHandleOffset
        )
        return rotated(unrotatedTop, for: annotation)
    }

    /// Where the rotation tether meets the box edge, in canvas space.
    private func rotationTetherAnchor(for annotation: Annotation) -> NSPoint {
        let box = selectionBox(for: annotation)
        let unrotated = NSPoint(x: box.midX, y: box.maxY + 2)
        return rotated(unrotated, for: annotation)
    }

    /// Top-right corner of the dashed box in canvas space. Anchors the
    /// stack of action buttons (delete, edit).
    private func topRightCorner(for annotation: Annotation) -> NSPoint {
        let box = selectionBox(for: annotation)
        return rotated(NSPoint(x: box.maxX, y: box.maxY), for: annotation)
    }

    /// Curve handle position for any annotation that supports curving its
    /// shaft (arrows and numbered badges with an arrow). Falls back to the
    /// visual midpoint when no `controlPoint` is set so a fresh straight
    /// shaft still has a grabbable bend point.
    private func curveHandleCenter(for annotation: Annotation) -> NSPoint? {
        if let arrow = annotation as? ArrowAnnotation {
            return arrow.curveHandlePoint
        }
        if let number = annotation as? NumberAnnotation {
            return number.curveHandlePoint
        }
        return nil
    }

    /// Tip handle position for numbered badges. Anchors at `tip` when set;
    /// otherwise places a "stub" handle just outside the badge so the user
    /// can pull a fresh arrow out without re-creating the annotation.
    /// Stub sits above the badge — the right side is reserved for the
    /// close button stack.
    private func tipHandleCenter(for annotation: Annotation) -> NSPoint? {
        guard let number = annotation as? NumberAnnotation else { return nil }
        if let tip = number.tip {
            return tip
        }
        return NSPoint(
            x: number.center.x,
            y: number.center.y + NumberAnnotation.arrowMinDistance + 4
        )
    }

    /// Delete button rect — always present in adjust mode.
    private func deleteButtonRect(for annotation: Annotation) -> NSRect {
        let s = EditCanvasView.actionButtonSize
        let topRight = topRightCorner(for: annotation)
        return NSRect(
            x: topRight.x + 4,
            y: topRight.y - s,
            width: s,
            height: s
        )
    }

    /// Edit (pencil) button rect — only meaningful for text annotations.
    private func editButtonRect(for annotation: Annotation) -> NSRect? {
        guard annotation is TextAnnotation else { return nil }
        let s = EditCanvasView.actionButtonSize
        let topRight = topRightCorner(for: annotation)
        return NSRect(
            x: topRight.x + 4,
            y: topRight.y - s * 2 - 4,
            width: s,
            height: s
        )
    }

    private func drawSelectionHandles(for annotation: Annotation, in context: CGContext) {
        // 1. Dashed selection box — rotated with the annotation so it stays
        // wrapped around the visible content at any angle.
        let box = selectionBox(for: annotation)
        let needsRotation = annotation.supportsRotation && annotation.rotation != 0
        context.saveGState()
        if needsRotation {
            let rect = annotation.boundingRect
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: annotation.rotation)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(box)
        context.restoreGState()

        // 2. Rotation handle — follows the rotated top-center via a dashed
        // tether so the user has a clear pivot point at any angle.
        if annotation.supportsRotation {
            let handleCenter = rotationHandleCenter(for: annotation)
            let tether = rotationTetherAnchor(for: annotation)
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: tether)
            context.addLine(to: handleCenter)
            context.strokePath()
            context.restoreGState()

            drawHandleDot(
                at: handleCenter,
                size: EditCanvasView.rotateHandleSize,
                fill: NSColor(white: 0.12, alpha: 0.94),
                stroke: accentGreen,
                in: context
            )
            drawSymbolGlyph(
                "arrow.triangle.2.circlepath",
                at: handleCenter,
                pointSize: 10,
                in: context
            )
        }

        // 3. Curve handle (arrow only).
        if let cp = curveHandleCenter(for: annotation) {
            drawHandleDot(
                at: cp,
                size: EditCanvasView.curveHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: accentGreen,
                in: context
            )
        }

        // 4. Tip handle (number only) — pulled out of the badge as an arrow.
        if let tip = tipHandleCenter(for: annotation) {
            drawHandleDot(
                at: tip,
                size: EditCanvasView.tipHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: accentGreen,
                in: context
            )
        }

        // 5. Delete button (always).
        let deleteRect = deleteButtonRect(for: annotation)
        drawActionButton(
            in: deleteRect,
            symbolName: "xmark",
            symbolPointSize: 9,
            in: context
        )

        // 6. Edit (pencil) button — text only.
        if let editRect = editButtonRect(for: annotation) {
            drawActionButton(
                in: editRect,
                symbolName: "pencil",
                symbolPointSize: 10,
                in: context
            )
        }
    }

    private func drawHandleDot(
        at center: NSPoint,
        size: CGFloat,
        fill: NSColor,
        stroke: NSColor,
        in context: CGContext
    ) {
        let rect = NSRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
    }

    /// Draw an SF Symbol tinted white, centered at `center`. Used for the
    /// rotate / delete / edit glyphs on the action buttons.
    private func drawSymbolGlyph(
        _ symbolName: String,
        at center: NSPoint,
        pointSize: CGFloat,
        in context: CGContext
    ) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let img = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg) else { return }

        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        let drawRect = NSRect(
            x: center.x - tinted.size.width / 2,
            y: center.y - tinted.size.height / 2,
            width: tinted.size.width,
            height: tinted.size.height
        )
        NSGraphicsContext.saveGraphicsState()
        tinted.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Round dark button with an accent ring and a centered SF symbol —
    /// used for delete / edit actions in adjust mode.
    private func drawActionButton(
        in rect: NSRect,
        symbolName: String,
        symbolPointSize: CGFloat,
        in context: CGContext
    ) {
        drawHandleDot(
            at: NSPoint(x: rect.midX, y: rect.midY),
            size: rect.width,
            fill: NSColor(white: 0.12, alpha: 0.94),
            stroke: accentGreen,
            in: context
        )
        drawSymbolGlyph(
            symbolName,
            at: NSPoint(x: rect.midX, y: rect.midY),
            pointSize: symbolPointSize,
            in: context
        )
    }

    enum SelectionAction { case delete, edit }

    /// Top-right action buttons (delete, edit) — clicked, not dragged.
    private func hitTestSelectionAction(at point: NSPoint) -> SelectionAction? {
        guard
            let idx = selectedIndex,
            idx < annotations.count
        else { return nil }
        let annotation = annotations[idx]

        if deleteButtonRect(for: annotation).contains(point) {
            return .delete
        }
        if let editRect = editButtonRect(for: annotation), editRect.contains(point) {
            return .edit
        }
        return nil
    }

    private func hitTestSelectionHandle(at point: NSPoint) -> HandleDragState.Kind? {
        guard
            let idx = selectedIndex,
            idx < annotations.count
        else { return nil }
        let annotation = annotations[idx]

        if annotation.supportsRotation {
            let handleCenter = rotationHandleCenter(for: annotation)
            let r = EditCanvasView.rotateHandleSize / 2 + 2
            if hypot(point.x - handleCenter.x, point.y - handleCenter.y) <= r {
                return .rotate
            }
        }

        // Tip handle wins over curve when both apply (numbered badges with
        // a short shaft) — the arrowhead is the more visually salient grab
        // target.
        if let tip = tipHandleCenter(for: annotation) {
            let r = EditCanvasView.tipHandleSize / 2 + 4
            if hypot(point.x - tip.x, point.y - tip.y) <= r {
                return .tip
            }
        }

        if let cp = curveHandleCenter(for: annotation) {
            let r = EditCanvasView.curveHandleSize / 2 + 4
            if hypot(point.x - cp.x, point.y - cp.y) <= r {
                return .curve
            }
        }

        return nil
    }

    private func applyHandleDrag(state: HandleDragState, currentMouse: NSPoint) {
        guard state.index < annotations.count else { return }

        switch state.kind {
        case .rotate:
            let original = state.original
            let center = NSPoint(
                x: original.boundingRect.midX,
                y: original.boundingRect.midY
            )
            let currentAngle = atan2(currentMouse.y - center.y, currentMouse.x - center.x)
            var newRotation = state.startRotation + (currentAngle - state.startAngle)
            // Shift snaps to 15° increments for predictable angles.
            if NSEvent.modifierFlags.contains(.shift) {
                let step = CGFloat.pi / 12
                newRotation = (newRotation / step).rounded() * step
            }
            annotations[state.index] = original.withRotation(newRotation)

        case .curve:
            // Snap back to a straight shaft when the handle is dragged near
            // the geometric midpoint, so the user can undo a curve without
            // having to land precisely on the original mid pixel.
            if let arrow = state.original as? ArrowAnnotation {
                let mid = arrow.defaultCurveMid
                if hypot(currentMouse.x - mid.x, currentMouse.y - mid.y) < 4 {
                    annotations[state.index] = arrow.withControlPoint(nil)
                } else {
                    annotations[state.index] = arrow.withControlPoint(currentMouse)
                }
            } else if let number = state.original as? NumberAnnotation,
                      let mid = number.defaultCurveMid {
                if hypot(currentMouse.x - mid.x, currentMouse.y - mid.y) < 4 {
                    annotations[state.index] = number.withControlPoint(nil)
                } else {
                    annotations[state.index] = number.withControlPoint(currentMouse)
                }
            }

        case .tip:
            guard let number = state.original as? NumberAnnotation else { return }
            // Snap to "no arrow" when the tip is dragged back inside the
            // badge so the user can ditch the arrow without precisely
            // landing on the badge center.
            let dist = hypot(currentMouse.x - number.center.x, currentMouse.y - number.center.y)
            if dist < NumberAnnotation.arrowMinDistance {
                annotations[state.index] = number.withTip(nil)
            } else {
                annotations[state.index] = number.withTip(currentMouse)
            }
        }

        needsDisplay = true
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        // Let whatever's underneath manage its own cursor.
        NSCursor.arrow.set()
    }

    private func updateCursor(at point: NSPoint) {
        // Don't fight the text field's I-beam while editing.
        if activeTextField != nil { return }
        // Action buttons on the selection chrome: pointing finger.
        if hitTestSelectionAction(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        // Drag handles (rotate / curve / number tip): open hand — they're
        // grabbable.
        if hitTestSelectionHandle(at: point) != nil {
            NSCursor.openHand.set()
            return
        }
        // Hovering over any draggable mark: open hand so the user knows it
        // can be picked up regardless of the active tool.
        if hitTestAnnotation(at: point) != nil {
            NSCursor.openHand.set()
            return
        }
        NSCursor.arrow.set()
    }

    /// Convert the global mouse location into view coords and refresh the
    /// cursor. Used after operations that change what's draggable (undo,
    /// commit, tool change) so the cursor doesn't lie until the next move.
    private func refreshCursorAtCurrentLocation() {
        guard let window else { return }
        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let local = convert(mouseInWindow, from: nil)
        guard bounds.contains(local) else { return }
        updateCursor(at: local)
    }
}

// MARK: - Editable Text Field

/// Borderless transparent NSTextField that auto-grows to fit its content
/// and reports commit/cancel via closures. Used by the text annotation
/// tool while the user is typing.
final class EditableTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var didFinish = false
    private var wasCanceled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        isBordered = false
        isBezeled = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        delegate = self
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        target = self
        action = #selector(commitFromAction)
        stringValue = ""
        placeholderString = ""

        // Visible editing border so the user can tell where the field is on
        // screen (the rest of the field is fully transparent over the
        // canvas content).
        wantsLayer = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
    }

    @objc private func commitFromAction() {
        commit()
    }

    func commit() {
        guard !didFinish else { return }
        didFinish = true
        onCommit?(stringValue)
    }

    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        onCancel?()
    }

    func controlTextDidChange(_ obj: Notification) {
        sizeToFitText()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !didFinish else { return }
        if wasCanceled {
            cancel()
        } else {
            commit()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            wasCanceled = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    /// The app has no main menu, so standard editing key equivalents
    /// (⌘A/⌘C/⌘V/⌘X/⌘Z/⇧⌘Z) never reach the field editor. Route them
    /// here while we hold focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if mods == cmd {
            switch chars {
            case "a": currentEditor()?.selectAll(nil); return true
            case "c": currentEditor()?.copy(nil); return true
            case "v": currentEditor()?.paste(nil); return true
            case "x": currentEditor()?.cut(nil); return true
            case "z":
                if let undoMgr = currentEditor()?.undoManager, undoMgr.canUndo {
                    undoMgr.undo(); return true
                }
            default: break
            }
        } else if mods == cmdShift, chars == "z" {
            if let undoMgr = currentEditor()?.undoManager, undoMgr.canRedo {
                undoMgr.redo(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Recompute width/height from the current string + font, keeping the
    /// top edge anchored so text grows downward only when font size changes.
    func sizeToFitText() {
        guard let font = font else { return }
        let size = TextAnnotation.editorSize(for: stringValue, font: font)

        let prevTop = frame.maxY
        var f = frame
        f.size = size
        f.origin.y = prevTop - size.height
        frame = f
    }
}
