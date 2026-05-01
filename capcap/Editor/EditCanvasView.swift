import AppKit

enum EditTool {
    case none
    case pen
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
    /// Pending number creation — committed on mouseUp only if the cursor
    /// stayed put. A drag on empty canvas is a canceled click.
    private var pendingNumberCreate: NSPoint?
    /// Pending text creation — same idea as number, plus a `wasEditing` flag
    /// so a click that just committed an in-progress field doesn't pop a new
    /// one.
    private var pendingTextCreate: PendingTextCreate?
    private let dragThreshold: CGFloat = 4

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
        // In adjust mode (no tool, no preview) we still want to capture
        // clicks that land on an existing draggable annotation so the user
        // can grab and move them. Empty clicks fall through to the layers
        // beneath, preserving the live overlay's pass-through behavior.
        let local = convert(point, from: superview)
        if hitTestAnnotation(at: local) != nil {
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
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

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
            EditCanvasView.moveCursor.set()
            return
        }

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

        case .mosaic:
            mosaicBaseImage = resolveBaseImageForEditing()
            currentMosaicPoints = [point]

        case .rectangle, .ellipse, .arrow:
            shapeStart = point
            shapeCurrent = point

        case .numbered:
            pendingNumberCreate = point

        case .text:
            let wasEditing = activeTextField != nil
            activeTextField?.commit()
            pendingTextCreate = PendingTextCreate(point: point, wasEditing: wasEditing)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

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

        // Drag away from a pending create cancels it (and adds nothing).
        if let p = pendingNumberCreate {
            if hypot(point.x - p.x, point.y - p.y) >= dragThreshold {
                pendingNumberCreate = nil
            }
            return
        }
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

        case .mosaic:
            currentMosaicPoints.append(point)
            needsDisplay = true

        case .rectangle, .ellipse, .arrow:
            shapeCurrent = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 1. Drag interaction on existing annotation
        if let state = dragState {
            dragState = nil
            if !state.didDrag {
                // Click without drag. Text annotations re-enter edit mode for
                // convenience; other types just deselect (no-op).
                if let textAnnotation = state.original as? TextAnnotation {
                    reEditTextAnnotation(at: state.index, annotation: textAnnotation)
                }
            }
            refreshCursorAtCurrentLocation()
            return
        }

        // 2. Pending number create
        if let p = pendingNumberCreate {
            pendingNumberCreate = nil
            annotations.append(NumberAnnotation(
                center: p,
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

        // Draw all committed annotations
        for annotation in annotations {
            annotation.draw(in: context, bounds: bounds)
        }

        // Draw in-progress pen stroke
        if let path = currentPenPath {
            currentColor.setStroke()
            path.lineWidth = currentLineWidth
            path.stroke()
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
                annotation.draw(in: context, bounds: imageBounds)
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
        currentMosaicPoints = []
        mosaicBaseImage = nil
        shapeStart = nil
        shapeCurrent = nil
        dragState = nil
        pendingNumberCreate = nil
        pendingTextCreate = nil
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

    // MARK: - Cursor

    /// Custom 4-way arrow cursor shown while hovering over a draggable mark.
    /// AppKit doesn't expose a public "move" cursor, so we render the SF
    /// Symbol with a 1px black halo so it's readable on any background.
    static let moveCursor: NSCursor = makeMoveCursor()

    private static func makeMoveCursor() -> NSCursor {
        let symbolName = "arrow.up.and.down.and.arrow.left.and.right"
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else {
            return NSCursor.crosshair
        }

        let blackTinted = baseImage.tintedTemplate(with: .black)
        let whiteTinted = baseImage.tintedTemplate(with: .white)

        let inset: CGFloat = 2
        let canvasSize = NSSize(
            width: baseImage.size.width + inset * 2,
            height: baseImage.size.height + inset * 2
        )

        let outlinedImage = NSImage(size: canvasSize, flipped: false) { _ in
            let center = NSPoint(x: inset, y: inset)
            for dx in [-1.0, 0.0, 1.0] {
                for dy in [-1.0, 0.0, 1.0] {
                    if dx == 0, dy == 0 { continue }
                    blackTinted.draw(
                        at: NSPoint(x: center.x + dx, y: center.y + dy),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                }
            }
            whiteTinted.draw(
                at: center,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }

        let hotSpot = NSPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return NSCursor(image: outlinedImage, hotSpot: hotSpot)
    }

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
        if hitTestAnnotation(at: point) != nil {
            EditCanvasView.moveCursor.set()
        } else {
            NSCursor.arrow.set()
        }
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

// MARK: - NSImage tinting helper

private extension NSImage {
    /// Render a tinted copy of a template image. Used to build the move
    /// cursor's black halo + white fill.
    func tintedTemplate(with color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
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
