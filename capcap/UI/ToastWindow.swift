import AppKit

class ToastWindow: NSPanel {
    private static var current: ToastWindow?

    static func show(message: String = L10n.copiedToClipboard, on screen: NSScreen? = nil) {
        current?.orderOut(nil)

        let toast = ToastWindow(message: message)
        current = toast

        if let screen = screen ?? NSScreen.main {
            let x = screen.frame.midX - toast.frame.width / 2
            let y = screen.frame.midY - toast.frame.height / 2
            toast.setFrameOrigin(NSPoint(x: x, y: y))
        }

        toast.alphaValue = 0
        toast.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            toast.animator().alphaValue = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                toast.animator().alphaValue = 0.0
            }, completionHandler: {
                toast.orderOut(nil)
                if current === toast { current = nil }
            })
        }
    }

    private init(message: String) {
        // Measure text to size the chip
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let textSize = message.size(withAttributes: attrs)
        let size = NSSize(width: textSize.width + 24, height: 32)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true

        let toastView = ToastContentView(frame: NSRect(origin: .zero, size: size), message: message)
        contentView = toastView
    }
}

private class ToastContentView: NSView {
    private let message: String

    init(frame: NSRect, message: String) {
        self.message = message
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dark semi-transparent background (matching CursorChip style)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor(white: 0.15, alpha: 0.9).setFill()
        path.fill()

        NSColor(white: 0.4, alpha: 1.0).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Text
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let size = message.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        message.draw(in: textRect, withAttributes: attrs)
    }
}
