import AppKit

protocol SelectionViewDelegate: AnyObject {
    func selectionDidStart()
    func selectionDidComplete(rect: NSRect, inView view: NSView)
    func selectionDidChange(rect: NSRect, inView view: NSView)
}

extension SelectionViewDelegate {
    func selectionDidChange(rect: NSRect, inView view: NSView) {}
}

class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?

    // MARK: - State

    private enum State {
        case idle
        case drawing
        case selected
    }

    private enum DragAction {
        case none
        case drawNew
        case move
        case resize(HandlePosition)
    }

    enum HandlePosition: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        case topCenter, bottomCenter, leftCenter, rightCenter
    }

    private var state: State = .idle
    private var dragAction: DragAction = .none
    private var selectionOrigin: NSPoint = .zero
    private var selectionRect: NSRect?
    private var dragStart: NSPoint = .zero
    private var dragOriginalRect: NSRect = .zero

    // Whether annotation tools are active (pass mouse events through to canvas)
    var annotationToolActive = false

    // When true, clicking outside selection won't start a new selection
    var selectionLocked = false

    // Scroll capture mode: update border styling while the controller manages event routing.
    var scrollCaptureActive = false

    // When false, the selection frame becomes a fixed viewport.
    var selectionInteractionEnabled = true

    // MARK: - Window Detection

    /// Set by OverlayWindowController so the view can detect windows under the cursor.
    var windowDetector: WindowDetector?

    /// The window rect currently highlighted under the cursor (view coordinates).
    private var hoverWindowRect: NSRect?

    /// Pending window selection — confirmed on mouseUp if no significant drag occurs.
    private var pendingWindowRect: NSRect?
    private let windowClickThreshold: CGFloat = 4

    // MARK: - Constants

    private let accentColor = NSColor(red: 0, green: 212.0/255.0, blue: 106.0/255.0, alpha: 1.0)
    private let handleSize: CGFloat = 8
    private let handleHitSize: CGFloat = 12
    private let borderWidth: CGFloat = 2.0
    private let dashPattern: [CGFloat] = [6, 4]

    // MARK: - Public

    var currentSelectionRect: NSRect? { selectionRect }

    func updateSelectionRect(_ rect: NSRect) {
        selectionRect = rect
        state = .selected
        needsDisplay = true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        guard selectionInteractionEnabled else {
            dragAction = .none
            return
        }

        let point = convert(event.locationInWindow, from: nil)

        // On a highlighted window: defer confirmation until mouseUp.
        // If the user drags past the threshold, fall through to free-form drawing.
        if state == .idle, let hoverRect = hoverWindowRect {
            pendingWindowRect = hoverRect
            hoverWindowRect = nil
            selectionOrigin = point
            dragStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .drawing
            dragAction = .drawNew
            delegate?.selectionDidStart()
            needsDisplay = true
            return
        }

        if let rect = selectionRect, state == .selected {
            // Check control points first
            if let handle = hitTestHandle(point: point, rect: rect) {
                dragAction = .resize(handle)
                dragStart = point
                dragOriginalRect = rect
                return
            }
            // Check inside selection for move
            if rect.contains(point) {
                if annotationToolActive {
                    // Let canvas handle it
                    return
                }
                dragAction = .move
                dragStart = point
                dragOriginalRect = rect
                return
            }
            // Click outside selection — if locked (editor active), ignore
            if selectionLocked {
                dragAction = .none
                return
            }
        }

        // Start drawing new selection
        selectionOrigin = point
        selectionRect = NSRect(origin: point, size: .zero)
        state = .drawing
        dragAction = .drawNew
        delegate?.selectionDidStart()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionInteractionEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch dragAction {
        case .drawNew:
            // If still within click threshold, keep the pending window rect alive
            if pendingWindowRect != nil {
                let dx = abs(point.x - dragStart.x)
                let dy = abs(point.y - dragStart.y)
                if dx < windowClickThreshold && dy < windowClickThreshold {
                    return  // no visual update yet — wait for more movement or mouseUp
                }
                // Drag exceeded threshold → discard window snap, proceed with free draw
                pendingWindowRect = nil
            }
            NSCursor.crosshair.set()
            let x = min(selectionOrigin.x, point.x)
            let y = min(selectionOrigin.y, point.y)
            let width = abs(point.x - selectionOrigin.x)
            let height = abs(point.y - selectionOrigin.y)
            selectionRect = NSRect(x: x, y: y, width: width, height: height)
            needsDisplay = true

        case .move:
            NSCursor.closedHand.set()
            guard let _ = selectionRect else { return }
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            var newRect = dragOriginalRect.offsetBy(dx: dx, dy: dy)
            // Clamp to view bounds
            newRect.origin.x = max(0, min(bounds.width - newRect.width, newRect.origin.x))
            newRect.origin.y = max(0, min(bounds.height - newRect.height, newRect.origin.y))
            selectionRect = newRect
            delegate?.selectionDidChange(rect: newRect, inView: self)
            needsDisplay = true

        case .resize(let handle):
            let newRect = resizedRect(from: dragOriginalRect, handle: handle, currentPoint: point)
            selectionRect = newRect
            delegate?.selectionDidChange(rect: newRect, inView: self)
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionInteractionEnabled else {
            dragAction = .none
            return
        }

        switch dragAction {
        case .drawNew:
            // Click without drag → confirm the pending window selection
            if let windowRect = pendingWindowRect {
                pendingWindowRect = nil
                selectionRect = windowRect
                state = .selected
                dragAction = .none
                delegate?.selectionDidComplete(rect: windowRect, inView: self)
                needsDisplay = true
                return
            }
            guard let rect = selectionRect, rect.width >= 5, rect.height >= 5 else {
                selectionRect = nil
                state = .idle
                dragAction = .none
                needsDisplay = true
                return
            }
            state = .selected
            delegate?.selectionDidComplete(rect: rect, inView: self)

        case .move, .resize:
            if let rect = selectionRect {
                delegate?.selectionDidComplete(rect: rect, inView: self)
            }

        case .none:
            break
        }

        dragAction = .none
    }

    override func mouseMoved(with event: NSEvent) {
        guard selectionInteractionEnabled else {
            NSCursor.arrow.set()
            return
        }

        // In idle state, detect windows under cursor for hover highlight
        if state == .idle && !selectionLocked {
            updateWindowHover(with: event)
            return
        }

        guard state == .selected, let rect = selectionRect else {
            if !selectionLocked {
                NSCursor.crosshair.set()
            }
            return
        }

        let point = convert(event.locationInWindow, from: nil)

        // When editor is active, only show resize cursors on handles;
        // don't override the cursor elsewhere (let editor/toolbar handle it)
        if selectionLocked {
            if let handle = hitTestHandle(point: point, rect: rect) {
                setCursorForHandle(handle)
            } else {
                NSCursor.arrow.set()
            }
            return
        }

        if let handle = hitTestHandle(point: point, rect: rect) {
            setCursorForHandle(handle)
        } else if rect.contains(point) {
            if annotationToolActive {
                NSCursor.crosshair.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Window Hover

    private func updateWindowHover(with event: NSEvent) {
        guard let detector = windowDetector,
              let win = self.window,
              let screen = win.screen else {
            clearHover()
            NSCursor.crosshair.set()
            return
        }

        // Convert view point → screen point → CG point
        let viewPoint = convert(event.locationInWindow, from: nil)
        let windowPoint = convert(viewPoint, to: nil)
        let screenPoint = win.convertPoint(toScreen: windowPoint)
        let primaryHeight = NSScreen.screens[0].frame.height
        let cgPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)

        if let detected = detector.windowAt(cgPoint: cgPoint) {
            // Convert CG window frame → AppKit screen coords → view coords
            let appKitY = primaryHeight - detected.frame.origin.y - detected.frame.height
            let viewRect = NSRect(
                x: detected.frame.origin.x - screen.frame.origin.x,
                y: appKitY - screen.frame.origin.y,
                width: detected.frame.width,
                height: detected.frame.height
            )
            // Clamp to view bounds
            let clamped = viewRect.intersection(bounds)
            guard !clamped.isNull, clamped.width > 1, clamped.height > 1 else {
                clearHover()
                NSCursor.crosshair.set()
                return
            }
            if hoverWindowRect != clamped {
                hoverWindowRect = clamped
                needsDisplay = true
            }
            NSCursor.pointingHand.set()
        } else {
            clearHover()
            NSCursor.crosshair.set()
        }
    }

    private func clearHover() {
        if hoverWindowRect != nil {
            hoverWindowRect = nil
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Hover highlight for window detection (idle state, before any click)
        if state == .idle, let hoverRect = hoverWindowRect {
            // Dark overlay
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.fill(bounds)
            // Clear the hovered window area
            context.setBlendMode(.clear)
            context.fill(hoverRect)
            context.setBlendMode(.normal)
            // Solid accent border
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(borderWidth + 1)
            context.stroke(hoverRect.insetBy(dx: -1.5, dy: -1.5))
            // Size label
            drawSizeLabel(context: context, rect: hoverRect)
            return
        }

        // In idle state with no selection, don't draw overlay
        guard let rect = selectionRect, (state == .drawing || state == .selected),
              rect.width > 0 || rect.height > 0 else {
            return
        }

        // Draw semi-transparent dark overlay
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(bounds)

        // Clear the selection area (cutout)
        context.setBlendMode(.clear)
        context.fill(rect)
        context.setBlendMode(.normal)

        // Draw border — solid red during scroll capture, green dashed otherwise
        if scrollCaptureActive {
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(borderWidth + 1)
            context.stroke(rect.insetBy(dx: -1, dy: -1))
        } else {
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(borderWidth)
            context.setLineDash(phase: 0, lengths: dashPattern)
            context.stroke(rect.insetBy(dx: -1, dy: -1))
            context.setLineDash(phase: 0, lengths: [])
        }

        if state == .selected && selectionInteractionEnabled {
            // Draw 8 control handles
            drawHandles(context: context, rect: rect)
            // Draw size label
            drawSizeLabel(context: context, rect: rect)
        }
    }

    private func drawHandles(context: CGContext, rect: NSRect) {
        let positions = handlePositions(for: rect)
        for pos in positions {
            let handleRect = NSRect(
                x: pos.x - handleSize / 2,
                y: pos.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            context.setFillColor(accentColor.cgColor)
            context.fillEllipse(in: handleRect)
        }
    }

    private func drawSizeLabel(context: CGContext, rect: NSRect) {
        let text = "\(Int(rect.width)) x \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        let size = text.size(withAttributes: attrs)
        // Position above the top-left corner of selection
        let labelX = rect.origin.x
        let labelY = rect.origin.y + rect.height + 4  // Above top edge (AppKit coords: y increases upward)
        let labelRect = NSRect(x: labelX, y: labelY, width: size.width + 8, height: size.height + 4)

        // Draw background
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        let bgPath = CGPath(roundedRect: labelRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.addPath(bgPath)
        context.fillPath()

        // Draw text
        let textOrigin = NSPoint(x: labelRect.origin.x + 4, y: labelRect.origin.y + 2)
        text.draw(at: textOrigin, withAttributes: attrs)
    }

    // MARK: - Handle Positions

    private func handlePositions(for rect: NSRect) -> [NSPoint] {
        let minX = rect.minX, midX = rect.midX, maxX = rect.maxX
        let minY = rect.minY, midY = rect.midY, maxY = rect.maxY
        return [
            NSPoint(x: minX, y: maxY),  // topLeft
            NSPoint(x: maxX, y: maxY),  // topRight
            NSPoint(x: minX, y: minY),  // bottomLeft
            NSPoint(x: maxX, y: minY),  // bottomRight
            NSPoint(x: midX, y: maxY),  // topCenter
            NSPoint(x: midX, y: minY),  // bottomCenter
            NSPoint(x: minX, y: midY),  // leftCenter
            NSPoint(x: maxX, y: midY),  // rightCenter
        ]
    }

    private func hitTestHandle(point: NSPoint, rect: NSRect) -> HandlePosition? {
        let positions = handlePositions(for: rect)
        let handles = HandlePosition.allCases
        for (i, pos) in positions.enumerated() {
            let hitRect = NSRect(
                x: pos.x - handleHitSize / 2,
                y: pos.y - handleHitSize / 2,
                width: handleHitSize,
                height: handleHitSize
            )
            if hitRect.contains(point) {
                return handles[i]
            }
        }
        return nil
    }

    // MARK: - Resize Logic

    private func resizedRect(from original: NSRect, handle: HandlePosition, currentPoint: NSPoint) -> NSRect {
        var minX = original.minX
        var minY = original.minY
        var maxX = original.maxX
        var maxY = original.maxY

        switch handle {
        case .topLeft:
            minX = min(currentPoint.x, maxX - 5)
            maxY = max(currentPoint.y, minY + 5)
        case .topRight:
            maxX = max(currentPoint.x, minX + 5)
            maxY = max(currentPoint.y, minY + 5)
        case .bottomLeft:
            minX = min(currentPoint.x, maxX - 5)
            minY = min(currentPoint.y, maxY - 5)
        case .bottomRight:
            maxX = max(currentPoint.x, minX + 5)
            minY = min(currentPoint.y, maxY - 5)
        case .topCenter:
            maxY = max(currentPoint.y, minY + 5)
        case .bottomCenter:
            minY = min(currentPoint.y, maxY - 5)
        case .leftCenter:
            minX = min(currentPoint.x, maxX - 5)
        case .rightCenter:
            maxX = max(currentPoint.x, minX + 5)
        }

        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Cursor

    private func setCursorForHandle(_ handle: HandlePosition) {
        switch handle {
        case .topLeft, .bottomRight:
            NSCursor(image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.white.setStroke()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 2, y: 14))
                path.line(to: NSPoint(x: 14, y: 2))
                path.lineWidth = 2
                path.stroke()
                return true
            }, hotSpot: NSPoint(x: 8, y: 8)).set()
        case .topRight, .bottomLeft:
            NSCursor(image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.white.setStroke()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 2, y: 2))
                path.line(to: NSPoint(x: 14, y: 14))
                path.lineWidth = 2
                path.stroke()
                return true
            }, hotSpot: NSPoint(x: 8, y: 8)).set()
        case .topCenter, .bottomCenter:
            NSCursor.resizeUpDown.set()
        case .leftCenter, .rightCenter:
            NSCursor.resizeLeftRight.set()
        }
    }

    // MARK: - Configuration

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}
