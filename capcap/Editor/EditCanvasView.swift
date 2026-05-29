import AppKit

enum EditTool {
    case none
    case pen
    case marker
    case mosaic
    case eraser
    case magnifier
    case rectangle
    case ellipse
    case arrow
    case line
    case numbered
    case text
    case emoji
    case scrollCapture
}

class EditCanvasView: NSView {
    var captureRect: CGRect?
    var captureScreen: NSScreen?
    var preSnapshot: CGImage?
    /// When set (image-edit mode), this image is the source-of-truth base
    /// instead of preSnapshot/live capture.
    var overrideBaseImage: NSImage?
    /// Exact clicked-window image, including the WindowServer alpha mask.
    var windowBaseImage: NSImage?
    var activeTool: EditTool = .none {
        didSet {
            if oldValue == .text, activeTool != .text {
                activeTextField?.commit()
            }
            if oldValue == .eraser, activeTool != .eraser {
                if eraserSelection?.didDelete != true {
                    discardPendingUndo()
                }
                eraserSelection = nil
            }
            if activeTool == .eraser {
                selectedIndex = nil
            }
            if activeTool != .emoji {
                emojiPreviewPoint = nil
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
    var currentColor: NSColor = EditorStyleDefaults.primaryColor {
        didSet { activeTextField?.textColor = currentColor }
    }
    /// Whether new text annotations get a contrast outline.
    var currentTextStroke: Bool = Defaults.lastTextStroke {
        didSet { activeTextField?.hasStroke = currentTextStroke }
    }
    /// Whether newly drawn rectangles/ellipses should be filled.
    var currentShapeFill: Bool = Defaults.lastShapeFill
    var currentLineWidth: CGFloat = EditorStyleDefaults.standardLineWidth
    var currentArrowStyle: ArrowStyle = Defaults.lastArrowStyle
    /// Base width for the marker brush. Drawn at `× MarkerAnnotation.brushScale`.
    var currentMarkerLineWidth: CGFloat = EditorStyleDefaults.markerLineWidth
    /// Marker uses a separate color slot so switching tools keeps the
    /// highlighter's yellow without overriding the pen's red, and vice-versa.
    var currentMarkerColor: NSColor = EditorStyleDefaults.markerColor
    var currentMosaicBlockSize: CGFloat = CGFloat(Defaults.mosaicBlockSize)
    var currentFontSize: CGFloat = CGFloat(Defaults.lastTextFontSize) {
        didSet {
            guard let field = activeTextField else { return }
            field.font = NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
            field.sizeToFitText()
        }
    }
    var currentEmoji: String? {
        didSet {
            if activeTool == .emoji {
                needsDisplay = true
            }
        }
    }

    // Annotations stack (supports undo)
    private var annotations: [Annotation] = []

    // In-progress drawing state — pen and marker collect raw mouse points
    // and rebuild a smoothed bezier on every change so the live preview
    // matches the committed annotation.
    private var currentPenPoints: [NSPoint]?
    private var currentMarkerPoints: [NSPoint]?
    private var shapeStart: NSPoint?
    private var shapeCurrent: NSPoint?
    /// Base image snapshot captured when a magnifier drag begins, reused for
    /// both the live preview and the committed lens so the (possibly
    /// expensive) base-image lookup happens only once per drag.
    private var magnifierBaseImage: NSImage?
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
    private var emojiPreviewPoint: NSPoint?
    /// Active eraser drag rectangle. Matching annotations are removed as
    /// soon as they intersect the rectangle.
    private var eraserSelection: EraserSelection?
    private let dragThreshold: CGFloat = 4
    /// Primary selected annotation. Existing single-selection paths read this
    /// value for sub-toolbar seeding and handle editing, while `selectedIndexes`
    /// carries the full multi-selection set.
    private var selectedIndex: Int? {
        get { primarySelectedIndex }
        set {
            if let newValue {
                setSelectedIndexes([newValue], primary: newValue)
            } else {
                setSelectedIndexes([], primary: nil)
            }
        }
    }
    private var selectedIndexes: Set<Int> = []
    private var primarySelectedIndex: Int?
    private var hasSelection: Bool { !selectedIndexes.isEmpty }
    private var validSelectedIndexes: [Int] {
        selectedIndexes.filter { annotations.indices.contains($0) }.sorted()
    }

    /// Fired when the selected annotation identity changes — non-nil when a
    /// selection is gained, nil when the selection clears. Used by the
    /// controller to switch the active tool / sub-toolbar to match the
    /// selected annotation and seed it with that annotation's properties.
    var onAnnotationSelected: ((Annotation?) -> Void)?
    /// Fired when selection enters or leaves multi-select mode. The editor
    /// controller uses this to hide sub-toolbars and clear active tools only
    /// for true multi-selection, without disrupting normal drawing flows.
    var onMultiSelectionChanged: ((Bool) -> Void)?
    /// Fired whenever undo / redo availability changes so toolbar buttons can
    /// reflect the real history state instead of acting as no-op controls.
    var onHistoryStateChanged: ((Bool, Bool) -> Void)?
    /// Fired after the emoji tool stamps a sticker so the controller can clear
    /// the pending emoji without leaving the tool.
    var onEmojiStamped: (() -> Void)?
    /// Fired when the user double-clicks the screenshot canvas.
    var onCanvasDoubleClick: (() -> Void)?

    private func notifySelectionChanged() {
        guard let cb = onAnnotationSelected else { return }
        if selectedIndexes.count == 1, let idx = selectedIndex, idx < annotations.count {
            cb(annotations[idx])
        } else {
            cb(nil)
        }
    }

    private func setSelectedIndexes(_ indexes: Set<Int>, primary: Int? = nil) {
        let wasMultiSelecting = selectedIndexes.count > 1
        let validIndexes = Set(indexes.filter { annotations.indices.contains($0) })
        let resolvedPrimary: Int?
        if let primary, validIndexes.contains(primary) {
            resolvedPrimary = primary
        } else if let current = primarySelectedIndex, validIndexes.contains(current) {
            resolvedPrimary = current
        } else {
            resolvedPrimary = validIndexes.max()
        }

        let changed = validIndexes != selectedIndexes || resolvedPrimary != primarySelectedIndex
        selectedIndexes = validIndexes
        primarySelectedIndex = resolvedPrimary
        if changed {
            needsDisplay = true
            let isMultiSelecting = validIndexes.count > 1
            if wasMultiSelecting != isMultiSelecting {
                onMultiSelectionChanged?(isMultiSelecting)
            }
            notifySelectionChanged()
        }
    }

    private func toggleSelection(of index: Int) {
        var next = selectedIndexes
        if next.contains(index) {
            next.remove(index)
            setSelectedIndexes(next)
        } else {
            next.insert(index)
            setSelectedIndexes(next, primary: index)
        }
    }

    /// The currently selected annotation, if any. Read by the controller
    /// when seeding sub-toolbar values.
    var selectedAnnotation: Annotation? {
        guard selectedIndexes.count == 1, let idx = selectedIndex, idx < annotations.count else { return nil }
        return annotations[idx]
    }

    @discardableResult
    func clearMultiSelection() -> Bool {
        guard selectedIndexes.count > 1 else { return false }
        selectedIndex = nil
        return true
    }

    private var handleDragState: HandleDragState?

    private struct DragState {
        let index: Int
        let startMouse: NSPoint
        let originals: [Int: Annotation]
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

    private struct EraserSelection {
        let start: NSPoint
        var current: NSPoint
        var didDelete: Bool
    }

    /// One of the eight resize grips around a resizable annotation — four
    /// corners plus four edge midpoints. Coordinates are y-up (canvas
    /// space), so "top" maps to `maxY`.
    enum ResizeAnchor: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var movesMaxY: Bool { self == .topLeft || self == .top || self == .topRight }

        /// Center of this grip for a given rect, in canvas coordinates.
        func point(in rect: NSRect) -> NSPoint {
            let x: CGFloat = movesMinX ? rect.minX : (movesMaxX ? rect.maxX : rect.midX)
            let y: CGFloat = movesMinY ? rect.minY : (movesMaxY ? rect.maxY : rect.midY)
            return NSPoint(x: x, y: y)
        }
    }

    /// Active drag on a selection handle (rotate / curve / number tip /
    /// resize). The original annotation is captured so escape-style
    /// cancellations (e.g. tool switch mid-drag) can restore it cleanly.
    private struct HandleDragState {
        enum Kind { case rotate, curve, tip, arrowStart, arrowEnd, resize(ResizeAnchor) }
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
    private static let endpointHandleSize: CGFloat = 12
    private static let resizeHandleSize: CGFloat = 10
    private static let actionButtonSize: CGFloat = 22
    /// Small +/- stepper buttons shown under a selected numbered badge.
    private static let numberStepButtonSize: CGFloat = 20
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
        // Empty-canvas click in adjust mode normally falls through to
        // SelectionView so the user can re-crop. But when there's a
        // selection or in-progress text edit to dismiss, capture the
        // click so mouseDown can clear that chrome / commit the field.
        if hasSelection || activeTextField != nil {
            if bounds.contains(local) {
                return super.hitTest(point)
            }
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
                hasStroke: annotation.hasStroke,
                initialText: annotation.text,
                rotation: annotation.rotation,
                replacingIndex: index
            )
        }
    }

    // MARK: - Undo / Redo

    /// History snapshot. Annotations are value-typed (struct) so a plain
    /// array copy is a deep copy of the editor's logical state. The number
    /// counter is included so undo/redo also restores the next-badge value.
    private struct EditorSnapshot {
        let annotations: [Annotation]
        let numberCounter: Int
    }

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Stash for drag-style operations and text edits — captured before the
    /// mutation begins, then either committed (drag actually moved / text
    /// edit produced a change) or discarded (just a click / cancel).
    private var pendingSnapshot: EditorSnapshot?
    private static var annotationPasteboard: [Annotation] = []
    private static let defaultPasteOffset = NSPoint(x: 12, y: -12)

    private func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(annotations: annotations, numberCounter: numberCounter)
    }

    private func apply(_ snapshot: EditorSnapshot) {
        annotations = snapshot.annotations
        numberCounter = snapshot.numberCounter
        setSelectedIndexes(selectedIndexes, primary: primarySelectedIndex)
    }

    /// Push current state onto the undo stack and clear the redo stack.
    /// Call BEFORE any direct, instantaneous mutation (creation / deletion
    /// / text edit commit).
    private func recordUndo() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        notifyHistoryStateChanged()
    }

