import AppKit

enum HistoryMediaBadgeKind {
    case gif
    case mp4

    init?(entry: HistoryEntry) {
        switch entry.kind {
        case .image where entry.fileURL.pathExtension.lowercased() == "gif":
            self = .gif
        case .video:
            self = .mp4
        case .image, .color:
            return nil
        }
    }

    var title: String {
        switch self {
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }
}

final class HistoryMediaBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(kind: HistoryMediaBadgeKind? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = accentGreen.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        label.textColor = .black
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if let kind {
            title = kind.title
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: ceil(labelSize.width) + 14, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class HistoryCloudBadgeView: NSView {
    private let label = NSTextField(labelWithString: "☁️")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
