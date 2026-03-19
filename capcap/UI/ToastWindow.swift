import AppKit

class ToastWindow: NSPanel {
    private static var current: ToastWindow?

    static func show(message: String = "已添加到剪贴板") {
        current?.orderOut(nil)

        let toast = ToastWindow(message: message)
        current = toast

        // Center on main screen
        if let screen = NSScreen.main {
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
        let size = NSSize(width: 200, height: 100)
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
        // Background
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
        NSColor.white.withAlphaComponent(0.95).setFill()
        path.fill()

        NSColor.black.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Checkmark icon
        let checkSize: CGFloat = 36
        let checkY = bounds.midY + 4
        let checkX = bounds.midX - checkSize / 2

        if let checkImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: checkSize, weight: .light)
            let configured = checkImage.withSymbolConfiguration(config)
            let tinted = configured ?? checkImage

            NSGraphicsContext.saveGraphicsState()
            NSColor(white: 0.7, alpha: 1.0).set()
            let imgRect = NSRect(x: checkX, y: checkY - checkSize / 2, width: checkSize, height: checkSize)
            tinted.draw(in: imgRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Text
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.4, alpha: 1.0),
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let size = message.size(withAttributes: attrs)
        let textRect = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - 26,
            width: size.width,
            height: size.height
        )
        message.draw(in: textRect, withAttributes: attrs)
    }
}
