import AppKit

/// Floating chip near top-center of the screen showing upload progress.
final class UploadProgressWindow: NSPanel {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let progressBar = ProgressBarView()

    init(provider: String) {
        let size = NSSize(width: 240, height: 56)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver + 4
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true

        let host = ChipBackgroundView(frame: NSRect(origin: .zero, size: size))
        contentView = host

        let title = "\(L10n.uploadingTitle) · \(provider)"
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(titleLabel)

        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(percentLabel)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(progressBar)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: percentLabel.leadingAnchor, constant: -8),

            percentLabel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            percentLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            percentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            progressBar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            progressBar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            progressBar.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen?) {
        let target = screen ?? NSScreen.main
        if let target {
            let frame = target.frame
            let x = frame.midX - self.frame.width / 2
            let y = frame.maxY - self.frame.height - 80
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1
        }
    }

    func setProgress(_ pct: Double) {
        let clamped = min(max(pct, 0), 1)
        progressBar.progress = CGFloat(clamped)
        percentLabel.stringValue = "\(Int(clamped * 100))%"
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

private final class ChipBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(white: 0.13, alpha: 0.92).setFill()
        path.fill()
        NSColor(white: 0.4, alpha: 1.0).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

private final class ProgressBarView: NSView {
    var progress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.12).setFill()
        trackPath.fill()

        let fillWidth = bounds.width * progress
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRect.height / 2, yRadius: fillRect.height / 2)
        NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.50, alpha: 1.0).setFill()
        fillPath.fill()
    }
}