    /// Stash current state for a drag-style operation. Pair with
    /// `commitPendingUndo()` (drag actually moved) or `discardPendingUndo()`
    /// (just a click / cancel).
    private func captureUndoForPending() {
        pendingSnapshot = currentSnapshot()
    }

    private func commitPendingUndo() {
        guard let snap = pendingSnapshot else { return }
        pendingSnapshot = nil
        undoStack.append(snap)
        redoStack.removeAll()
        notifyHistoryStateChanged()
    }

    private func discardPendingUndo() {
        pendingSnapshot = nil
    }

    @discardableResult
    func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(currentSnapshot())
        apply(prev)
        needsDisplay = true
        notifyHistoryStateChanged()
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(currentSnapshot())
        apply(next)
        needsDisplay = true
        notifyHistoryStateChanged()
        refreshCursorAtCurrentLocation()
        return true
    }

    private func notifyHistoryStateChanged() {
        onHistoryStateChanged?(canUndo, canRedo)
    }

    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        let indexes = validSelectedIndexes
        guard activeTextField == nil, !indexes.isEmpty else {
            return false
        }
        recordUndo()
        for idx in indexes.reversed() {
            annotations.remove(at: idx)
        }
        resetNumberCounterIfNumberAnnotationsAreGone()
        selectedIndex = nil
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    func deleteSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        guard EditCanvasView.isSelectionDeleteKey(event) else { return false }
        return deleteSelectedAnnotation()
    }

    func nudgeSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        let indexes = validSelectedIndexes
        guard
            activeTextField == nil,
            let delta = EditCanvasView.selectionNudgeDelta(for: event),
            !indexes.isEmpty
        else {
            return false
        }
        recordUndo()
        for idx in indexes {
            annotations[idx] = annotations[idx].translated(by: delta)
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    func undoFromKeyboard(for event: NSEvent) -> Bool {
        guard EditCanvasView.isUndoKey(event) else { return false }
        return undo()
    }

    func redoFromKeyboard(for event: NSEvent) -> Bool {
        guard EditCanvasView.isRedoKey(event) else { return false }
        return redo()
    }

    func handleAnnotationClipboardShortcutFromKeyboard(for event: NSEvent) -> Bool {
        guard let shortcut = EditCanvasView.commandShortcutCharacter(for: event) else { return false }
        switch shortcut {
        case "x":
            return cutSelectedAnnotation()
        case "c":
            return copySelectedAnnotation()
        case "v":
            return pasteCopiedAnnotation()
        case "a":
            return selectAllAnnotations()
        default:
            return false
        }
    }

    @discardableResult
    func copySelectedAnnotation() -> Bool {
        let indexes = validSelectedIndexes
        guard activeTextField == nil, indexes.count == 1 else {
            return false
        }
        Self.annotationPasteboard = indexes.map { annotations[$0] }
        return true
    }

    @discardableResult
    func cutSelectedAnnotation() -> Bool {
        guard copySelectedAnnotation() else { return false }
        return deleteSelectedAnnotation()
    }

    @discardableResult
    func pasteCopiedAnnotation() -> Bool {
        let sources = Self.annotationPasteboard
        guard activeTextField == nil, sources.count == 1 else {
            return false
        }
        let offset = pasteOffset(forPasting: sources)
        let pasted = sources.map { $0.translated(by: offset) }
        let firstNewIndex = annotations.count
        recordUndo()
        annotations.append(contentsOf: pasted)
        pasted.forEach(syncNumberCounterAfterAdding)
        setSelectedIndexes(Set(firstNewIndex..<annotations.count), primary: annotations.indices.last)
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    func selectAllAnnotations() -> Bool {
        guard activeTextField == nil, !annotations.isEmpty else {
            return false
        }
        setSelectedIndexes(Set(annotations.indices), primary: annotations.indices.last)
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    func insertEmoji(_ emoji: String) -> Bool {
        activeTextField?.commit()
        let rect = emojiRect(centeredAt: insertionCenter())
        recordUndo()
        annotations.append(EmojiAnnotation(emoji: emoji, rect: rect))
        selectedIndex = annotations.indices.last
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    private func stampCurrentEmoji(at point: NSPoint) -> Bool {
        guard let currentEmoji else { return false }
        activeTextField?.commit()
        recordUndo()
        annotations.append(EmojiAnnotation(
            emoji: currentEmoji,
            rect: emojiRect(centeredAt: point)
        ))
        selectedIndex = annotations.indices.last
        emojiPreviewPoint = point
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    func insertImage(_ image: NSImage) -> Bool {
        activeTextField?.commit()
        let size = fittedInsertedImageSize(for: image)
        guard size.width > 0, size.height > 0 else { return false }
        let rect = insertionRect(size: size)
        recordUndo()
        annotations.append(ImageAnnotation(image: image, rect: rect))
        selectedIndex = annotations.indices.last
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    private func fittedInsertedImageSize(for image: NSImage) -> NSSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let maxWidth = min(max(24, bounds.width - 16), 360)
        let maxHeight = min(max(24, bounds.height - 16), 360)
        let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func insertionRect(size: NSSize) -> NSRect {
        let center = insertionCenter()
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        return clampedInsertionRect(NSRect(origin: origin, size: size))
    }

    private func emojiRect(centeredAt point: NSPoint) -> NSRect {
        let size = NSSize(width: 44, height: 44)
        return clampedInsertionRect(NSRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    private func insertionCenter() -> NSPoint {
        if let cursorPoint = currentMousePointInCanvas(), bounds.contains(cursorPoint) {
            return cursorPoint
        }
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }

    private func clampedInsertionRect(_ rect: NSRect) -> NSRect {
        let margin: CGFloat = 8
        var result = rect
        let available = bounds.insetBy(dx: margin, dy: margin)

        if result.width <= available.width {
            result.origin.x = min(max(result.minX, available.minX), available.maxX - result.width)
        } else {
            result.origin.x = bounds.midX - result.width / 2
        }

        if result.height <= available.height {
            result.origin.y = min(max(result.minY, available.minY), available.maxY - result.height)
        } else {
            result.origin.y = bounds.midY - result.height / 2
        }

        return result
    }

    // MARK: - Selection adjustment (sub-toolbar driven)

    /// True between `beginSelectionAdjustment()` and `commitSelectionAdjustment()`
    /// once a live mutate has actually changed the annotation. Used to
    /// suppress no-op undo entries when the user clicks the slider but
    /// doesn't drag.
    private var selectionAdjustmentDirty: Bool = false

    /// Capture the pre-mutation snapshot for an in-progress sub-toolbar
    /// adjustment (e.g. slider drag). No-op when nothing is selected, so
    /// idle slider clicks don't pollute the undo stack.
    func beginSelectionAdjustment() {
        guard selectedIndexes.count == 1 else { return }
        captureUndoForPending()
        selectionAdjustmentDirty = false
    }

    func commitSelectionAdjustment() {
        if selectionAdjustmentDirty {
            commitPendingUndo()
        } else {
            discardPendingUndo()
        }
        selectionAdjustmentDirty = false
    }

    /// Atomic mutation to the selected annotation — captures undo, applies
    /// the transform, redraws. Used by color taps and discrete size dots
    /// where there's no drag to batch.
    func mutateSelectedAnnotationAtomic(_ transform: (Annotation) -> Annotation) {
        guard selectedIndexes.count == 1, let idx = selectedIndex, idx < annotations.count else { return }
        let original = annotations[idx]
        let updated = transform(original)
        guard !annotationsEqualEnough(updated, original) else { return }
        recordUndo()
        annotations[idx] = updated
        syncNumberCounterAfterMutation(from: original, to: updated)
        needsDisplay = true
    }

    /// Live mutation during a slider drag — caller is responsible for
    /// `beginSelectionAdjustment` / `commitSelectionAdjustment` bookending.
    func mutateSelectedAnnotationLive(_ transform: (Annotation) -> Annotation) {
        guard selectedIndexes.count == 1, let idx = selectedIndex, idx < annotations.count else { return }
        let original = annotations[idx]
        let updated = transform(original)
        guard !annotationsEqualEnough(updated, original) else { return }
        annotations[idx] = updated
        syncNumberCounterAfterMutation(from: original, to: updated)
        selectionAdjustmentDirty = true
        needsDisplay = true
    }

    func mutateSelectedMosaicBlockSizeLive(_ blockSize: CGFloat) {
        guard let baseImage = resolveBaseImageForEditing() else { return }
        let imageSize = bounds.size
        mutateSelectedAnnotationLive { annotation in
            guard
                let mosaic = annotation as? MosaicAnnotation,
                let region = MosaicTool.createMosaicRegion(
                    rect: mosaic.rect,
                    imageSize: imageSize,
                    baseImage: baseImage,
                    blockSize: blockSize
                )
            else {
                return annotation
            }
            return MosaicAnnotation(
                rect: region.rect,
                pixelatedImage: region.pixelatedImage,
                blockSize: blockSize
            )
        }
    }

    private func syncNumberCounterAfterMutation(from original: Annotation, to updated: Annotation) {
        guard
            let oldNumber = original as? NumberAnnotation,
            let newNumber = updated as? NumberAnnotation,
            oldNumber.number != newNumber.number
        else { return }
        numberCounter = max(1, newNumber.number + 1)
    }

    private func syncNumberCounterAfterAdding(_ annotation: Annotation) {
        guard let number = annotation as? NumberAnnotation else { return }
        numberCounter = max(numberCounter, number.number + 1)
    }

    private func pasteOffset(forPasting annotations: [Annotation]) -> NSPoint {
        if let cursorPoint = currentMousePointInCanvas(), bounds.contains(cursorPoint) {
            let rect = combinedBoundingRect(for: annotations)
            return NSPoint(x: cursorPoint.x - rect.midX, y: cursorPoint.y - rect.midY)
        }
        return adjacentPasteOffsetKeepingAnnotationsVisible(annotations)
    }

    private func currentMousePointInCanvas() -> NSPoint? {
        guard let window else { return nil }
        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        return convert(mouseInWindow, from: nil)
    }

    private func adjacentPasteOffsetKeepingAnnotationsVisible(_ annotations: [Annotation]) -> NSPoint {
        let margin: CGFloat = 4
        var offset = Self.defaultPasteOffset
        let pastedRect = combinedBoundingRect(for: annotations.map { $0.translated(by: offset) })

        if pastedRect.maxX > bounds.maxX - margin {
            offset.x -= pastedRect.maxX - (bounds.maxX - margin)
        }
        if pastedRect.minX < bounds.minX + margin {
            offset.x += (bounds.minX + margin) - pastedRect.minX
        }
        if pastedRect.maxY > bounds.maxY - margin {
            offset.y -= pastedRect.maxY - (bounds.maxY - margin)
        }
        if pastedRect.minY < bounds.minY + margin {
            offset.y += (bounds.minY + margin) - pastedRect.minY
        }

        return offset
    }

    private func combinedBoundingRect(for annotations: [Annotation]) -> NSRect {
        guard let first = annotations.first?.boundingRect else { return .zero }
        return annotations.dropFirst().reduce(first) { $0.union($1.boundingRect) }
    }

    private func resetNumberCounterIfNumberAnnotationsAreGone() {
        if !annotations.contains(where: { $0 is NumberAnnotation }) {
            numberCounter = 1
        }
    }

    /// Cheap identity check — guards atomic mutations from registering a
    /// no-op undo entry when the user clicks the swatch that's already
    /// selected. Annotations are value types but compare via property
    /// snapshots since the protocol itself isn't Equatable.
    private func annotationsEqualEnough(_ a: Annotation, _ b: Annotation) -> Bool {
        if let a = a as? TextAnnotation, let b = b as? TextAnnotation {
            return a.text == b.text && a.origin == b.origin
                && a.fontSize == b.fontSize && a.rotation == b.rotation
                && a.color == b.color && a.hasStroke == b.hasStroke
        }
        if let a = a as? PenAnnotation, let b = b as? PenAnnotation {
            return a.path === b.path && a.lineWidth == b.lineWidth
                && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? MarkerAnnotation, let b = b as? MarkerAnnotation {
            return a.path === b.path && a.lineWidth == b.lineWidth
                && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? RectAnnotation, let b = b as? RectAnnotation {
            return a.rect == b.rect && a.lineWidth == b.lineWidth
                && a.filled == b.filled && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? EllipseAnnotation, let b = b as? EllipseAnnotation {
            return a.rect == b.rect && a.lineWidth == b.lineWidth
                && a.filled == b.filled && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? ArrowAnnotation, let b = b as? ArrowAnnotation {
            return a.startPoint == b.startPoint && a.endPoint == b.endPoint
                && a.controlPoint == b.controlPoint && a.style == b.style
                && a.lineWidth == b.lineWidth && a.color == b.color
        }
        if let a = a as? LineAnnotation, let b = b as? LineAnnotation {
            return a.startPoint == b.startPoint && a.endPoint == b.endPoint
                && a.lineWidth == b.lineWidth && a.color == b.color
        }
        if let a = a as? NumberAnnotation, let b = b as? NumberAnnotation {
            return a.center == b.center && a.tip == b.tip
                && a.controlPoint == b.controlPoint && a.number == b.number
                && a.color == b.color
        }
        if let a = a as? MosaicAnnotation, let b = b as? MosaicAnnotation {
            return a.rect == b.rect && a.blockSize == b.blockSize
        }
        if let a = a as? ImageAnnotation, let b = b as? ImageAnnotation {
            return a.image === b.image && a.rect == b.rect && a.rotation == b.rotation
        }
        if let a = a as? EmojiAnnotation, let b = b as? EmojiAnnotation {
            return a.emoji == b.emoji && a.rect == b.rect && a.rotation == b.rotation
        }
        return false
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let isShiftSelecting = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)

        // Action buttons (delete / edit) — clicked, not dragged.
        if !isShiftSelecting,
           let action = hitTestSelectionAction(at: point),
           let idx = selectedIndex {
            activeTextField?.commit()
            switch action {
            case .delete:
                _ = deleteSelectedAnnotation()
            case .edit:
                if let textAnnotation = annotations[idx] as? TextAnnotation {
                    reEditTextAnnotation(at: idx, annotation: textAnnotation)
                }
            case .incrementNumber:
                mutateSelectedAnnotationAtomic { annotation in
                    guard let n = annotation as? NumberAnnotation else { return annotation }
                    return n.withNumber(n.number + 1)
                }
            case .decrementNumber:
                // Sequence badges start at 1 — clamp so "−" can't go lower.
                mutateSelectedAnnotationAtomic { annotation in
                    guard let n = annotation as? NumberAnnotation else { return annotation }
                    return n.withNumber(max(1, n.number - 1))
                }
            }
            return
        }

        if activeTool == .eraser {
            activeTextField?.commit()
            selectedIndex = nil
            eraserSelection = EraserSelection(start: point, current: point, didDelete: false)
            captureUndoForPending()
            EditCanvasView.eraserCursor.set()
            needsDisplay = true
            return
        }

        // Selection handles (rotate / curve / tip) take priority over body
        // drags so the user can grab a handle that visually overlaps the
        // annotation it controls.
        if !isShiftSelecting,
           let kind = hitTestSelectionHandle(at: point),
           let idx = selectedIndex {
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
            captureUndoForPending()
            NSCursor.closedHand.set()
            return
        }

        // Universal: clicking on any draggable existing annotation starts a
        // drag, regardless of which tool is selected (or none). Drawing tools
        // only take over for clicks on empty canvas.
        if let idx = hitTestAnnotation(at: point) {
            // Commit any in-progress text edit before grabbing something else.
            activeTextField?.commit()
            if event.clickCount >= 2, activeTool == .none, !isShiftSelecting {
                if selectedIndexes.count == 1,
                   selectedIndex == idx,
                   let textAnnotation = annotations[idx] as? TextAnnotation {
                    reEditTextAnnotation(at: idx, annotation: textAnnotation)
                } else {
                    onCanvasDoubleClick?()
                }
                return
            }
            if isShiftSelecting {
                toggleSelection(of: idx)
                refreshCursorAtCurrentLocation()
                return
            }
            if event.clickCount >= 2,
               selectedIndexes.count == 1,
               selectedIndex == idx,
               let textAnnotation = annotations[idx] as? TextAnnotation {
                reEditTextAnnotation(at: idx, annotation: textAnnotation)
                return
            }
            if selectedIndexes.contains(idx), selectedIndexes.count > 1 {
                setSelectedIndexes(selectedIndexes, primary: idx)
            } else {
                selectedIndex = idx
            }
            let originals = Dictionary(
                uniqueKeysWithValues: validSelectedIndexes.map { ($0, annotations[$0]) }
            )
            dragState = DragState(
                index: idx,
                startMouse: point,
                originals: originals,
                didDrag: false
            )
            captureUndoForPending()
            NSCursor.closedHand.set()
            return
        }

        if event.clickCount >= 2, activeTool == .none {
            activeTextField?.commit()
            onCanvasDoubleClick?()
            return
        }

        // Click on empty canvas: commit any in-progress text edit and
        // clear the current selection so adjust-mode chrome dismisses;
        // the active tool then takes over (if any).
        activeTextField?.commit()
        selectedIndex = nil

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .scrollCapture, .eraser:
            return

        case .emoji:
            if stampCurrentEmoji(at: point) {
                onEmojiStamped?()
            }

        case .pen:
            currentPenPoints = [point]

        case .marker:
            currentMarkerPoints = [point]

        case .rectangle, .ellipse, .arrow, .line, .mosaic:
            shapeStart = point
            shapeCurrent = point

        case .magnifier:
            shapeStart = point
            shapeCurrent = point
            // Resolve the base image once; both the live preview and the
            // committed lens sample it.
            magnifierBaseImage = resolveBaseImageForEditing()

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
            // First mutation of the handle drag — commit the pre-drag snapshot
            // so undo can roll back to before the rotate/curve/tip.
            commitPendingUndo()
            applyHandleDrag(state: state, currentMouse: point)
            return
        }

        if var state = dragState {
            if !state.didDrag {
                let distance = hypot(point.x - state.startMouse.x, point.y - state.startMouse.y)
                guard distance >= dragThreshold else { return }
                state.didDrag = true
                dragState = state
                commitPendingUndo()
            }
            let delta = NSPoint(
                x: point.x - state.startMouse.x,
                y: point.y - state.startMouse.y
            )
            var didMove = false
            for (idx, original) in state.originals where idx < annotations.count {
                annotations[idx] = original.translated(by: delta)
                didMove = true
            }
            if didMove {
                needsDisplay = true
            }
            return
        }

        if eraserSelection != nil {
            updateEraserSelection(to: point)
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
        case .none, .scrollCapture, .numbered, .text, .eraser, .emoji:
            return

        case .pen:
            appendStrokePoint(point, to: &currentPenPoints)
            needsDisplay = true

        case .marker:
            appendStrokePoint(point, to: &currentMarkerPoints)
            needsDisplay = true

        case .rectangle, .ellipse, .arrow, .line, .mosaic, .magnifier:
            shapeCurrent = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 0. Handle drag (rotate / curve) — commit current state and exit.
        if handleDragState != nil {
            handleDragState = nil
            // If the user only clicked a handle without dragging, the
            // pending snapshot was never committed by mouseDragged — drop it
            // so the undo stack doesn't grow no-op entries.
            discardPendingUndo()
            needsDisplay = true
            refreshCursorAtCurrentLocation()
            return
        }

        // 1. Drag interaction on existing annotation. In any tool, a click
        // (with or without drag) keeps the annotation selected so the
        // adjust-mode chrome appears. Drag also moves it.
        if let state = dragState {
            dragState = nil
            // Click without drag → no mutation happened; drop the stash.
            discardPendingUndo()
            if state.didDrag {
                setSelectedIndexes(Set(state.originals.keys), primary: state.index)
            } else {
                selectedIndex = state.index
            }
            refreshCursorAtCurrentLocation()
            return
        }

        if let selection = eraserSelection {
            eraserSelection = nil
            if !selection.didDelete {
                discardPendingUndo()
            }
            needsDisplay = true
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
            recordUndo()
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
                    color: currentColor,
                    hasStroke: currentTextStroke
                )
            }
            return
        }

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .scrollCapture, .numbered, .text, .eraser, .emoji:
            return

        case .pen:
            if let points = currentPenPoints, !points.isEmpty {
                recordUndo()
                annotations.append(PenAnnotation(
                    path: NSBezierPath.smoothed(through: points),
                    color: currentColor,
                    lineWidth: currentLineWidth
                ))
                currentPenPoints = nil
            }

        case .marker:
            if let points = currentMarkerPoints, !points.isEmpty {
                recordUndo()
                annotations.append(MarkerAnnotation(
                    path: NSBezierPath.smoothed(through: points),
                    color: currentMarkerColor,
                    lineWidth: currentMarkerLineWidth
                ))
                currentMarkerPoints = nil
            }

        case .mosaic:
            if let start = shapeStart, let end = shapeCurrent {
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2,
                   let baseImage = resolveBaseImageForEditing(),
                   let region = MosaicTool.createMosaicRegion(
                       rect: rect,
                       imageSize: bounds.size,
                       baseImage: baseImage,
                       blockSize: currentMosaicBlockSize
                   ) {
                    recordUndo()
                    annotations.append(MosaicAnnotation(
                        rect: region.rect,
                        pixelatedImage: region.pixelatedImage,
                        blockSize: currentMosaicBlockSize
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .magnifier:
            if let start = shapeStart, let end = shapeCurrent,
               let baseImage = magnifierBaseImage {
                // The press point is the lens center; the drag distance is
                // its radius, so the lens grows outward from where the user
                // pressed.
                let radius = hypot(end.x - start.x, end.y - start.y)
                if radius >= MagnifierAnnotation.minRadius {
                    recordUndo()
                    annotations.append(MagnifierAnnotation(
                        center: start,
                        radius: radius,
                        zoom: MagnifierAnnotation.defaultZoom,
                        sourceImage: baseImage
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil
            magnifierBaseImage = nil

        case .rectangle:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .rectangle, modifiers: event.modifierFlags)
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    recordUndo()
                    annotations.append(RectAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        filled: currentShapeFill
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .ellipse:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .ellipse, modifiers: event.modifierFlags)
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    recordUndo()
                    annotations.append(EllipseAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        filled: currentShapeFill
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .arrow:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .arrow, modifiers: event.modifierFlags)
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 5 {
                    recordUndo()
                    annotations.append(ArrowAnnotation(
                        startPoint: start,
                        endPoint: end,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        style: currentArrowStyle
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .line:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .line, modifiers: event.modifierFlags)
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 5 {
                    recordUndo()
                    annotations.append(LineAnnotation(
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

    override func flagsChanged(with event: NSEvent) {
        if shapeStart != nil, constrainsShapeWithShift(activeTool) {
            needsDisplay = true
        }
        super.flagsChanged(with: event)
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

        if let image = previewImage ?? externalBaseImage ?? overrideBaseImage ?? windowBaseImage {
            image.draw(in: NSRect(origin: .zero, size: bounds.size))
        }

        // Draw all committed annotations (rotation applied via helper)
        for annotation in annotations {
            annotation.drawApplyingTransforms(in: context, bounds: bounds)
        }

        // Selection chrome — drawn on top so it's always reachable.
        let selected = validSelectedIndexes
        if selected.count == 1, let idx = selected.first {
            drawSelectionHandles(for: annotations[idx], in: context)
        } else {
            for idx in selected {
                drawSelectionOutline(for: annotations[idx], in: context)
            }
        }

        // Draw in-progress pen stroke (smoothed live so the preview matches
        // what gets committed on mouseUp).
        if let points = currentPenPoints, !points.isEmpty {
            let path = NSBezierPath.smoothed(through: points)
            currentColor.setStroke()
            path.lineWidth = currentLineWidth
            path.stroke()
        }

        // Draw in-progress marker stroke (semi-transparent, brush × 6).
        if let points = currentMarkerPoints, !points.isEmpty {
            let path = NSBezierPath.smoothed(through: points)
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
        if let start = shapeStart, let rawCurrent = shapeCurrent {
            let current = constrainedShapeEnd(
                from: start,
                to: rawCurrent,
                tool: activeTool,
                modifiers: NSEvent.modifierFlags
            )
            context.setStrokeColor(currentColor.cgColor)
            context.setLineWidth(currentLineWidth)

            switch activeTool {
            case .rectangle:
                let rect = rectFromTwoPoints(start, current)
                if currentShapeFill {
                    context.setFillColor(currentColor.cgColor)
                    context.fill(rect)
                }
                context.stroke(rect)
            case .ellipse:
                let rect = rectFromTwoPoints(start, current)
                if currentShapeFill {
                    context.setFillColor(currentColor.cgColor)
                    context.fillEllipse(in: rect)
                }
                context.strokeEllipse(in: rect)
            case .mosaic:
                // Mosaic preview: a semi-transparent gray fill marking the
                // region that will be pixelated on mouseUp.
                let rect = rectFromTwoPoints(start, current)
                context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
                context.fill(rect)
            case .line:
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: current)
                context.strokePath()
            case .arrow:
                // Defer to ArrowAnnotation so the live drag preview is
                // pixel-identical to the committed shape — anything else
                // creates a visible snap on mouseUp.
                ArrowAnnotation(
                    startPoint: start,
                    endPoint: current,
                    color: currentColor,
                    lineWidth: currentLineWidth,
                    style: currentArrowStyle
                ).draw(in: context, bounds: bounds)
            case .magnifier:
                // Live lens preview — centered on the press point, radius
                // following the drag, sampling the base image cached when
                // the drag began.
                let radius = hypot(current.x - start.x, current.y - start.y)
                if radius > 6, let baseImage = magnifierBaseImage {
                    MagnifierAnnotation(
                        center: start,
                        radius: radius,
                        zoom: MagnifierAnnotation.defaultZoom,
                        sourceImage: baseImage
                    ).draw(in: context, bounds: bounds)
                }
            default:
                break
            }
        }

        if let eraserSelection {
            drawEraserSelection(
                rectFromTwoPoints(eraserSelection.start, eraserSelection.current),
                in: context
            )
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

        if activeTool == .emoji, let currentEmoji, let emojiPreviewPoint {
            context.saveGState()
            context.setAlpha(0.45)
            EmojiAnnotation(
                emoji: currentEmoji,
                rect: emojiRect(centeredAt: emojiPreviewPoint)
            ).draw(in: context, bounds: bounds)
            context.restoreGState()
        }

        if didClip {
            context.restoreGState()
        }
    }

    private func drawEraserSelection(_ rect: NSRect, in context: CGContext) {
        guard rect.width > 0 || rect.height > 0 else { return }
        context.saveGState()
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.13).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(3)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()
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
        beautifyShadowEnabled: Bool = true,
        wallpaperImage: NSImage? = nil,
        annotationClipMask: NSImage? = nil,
        beautifyInnerClipRadius: CGFloat? = BeautifyRenderer.innerCornerRadius,
        beautifyInnerShadowCornerRadius: CGFloat = BeautifyRenderer.innerCornerRadius,
        beautifyInnerShadowInset: CGFloat = 0
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
            if let annotationClipMask {
                _ = WindowEffects.clip(context, toAlphaOf: annotationClipMask, in: imageBounds)
            }
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
            let rendered = BeautifyRenderer.render(
                innerImage: innerImage,
                preset: preset,
                padding: pad,
                wallpaperImage: wallpaperImage,
                shadowEnabled: beautifyShadowEnabled,
                innerClipRadius: beautifyInnerClipRadius,
                innerShadowCornerRadius: beautifyInnerShadowCornerRadius,
                innerShadowInset: beautifyInnerShadowInset
            )
            return rendered
        }
        return innerImage
    }

    func loadPreviewImage(_ image: NSImage) {
        cancelInFlightInteraction()
        previewImage = image
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

        if let overrideBaseImage {
            return overrideBaseImage
        }

        if let windowBaseImage {
            return windowBaseImage
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
        currentPenPoints = nil
        currentMarkerPoints = nil
        shapeStart = nil
        shapeCurrent = nil
        magnifierBaseImage = nil
        dragState = nil
        handleDragState = nil
        pendingNumberCreate = nil
        pendingTextCreate = nil
        emojiPreviewPoint = nil
        if eraserSelection?.didDelete != true {
            discardPendingUndo()
        }
        eraserSelection = nil
        selectedIndex = nil
        activeTextField?.cancel()
    }

    /// Append a point to a stroke buffer, dropping samples that are too
    /// close to the previous one. Sub-pixel-spaced samples just bloat the
    /// path and amplify noise without adding visible detail.
    private func appendStrokePoint(_ point: NSPoint, to buffer: inout [NSPoint]?) {
        guard buffer != nil else { return }
        if let last = buffer?.last, hypot(point.x - last.x, point.y - last.y) < 1.0 {
            return
        }
        buffer?.append(point)
    }

    /// Topmost annotation under `point` that the user can grab.
    private func hitTestAnnotation(at point: NSPoint) -> Int? {
        for i in annotations.indices.reversed() {
            if annotations[i].containsPoint(point) {
                return i
            }
        }
        return nil
    }

    private func updateEraserSelection(to point: NSPoint) {
        guard var selection = eraserSelection else { return }
        selection.current = point
        eraseAnnotations(in: rectFromTwoPoints(selection.start, point), selection: &selection)
        eraserSelection = selection
        needsDisplay = true
    }

    private func eraseAnnotations(in rect: NSRect, selection: inout EraserSelection) {
        guard rect.width >= 1 || rect.height >= 1 else { return }
        let kept = annotations.filter { !annotationSelectionBounds($0).intersects(rect) }
        guard kept.count != annotations.count else { return }

        if !selection.didDelete {
            commitPendingUndo()
            selection.didDelete = true
        }
        annotations = kept
        selectedIndex = nil
        resetNumberCounterIfNumberAnnotationsAreGone()
        refreshCursorAtCurrentLocation()
    }

    private func annotationSelectionBounds(_ annotation: Annotation) -> NSRect {
        let rect = annotation.boundingRect
        guard annotation.supportsRotation, annotation.rotation != 0 else { return rect }

        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ].map { rotated($0, for: annotation) }

        guard let first = corners.first else { return rect }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in corners.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
        hasStroke: Bool,
        initialText: String = "",
        rotation: CGFloat = 0,
        replacingIndex: Int? = nil
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let lineHeight = TextAnnotation.lineHeight(for: font)

        // Capture the pre-edit state BEFORE we remove a re-edited annotation
        // from the array, so undo can restore the original cleanly.
        captureUndoForPending()

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

        let initialSize = TextAnnotation.editorSize(for: initialText, font: font)
        let fieldRect = NSRect(
            x: bottomLeft.x,
            y: bottomLeft.y,
            width: initialSize.width,
            height: max(initialSize.height, lineHeight)
        )

        let field = EditableTextField(frame: fieldRect)
        field.font = font
        field.textColor = color
        field.hasStroke = hasStroke
        field.rotation = rotation
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
        let wasReEdit = editingOriginalIndex != nil
        if !trimmed.isEmpty {
            let font = field.font ?? NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
            let newAnnotation = TextAnnotation(
                text: text,
                origin: NSPoint(x: field.frame.minX, y: field.frame.minY),
                color: field.textColor ?? currentColor,
                fontSize: font.pointSize,
                rotation: field.rotation,
                hasStroke: field.hasStroke
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
        // Net change happens whenever a new annotation was added OR a
        // re-edit was attempted (re-edit always replaces or removes the
        // original). A no-op fresh-create with empty text leaves state
        // untouched — drop the stash so the undo stack stays clean.
        if !trimmed.isEmpty || wasReEdit {
            commitPendingUndo()
        } else {
            discardPendingUndo()
        }
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
        // Cancel restores the pre-edit state; no net change → no undo entry.
        discardPendingUndo()
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

    private func constrainedShapeEnd(
        from start: NSPoint,
        to end: NSPoint,
        tool: EditTool,
        modifiers: NSEvent.ModifierFlags
    ) -> NSPoint {
        guard modifiers
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        else { return end }

        switch tool {
        case .line, .arrow:
            return axisLockedEnd(from: start, to: end)
        case .rectangle, .ellipse:
            return squareLockedEnd(from: start, to: end)
        default:
            return end
        }
    }

    private func constrainsShapeWithShift(_ tool: EditTool) -> Bool {
        switch tool {
        case .line, .arrow, .rectangle, .ellipse:
            return true
        default:
            return false
        }
    }

    private func axisLockedEnd(from start: NSPoint, to end: NSPoint) -> NSPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dx) >= abs(dy) {
            return NSPoint(x: end.x, y: start.y)
        }
        return NSPoint(x: start.x, y: end.y)
    }

    private func squareLockedEnd(from start: NSPoint, to end: NSPoint) -> NSPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        guard side > 0 else { return end }

        let xSign: CGFloat = dx < 0 ? -1 : 1
        let ySign: CGFloat = dy < 0 ? -1 : 1
        return NSPoint(
            x: start.x + side * xSign,
            y: start.y + side * ySign
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

    /// Start (tail) endpoint handle for a straight/curved arrow or a line —
    /// sits at the `startPoint` so the user can re-anchor that end.
    private func arrowStartHandleCenter(for annotation: Annotation) -> NSPoint? {
        if let arrow = annotation as? ArrowAnnotation { return arrow.startPoint }
        if let line = annotation as? LineAnnotation { return line.startPoint }
        return nil
    }

    /// End endpoint handle — sits at the `endPoint` of an arrow or line so
    /// the user can redirect / re-extend it without rebuilding the mark.
    private func arrowEndHandleCenter(for annotation: Annotation) -> NSPoint? {
        if let arrow = annotation as? ArrowAnnotation { return arrow.endPoint }
        if let line = annotation as? LineAnnotation { return line.endPoint }
        return nil
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

    /// One of the two +/- stepper buttons under a numbered badge.
    /// `.decrement` is the left button, `.increment` the right. They are
    /// anchored to the badge circle (not the bounding box) so they hug the
    /// glyph regardless of any arrow. nil for non-number annotations.
    private func numberStepButtonRect(for annotation: Annotation, increment: Bool) -> NSRect? {
        guard let number = annotation as? NumberAnnotation else { return nil }
        let s = EditCanvasView.numberStepButtonSize
        let gap: CGFloat = 4          // spacing between the two buttons
        let dropBelow: CGFloat = 7    // clearance under the badge circle
        let centerY = number.center.y - NumberAnnotation.radius - dropBelow - s / 2
        let centerX = increment
            ? number.center.x + gap / 2 + s / 2
            : number.center.x - gap / 2 - s / 2
        return NSRect(x: centerX - s / 2, y: centerY - s / 2, width: s, height: s)
    }

    private func drawSelectionOutline(for annotation: Annotation, in context: CGContext) {
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
    }

    private func drawSelectionHandles(for annotation: Annotation, in context: CGContext) {
        // 1. Dashed selection box — rotated with the annotation so it stays
        // wrapped around the visible content at any angle.
        drawSelectionOutline(for: annotation, in: context)

        // 1b. Resize grips — eight dots on the rect's corners + edge mids.
        if isResizable(annotation) {
            for anchor in ResizeAnchor.allCases {
                drawHandleDot(
                    at: resizeHandlePoint(anchor, for: annotation),
                    size: EditCanvasView.resizeHandleSize,
                    fill: NSColor.white.withAlphaComponent(0.95),
                    stroke: accentGreen,
                    in: context
                )
            }
        }

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

        // 4b. Arrow endpoint handles — re-anchor the tail / redirect the tip.
        if let start = arrowStartHandleCenter(for: annotation) {
            drawHandleDot(
                at: start,
                size: EditCanvasView.endpointHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: accentGreen,
                in: context
            )
        }
        if let end = arrowEndHandleCenter(for: annotation) {
            drawHandleDot(
                at: end,
                size: EditCanvasView.endpointHandleSize,
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

        // 7. Number stepper — small +/- buttons under the badge so the
        // user can re-number a sequence badge without re-creating it.
        if let number = annotation as? NumberAnnotation,
           let decRect = numberStepButtonRect(for: annotation, increment: false),
           let incRect = numberStepButtonRect(for: annotation, increment: true) {
            drawActionButton(
                in: decRect,
                symbolName: "minus",
                symbolPointSize: 9,
                enabled: number.number > 1,
                in: context
            )
            drawActionButton(
                in: incRect,
                symbolName: "plus",
                symbolPointSize: 9,
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
    /// rotate / delete / edit glyphs on the action buttons. `alpha` dims the
    /// glyph for disabled buttons (e.g. "−" when the badge is already at 1).
    private func drawSymbolGlyph(
        _ symbolName: String,
        at center: NSPoint,
        pointSize: CGFloat,
        alpha: CGFloat = 1,
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
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: alpha)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Round dark button with an accent ring and a centered SF symbol —
    /// used for delete / edit / number-stepper actions in adjust mode.
    /// `enabled: false` dims the whole button for a no-op state.
    private func drawActionButton(
        in rect: NSRect,
        symbolName: String,
        symbolPointSize: CGFloat,
        enabled: Bool = true,
        in context: CGContext
    ) {
        let alpha: CGFloat = enabled ? 1 : 0.4
        drawHandleDot(
            at: NSPoint(x: rect.midX, y: rect.midY),
            size: rect.width,
            fill: NSColor(white: 0.12, alpha: 0.94 * alpha),
            stroke: accentGreen.withAlphaComponent(alpha),
            in: context
        )
        drawSymbolGlyph(
            symbolName,
            at: NSPoint(x: rect.midX, y: rect.midY),
            pointSize: symbolPointSize,
            alpha: alpha,
            in: context
        )
    }

    enum SelectionAction { case delete, edit, incrementNumber, decrementNumber }

    /// Top-right action buttons (delete, edit) — clicked, not dragged.
    private func hitTestSelectionAction(at point: NSPoint) -> SelectionAction? {
        guard
            selectedIndexes.count == 1,
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
        if let decRect = numberStepButtonRect(for: annotation, increment: false),
           decRect.contains(point) {
            return .decrementNumber
        }
        if let incRect = numberStepButtonRect(for: annotation, increment: true),
           incRect.contains(point) {
            return .incrementNumber
        }
        return nil
    }

    /// True for annotations that expose the eight-grip resize chrome.
    private func isResizable(_ annotation: Annotation) -> Bool {
        annotation is RectAnnotation
            || annotation is EllipseAnnotation
            || annotation is MosaicAnnotation
            || annotation is MagnifierAnnotation
            || annotation is ImageAnnotation
            || annotation is EmojiAnnotation
    }

    private func resizeHandlePoint(_ anchor: ResizeAnchor, for annotation: Annotation) -> NSPoint {
        rotated(anchor.point(in: annotation.boundingRect), for: annotation)
    }

    private func hitTestSelectionHandle(at point: NSPoint) -> HandleDragState.Kind? {
        guard
            selectedIndexes.count == 1,
            let idx = selectedIndex,
            idx < annotations.count
        else { return nil }
        let annotation = annotations[idx]

        // Resize grips — checked first so a corner grip wins over a body
        // drag on the same pixels.
        if isResizable(annotation) {
            let r = EditCanvasView.resizeHandleSize / 2 + 4
            for anchor in ResizeAnchor.allCases {
                let c = resizeHandlePoint(anchor, for: annotation)
                if hypot(point.x - c.x, point.y - c.y) <= r {
                    return .resize(anchor)
                }
            }
        }

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

        // Arrow endpoint handles — checked before the curve handle so the
        // user can grab the tip even if it visually overlaps another handle.
        if let end = arrowEndHandleCenter(for: annotation) {
            let r = EditCanvasView.endpointHandleSize / 2 + 4
            if hypot(point.x - end.x, point.y - end.y) <= r {
                return .arrowEnd
            }
        }
        if let start = arrowStartHandleCenter(for: annotation) {
            let r = EditCanvasView.endpointHandleSize / 2 + 4
            if hypot(point.x - start.x, point.y - start.y) <= r {
                return .arrowStart
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

        case .arrowStart:
            if let arrow = state.original as? ArrowAnnotation {
                annotations[state.index] = arrow.withStartPoint(currentMouse)
            } else if let line = state.original as? LineAnnotation {
                annotations[state.index] = line.withStartPoint(currentMouse)
            }

        case .arrowEnd:
            if let arrow = state.original as? ArrowAnnotation {
                annotations[state.index] = arrow.withEndPoint(currentMouse)
            } else if let line = state.original as? LineAnnotation {
                annotations[state.index] = line.withEndPoint(currentMouse)
            }

        case .resize(let anchor):
            let preserveAspectRatio = NSEvent.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.shift)
            if let magnifier = state.original as? MagnifierAnnotation {
                // Circular lens — keep the center pinned and set the radius
                // to the cursor's distance from it. Every grip behaves the
                // same; it's the natural gesture for a circle.
                let r = hypot(
                    currentMouse.x - magnifier.center.x,
                    currentMouse.y - magnifier.center.y
                )
                guard r >= MagnifierAnnotation.minRadius else { return }
                annotations[state.index] = MagnifierAnnotation(
                    center: magnifier.center,
                    radius: r,
                    zoom: magnifier.zoom,
                    sourceImage: magnifier.sourceImage
                )
            } else if let mosaic = state.original as? MosaicAnnotation {
                // Move only the edge(s) this grip owns; the opposite edge(s)
                // stay pinned. min/abs keep the rect valid if the user drags a
                // grip past its opposite side.
                let newRect = resizedRect(
                    from: mosaic.rect,
                    anchor: anchor,
                    currentMouse: currentMouse,
                    minimumSize: 4,
                    preserveAspectRatio: preserveAspectRatio
                )
                guard newRect.width >= 4, newRect.height >= 4 else { return }
                // Re-pixelate from the untouched base image so the mosaic
                // always covers whatever content the new rect frames (rather
                // than stretching the old pixels).
                guard
                    let baseImage = resolveBaseImageForEditing(),
                    let region = MosaicTool.createMosaicRegion(
                        rect: newRect,
                        imageSize: bounds.size,
                        baseImage: baseImage,
                        blockSize: mosaic.blockSize
                    )
                else { return }
                annotations[state.index] = MosaicAnnotation(
                    rect: region.rect,
                    pixelatedImage: region.pixelatedImage,
                    blockSize: mosaic.blockSize
                )
            } else if let rect = state.original as? RectAnnotation {
                let newRect = resizedRotatedRect(
                    from: rect.rect,
                    rotation: rect.rotation,
                    anchor: anchor,
                    currentMouse: currentMouse,
                    minimumSize: 4,
                    preserveAspectRatio: preserveAspectRatio
                )
                guard newRect.width >= 4, newRect.height >= 4 else { return }
                annotations[state.index] = RectAnnotation(
                    rect: newRect,
                    color: rect.color,
                    lineWidth: rect.lineWidth,
                    filled: rect.filled,
                    rotation: rect.rotation
                )
            } else if let ellipse = state.original as? EllipseAnnotation {
                let newRect = resizedRotatedRect(
                    from: ellipse.rect,
                    rotation: ellipse.rotation,
                    anchor: anchor,
                    currentMouse: currentMouse,
                    minimumSize: 4,
                    preserveAspectRatio: preserveAspectRatio
                )
                guard newRect.width >= 4, newRect.height >= 4 else { return }
                annotations[state.index] = EllipseAnnotation(
                    rect: newRect,
                    color: ellipse.color,
                    lineWidth: ellipse.lineWidth,
                    filled: ellipse.filled,
                    rotation: ellipse.rotation
                )
            } else if let image = state.original as? ImageAnnotation {
                let newRect = resizedRotatedRect(
                    from: image.rect,
                    rotation: image.rotation,
                    anchor: anchor,
                    currentMouse: currentMouse,
                    minimumSize: 12,
                    preserveAspectRatio: preserveAspectRatio
                )
                guard newRect.width >= 12, newRect.height >= 12 else { return }
                annotations[state.index] = image.withRect(newRect)
            } else if let emoji = state.original as? EmojiAnnotation {
                let newRect = resizedRotatedRect(
                    from: emoji.rect,
                    rotation: emoji.rotation,
                    anchor: anchor,
                    currentMouse: currentMouse,
                    minimumSize: 12,
                    preserveAspectRatio: preserveAspectRatio
                )
                guard newRect.width >= 12, newRect.height >= 12 else { return }
                annotations[state.index] = emoji.withRect(newRect)
            }
        }

        needsDisplay = true
    }

    private func resizedRect(
        from original: NSRect,
        anchor: ResizeAnchor,
        currentMouse: NSPoint,
        minimumSize: CGFloat,
        preserveAspectRatio: Bool = false
    ) -> NSRect {
        if preserveAspectRatio {
            return resizedRotatedRect(
                from: original,
                rotation: 0,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: minimumSize,
                preserveAspectRatio: true
            )
        }

        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        if anchor.movesMinX { minX = currentMouse.x }
        if anchor.movesMaxX { maxX = currentMouse.x }
        if anchor.movesMinY { minY = currentMouse.y }
        if anchor.movesMaxY { maxY = currentMouse.y }

        let width = abs(maxX - minX)
        let height = abs(maxY - minY)
        guard width >= minimumSize, height >= minimumSize else {
            return original
        }

        return NSRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: width,
            height: height
        )
    }

    private func resizedRotatedRect(
        from original: NSRect,
        rotation: CGFloat,
        anchor: ResizeAnchor,
        currentMouse: NSPoint,
        minimumSize: CGFloat,
        preserveAspectRatio: Bool = false
    ) -> NSRect {
        let originalHalfWidth = original.width / 2
        let originalHalfHeight = original.height / 2
        let originalCenter = NSPoint(x: original.midX, y: original.midY)
        let minHalfSize = minimumSize / 2
        guard original.width > 0, original.height > 0 else { return original }

        let xSign: CGFloat? = anchor.movesMinX ? -1 : (anchor.movesMaxX ? 1 : nil)
        let ySign: CGFloat? = anchor.movesMinY ? -1 : (anchor.movesMaxY ? 1 : nil)

        let fixedLocal = NSPoint(
            x: xSign.map { -$0 * originalHalfWidth } ?? 0,
            y: ySign.map { -$0 * originalHalfHeight } ?? 0
        )
        let fixedWorld = point(originalCenter, adding: rotatedVector(fixedLocal, by: rotation))
        let deltaLocal = unrotatedVector(delta(from: fixedWorld, to: currentMouse), by: rotation)

        var halfWidth = originalHalfWidth
        var halfHeight = originalHalfHeight
        if preserveAspectRatio, xSign != nil || ySign != nil {
            let proposedWidth = xSign.map { $0 * deltaLocal.x } ?? original.width
            let proposedHeight = ySign.map { $0 * deltaLocal.y } ?? original.height
            let scale: CGFloat
            switch (xSign, ySign) {
            case (.some, .some):
                let denominator = original.width * original.width + original.height * original.height
                scale = denominator > 0
                    ? (original.width * proposedWidth + original.height * proposedHeight) / denominator
                    : 1
            case (.some, .none):
                scale = proposedWidth / original.width
            case (.none, .some):
                scale = proposedHeight / original.height
            case (.none, .none):
                scale = 1
            }
            guard scale.isFinite, scale > 0 else { return original }
            halfWidth = originalHalfWidth * scale
            halfHeight = originalHalfHeight * scale
            guard halfWidth >= minHalfSize, halfHeight >= minHalfSize else { return original }
        } else {
            if let xSign {
                halfWidth = xSign * deltaLocal.x / 2
                guard halfWidth >= minHalfSize else { return original }
            }
            if let ySign {
                halfHeight = ySign * deltaLocal.y / 2
                guard halfHeight >= minHalfSize else { return original }
            }
        }

        let centerLocal = NSPoint(
            x: xSign.map { $0 * halfWidth } ?? 0,
            y: ySign.map { $0 * halfHeight } ?? 0
        )
        let center = point(fixedWorld, adding: rotatedVector(centerLocal, by: rotation))
        return NSRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    private func rotatedVector(_ vector: NSPoint, by rotation: CGFloat) -> NSPoint {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return NSPoint(
            x: vector.x * cosR - vector.y * sinR,
            y: vector.x * sinR + vector.y * cosR
        )
    }

    private func unrotatedVector(_ vector: NSPoint, by rotation: CGFloat) -> NSPoint {
        rotatedVector(vector, by: -rotation)
    }

    private func point(_ point: NSPoint, adding vector: NSPoint) -> NSPoint {
        NSPoint(x: point.x + vector.x, y: point.y + vector.y)
    }

    private func delta(from start: NSPoint, to end: NSPoint) -> NSPoint {
        NSPoint(x: end.x - start.x, y: end.y - start.y)
    }

    // MARK: - Cursor

    /// Cursor shown while the magnifier tool is active and the pointer is
    /// over empty canvas — a loupe glyph with a dark halo so it reads on any
    /// background. The hotspot is the lens center, where a drag drops the
    /// lens. The drawing handler is resolution-independent, so the cursor
    /// stays crisp on Retina displays.
    private static let magnifierCursor: NSCursor = {
        let size: CGFloat = 28
        let lensCenter = NSPoint(x: 11, y: 17)
        let lensRadius: CGFloat = 7

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let lens = NSBezierPath(ovalIn: NSRect(
                x: lensCenter.x - lensRadius,
                y: lensCenter.y - lensRadius,
                width: lensRadius * 2,
                height: lensRadius * 2
            ))

            // Handle — from the lens's lower-right edge toward the corner.
            let diag = CGFloat(2).squareRoot() / 2
            let handleStart = NSPoint(
                x: lensCenter.x + lensRadius * diag,
                y: lensCenter.y - lensRadius * diag
            )
            let handle = NSBezierPath()
            handle.lineCapStyle = .round
            handle.move(to: handleStart)
            handle.line(to: NSPoint(x: handleStart.x + 7.5, y: handleStart.y - 7.5))

            // "+" inside the lens, echoing the toolbar icon.
            let arm: CGFloat = 3.4
            let plus = NSBezierPath()
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: lensCenter.x - arm, y: lensCenter.y))
            plus.line(to: NSPoint(x: lensCenter.x + arm, y: lensCenter.y))
            plus.move(to: NSPoint(x: lensCenter.x, y: lensCenter.y - arm))
            plus.line(to: NSPoint(x: lensCenter.x, y: lensCenter.y + arm))

            // Dark halo pass — fatter strokes underneath for contrast.
            NSColor.black.withAlphaComponent(0.55).setStroke()
            lens.lineWidth = 5;   lens.stroke()
            handle.lineWidth = 7; handle.stroke()
            plus.lineWidth = 4;   plus.stroke()

            // White body pass.
            NSColor.white.setStroke()
            lens.lineWidth = 2;     lens.stroke()
            handle.lineWidth = 3.5; handle.stroke()
            plus.lineWidth = 1.8;   plus.stroke()
            return true
        }
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: lensCenter.x, y: size - lensCenter.y)
        )
    }()

    private static let eraserCursor: NSCursor = {
        let size: CGFloat = 28
        let center = NSPoint(x: 14, y: 14)

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: -35)
            transform.translateX(by: -center.x, yBy: -center.y)

            NSGraphicsContext.saveGraphicsState()
            transform.concat()

            let bodyRect = NSRect(x: 7, y: 9, width: 16, height: 10)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)

            NSColor.black.withAlphaComponent(0.55).setStroke()
            body.lineWidth = 5
            body.stroke()

            NSColor.white.setFill()
            body.fill()

            NSColor.systemRed.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: NSRect(x: 7, y: 9, width: 7, height: 10), xRadius: 3, yRadius: 3).fill()

            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 14, y: 10))
            divider.line(to: NSPoint(x: 14, y: 18))
            NSColor.black.withAlphaComponent(0.28).setStroke()
            divider.lineWidth = 1
            divider.stroke()

            NSColor.white.withAlphaComponent(0.95).setStroke()
            body.lineWidth = 1.5
            body.stroke()

            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: center.x, y: size - center.y))
    }()

    private static let plusCursor: NSCursor = {
        let size: CGFloat = 28
        let center = NSPoint(x: 14, y: 14)

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let plus = NSBezierPath()
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: center.x - 8, y: center.y))
            plus.line(to: NSPoint(x: center.x + 8, y: center.y))
            plus.move(to: NSPoint(x: center.x, y: center.y - 8))
            plus.line(to: NSPoint(x: center.x, y: center.y + 8))

            NSColor.black.withAlphaComponent(0.55).setStroke()
            plus.lineWidth = 5
            plus.stroke()

            NSColor.white.setStroke()
            plus.lineWidth = 2.5
            plus.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: center.x, y: size - center.y))
    }()

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
        updateEmojiPreview(at: point)
        updateCursor(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateEmojiPreview(at: point)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if emojiPreviewPoint != nil {
            emojiPreviewPoint = nil
            needsDisplay = true
        }
        // Let whatever's underneath manage its own cursor.
        NSCursor.arrow.set()
    }

    private func updateEmojiPreview(at point: NSPoint) {
        guard activeTool == .emoji, currentEmoji != nil else {
            if emojiPreviewPoint != nil {
                emojiPreviewPoint = nil
                needsDisplay = true
            }
            return
        }
        guard bounds.contains(point) else { return }
        if emojiPreviewPoint != point {
            emojiPreviewPoint = point
            needsDisplay = true
        }
    }

    private func updateCursor(at point: NSPoint) {
        // Don't fight the text field's I-beam while editing.
        if activeTextField != nil { return }
        if activeTool == .eraser {
            EditCanvasView.eraserCursor.set()
            return
        }
        // Action buttons on the selection chrome: pointing finger.
        if hitTestSelectionAction(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        // Drag handles (rotate / curve / number tip / resize): resize grips
        // get a directional cursor; the rest get an open hand.
        if let kind = hitTestSelectionHandle(at: point) {
            if case .resize(let anchor) = kind {
                switch anchor {
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                default: NSCursor.openHand.set()
                }
            } else {
                NSCursor.openHand.set()
            }
            return
        }
        // Hovering over any draggable mark: open hand so the user knows it
        // can be picked up regardless of the active tool.
        if hitTestAnnotation(at: point) != nil {
            NSCursor.openHand.set()
            return
        }
        if activeTool == .emoji, currentEmoji != nil {
            EditCanvasView.plusCursor.set()
            return
        }
        // Magnifier tool over empty canvas: a loupe cursor signals that a
        // drag here drops a lens.
        if activeTool == .magnifier {
            EditCanvasView.magnifierCursor.set()
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

    override func keyDown(with event: NSEvent) {
        if undoFromKeyboard(for: event) {
            return
        }
        if redoFromKeyboard(for: event) {
            return
        }
        if handleAnnotationClipboardShortcutFromKeyboard(for: event) {
            return
        }
        if nudgeSelectedAnnotationFromKeyboard(for: event) {
            return
        }
        if deleteSelectedAnnotationFromKeyboard(for: event) {
            return
        }
        super.keyDown(with: event)
    }

    private static func isUndoKey(_ event: NSEvent) -> Bool {
        commandShortcutCharacter(for: event) == "z"
    }

    private static func isRedoKey(_ event: NSEvent) -> Bool {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private static func commandShortcutCharacter(for event: NSEvent) -> String? {
        let activeModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let modifiers = event.modifierFlags.intersection(activeModifiers)
        guard modifiers == .command else { return nil }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    private static func isSelectionDeleteKey(_ event: NSEvent) -> Bool {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return event.keyCode == 51 || event.keyCode == 117
    }

    private static func selectionNudgeDelta(for event: NSEvent) -> NSPoint? {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return nil }

        let step: CGFloat = 1
        switch event.keyCode {
        case 123: return NSPoint(x: -step, y: 0) // Left Arrow
        case 124: return NSPoint(x: step, y: 0)  // Right Arrow
        case 125: return NSPoint(x: 0, y: -step) // Down Arrow
        case 126: return NSPoint(x: 0, y: step)  // Up Arrow
        default: return nil
        }
    }
}

// MARK: - Editable Text Field

/// Borderless transparent NSTextField that auto-grows to fit its content
/// and reports commit/cancel via closures. Used by the text annotation
/// tool while the user is typing.
final class EditableTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// Outline flag for the text being edited. Carried through the edit
    /// session and read back when the annotation is committed. The live field
    /// shows plain text; the outline is rendered on the committed
    /// `TextAnnotation`, which adds it without shifting the glyphs.
    var hasStroke: Bool = false
    /// Rotation carried by an existing text annotation while it is being edited.
    /// The live editor stays horizontal, but the committed annotation keeps the
    /// original angle instead of snapping back to zero.
    var rotation: CGFloat = 0

    private var didFinish = false
    private var wasCanceled = false
    private static let insertNewlineIgnoringFieldEditorSelector = Selector(("insertNewlineIgnoringFieldEditor:"))
    private static let insertLineBreakSelector = Selector(("insertLineBreak:"))

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
        cell?.usesSingleLineMode = false
        cell?.wraps = false
        cell?.isScrollable = false
        maximumNumberOfLines = 0
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
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) {
                insertLineBreak(in: textView)
            } else {
                window?.makeFirstResponder(nil)
            }
            return true
        }
        if commandSelector == Self.insertNewlineIgnoringFieldEditorSelector
            || commandSelector == Self.insertLineBreakSelector {
            insertLineBreak(in: textView)
            return true
        }
        return false
    }

    private func insertLineBreak(in textView: NSTextView) {
        textView.insertText("\n", replacementRange: textView.selectedRange())
        stringValue = textView.string
        sizeToFitText()
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
