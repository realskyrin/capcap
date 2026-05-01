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
    /// Active click/drag interaction on a committed text annotation. Captured
    /// in `mouseDown` and resolved in `mouseUp` (click → edit) or
    /// `mouseDragged` (drag → reposition). Using natural AppKit event
    /// callbacks instead of a synchronous `nextEvent` loop avoids losing
    /// events to scroll-view ancestors and other edge cases.
    private var textInteractionState: TextInteractionState?
    private let textDragThreshold: CGFloat = 4
    /// Active click/drag interaction for the numbered tool. mouseDown only
    /// records intent — either dragging an existing badge or pending a new
    /// one. mouseUp finalizes: pending+no-drag adds the number; drag of an
    /// existing badge just commits its new position. This makes "press" no
    /// longer commit a number until the click is fully released.
    private var numberInteractionState: NumberInteractionState?
    private let numberDragThreshold: CGFloat = 4
    private let numberHitRadius: CGFloat = 14

    private struct TextInteractionState {
        enum Kind {
            case existing(index: Int, mouseOffset: NSPoint, originalAnnotation: TextAnnotation)
            /// Click on empty canvas. The new editor opens on mouseUp only
            /// if the cursor stayed put. `wasEditing` records whether a
            /// previous text field was just committed by this same click —
            /// in that case the click is consumed and no new field opens.
            case pendingCreate(point: NSPoint, wasEditing: Bool)
        }
        var kind: Kind
        let startPoint: NSPoint
        var didDrag: Bool
    }

    private struct NumberInteractionState {
        enum Kind {
            case dragExisting(index: Int, mouseOffset: NSPoint)
            case pendingCreate(point: NSPoint)
        }
        var kind: Kind
        let startPoint: NSPoint
        var didDrag: Bool
    }

    var hasPreviewImage: Bool { previewImage != nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While previewing a merged long screenshot, keep the canvas interactive
        // so scroll-wheel gestures stay inside the preview viewport.
        guard activeTool != .none || hasPreviewImage else { return nil }
        return super.hitTest(point)
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
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        guard activeTool != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

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
            if let idx = numberAnnotationIndex(at: point),
               let existing = annotations[idx] as? NumberAnnotation {
                numberInteractionState = NumberInteractionState(
                    kind: .dragExisting(
                        index: idx,
                        mouseOffset: NSPoint(
                            x: point.x - existing.center.x,
                            y: point.y - existing.center.y
                        )
                    ),
                    startPoint: point,
                    didDrag: false
                )
            } else {
                numberInteractionState = NumberInteractionState(
                    kind: .pendingCreate(point: point),
                    startPoint: point,
                    didDrag: false
                )
            }

        case .text:
            handleTextMouseDown(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch activeTool {
        case .none, .scrollCapture:
            return

        case .numbered:
            guard var state = numberInteractionState else { return }
            if !state.didDrag {
                let distance = hypot(point.x - state.startPoint.x, point.y - state.startPoint.y)
                guard distance >= numberDragThreshold else { return }
                state.didDrag = true
                numberInteractionState = state
            }
            if case .dragExisting(let idx, let offset) = state.kind {
                moveNumberAnnotation(at: idx, keepingMouseAt: point, offset: offset)
                needsDisplay = true
            }
            return

        case .text:
            guard var state = textInteractionState else { return }
            if !state.didDrag {
                let distance = hypot(point.x - state.startPoint.x, point.y - state.startPoint.y)
                guard distance >= textDragThreshold else { return }
                state.didDrag = true
                textInteractionState = state
            }
            if case .existing(let idx, let offset, _) = state.kind {
                moveTextAnnotation(at: idx, keepingMouseAt: point, offset: offset)
                needsDisplay = true
            }
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
        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .scrollCapture:
            return

        case .numbered:
            guard let state = numberInteractionState else { return }
            numberInteractionState = nil
            switch state.kind {
            case .dragExisting:
                // Drag committed in-place; nothing else to do.
                break
            case .pendingCreate(let point):
                // Only count as a click if the cursor stayed put. A drag on
                // empty canvas is a canceled click and adds nothing.
                guard !state.didDrag else { return }
                annotations.append(NumberAnnotation(
                    center: point,
                    number: numberCounter,
                    color: currentColor
                ))
                numberCounter += 1
                needsDisplay = true
            }
            return

        case .text:
            // Click-without-drag on an existing annotation re-enters edit
            // mode. Click-without-drag on empty canvas opens a fresh field
            // (unless the same click just committed a previous edit). A
            // drag in either case is a reposition / canceled click and
            // commits no new editor.
            guard let state = textInteractionState else { return }
            textInteractionState = nil
            switch state.kind {
            case .existing(let idx, _, let original):
                if !state.didDrag {
                    reEditTextAnnotation(at: idx, annotation: original)
                }
            case .pendingCreate(let point, let wasEditing):
                guard !state.didDrag, !wasEditing else { return }
                beginTextEditing(
                    bottomLeft: newTextOrigin(forClickAt: point, fontSize: currentFontSize),
                    fontSize: currentFontSize,
                    color: currentColor
                )
            }
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
        textInteractionState = nil
        numberInteractionState = nil
        activeTextField?.cancel()
    }

    private func numberAnnotationIndex(at point: NSPoint) -> Int? {
        let radiusSquared = numberHitRadius * numberHitRadius
        for i in annotations.indices.reversed() {
            if let n = annotations[i] as? NumberAnnotation {
                let dx = point.x - n.center.x
                let dy = point.y - n.center.y
                if dx * dx + dy * dy <= radiusSquared {
                    return i
                }
            }
        }
        return nil
    }

    private func moveNumberAnnotation(at index: Int, keepingMouseAt point: NSPoint, offset: NSPoint) {
        guard index < annotations.count,
              let existing = annotations[index] as? NumberAnnotation
        else { return }
        annotations[index] = NumberAnnotation(
            center: NSPoint(x: point.x - offset.x, y: point.y - offset.y),
            number: existing.number,
            color: existing.color
        )
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

    private func handleTextMouseDown(at point: NSPoint) {
        let wasEditing = activeTextField != nil
        activeTextField?.commit()

        if let idx = textAnnotationIndex(at: point),
           let existing = annotations[idx] as? TextAnnotation {
            textInteractionState = TextInteractionState(
                kind: .existing(
                    index: idx,
                    mouseOffset: NSPoint(
                        x: point.x - existing.origin.x,
                        y: point.y - existing.origin.y
                    ),
                    originalAnnotation: existing
                ),
                startPoint: point,
                didDrag: false
            )
            return
        }

        // Defer opening the text editor until mouseUp — a press that ends
        // up dragging away on empty canvas should not pop a field.
        textInteractionState = TextInteractionState(
            kind: .pendingCreate(point: point, wasEditing: wasEditing),
            startPoint: point,
            didDrag: false
        )
    }

    private func editTextAnnotation(at index: Int, fallback: TextAnnotation) {
        let existing: TextAnnotation
        if index < annotations.count, let current = annotations[index] as? TextAnnotation {
            existing = current
        } else {
            existing = fallback
        }

        beginTextEditing(
            bottomLeft: existing.origin,
            fontSize: existing.fontSize,
            color: existing.color,
            initialText: existing.text,
            replacingIndex: index
        )
    }

    private func moveTextAnnotation(at index: Int, keepingMouseAt point: NSPoint, offset: NSPoint) {
        guard index < annotations.count,
              let existing = annotations[index] as? TextAnnotation
        else {
            return
        }

        annotations[index] = TextAnnotation(
            text: existing.text,
            origin: NSPoint(
                x: point.x - offset.x,
                y: point.y - offset.y
            ),
            color: existing.color,
            fontSize: existing.fontSize
        )
    }

    private func textAnnotationIndex(at point: NSPoint) -> Int? {
        for i in annotations.indices.reversed() {
            if let text = annotations[i] as? TextAnnotation,
               text.hitBounds.contains(point) {
                return i
            }
        }
        return nil
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
    }

    private func rectFromTwoPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
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

