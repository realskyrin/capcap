import AppKit

class CursorChipWindow: NSPanel {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        let chipSize = NSSize(width: 200, height: 32)
        super.init(
            contentRect: NSRect(origin: .zero, size: chipSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let chipView = ChipView(frame: NSRect(origin: .zero, size: chipSize))
        contentView = chipView
    }

    func show() {
        updatePosition()
        orderFrontRegardless()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updatePosition()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updatePosition()
            return event
        }
    }

    func dismiss() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        orderOut(nil)
    }

    private func updatePosition() {
        let loc = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: loc.x + 15, y: loc.y - 40))
    }
}

private class ChipView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)

        NSColor(white: 0.15, alpha: 0.9).setFill()
        path.fill()

        NSColor(white: 0.4, alpha: 1.0).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let text = L10n.dragToScreenshot
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let size = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: textRect, withAttributes: attrs)
    }
}
