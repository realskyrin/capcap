import AppKit

protocol SelectionViewDelegate: AnyObject {
    func selectionDidStart()
    func selectionDidComplete(rect: NSRect, inView view: NSView)
}

class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?

    private var selectionOrigin: NSPoint?
    private var selectionRect: NSRect?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectionOrigin = point
        selectionRect = NSRect(origin: point, size: .zero)
        isDragging = true
        delegate?.selectionDidStart()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let origin = selectionOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)

        let x = min(origin.x, current.x)
        let y = min(origin.y, current.y)
        let width = abs(current.x - origin.x)
        let height = abs(current.y - origin.y)

        selectionRect = NSRect(x: x, y: y, width: width, height: height)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let rect = selectionRect else { return }
        isDragging = false

        // Minimum selection size
        if rect.width < 5 || rect.height < 5 {
            selectionRect = nil
            needsDisplay = true
            return
        }

        delegate?.selectionDidComplete(rect: rect, inView: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Only draw overlay when dragging or selection exists
        guard let rect = selectionRect, isDragging, rect.width > 0 || rect.height > 0 else {
            // Transparent — no overlay before dragging
            return
        }

        // Draw semi-transparent dark overlay
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.fill(bounds)

        // Clear the selection area
        context.setBlendMode(.clear)
        context.fill(rect)

        // Reset blend mode
        context.setBlendMode(.normal)

        // Draw white border
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2.0)
        context.stroke(rect.insetBy(dx: -1, dy: -1))
    }

    override var acceptsFirstResponder: Bool { true }
}
