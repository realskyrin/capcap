import AppKit

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let onTakeScreenshot: () -> Void
    private let onOpenSettings: () -> Void
    private var historyMenu: NSMenu?
    private var historyItem: NSMenuItem?

    init(onTakeScreenshot: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onTakeScreenshot = onTakeScreenshot
        self.onOpenSettings = onOpenSettings

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "capcap")
            button.image?.isTemplate = true
        }

        setupMenu()

        NotificationCenter.default.addObserver(forName: .languageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.setupMenu()
        }
        NotificationCenter.default.addObserver(forName: .historyDidUpdate, object: nil, queue: .main) { [weak self] _ in
            self?.refreshHistoryItemState()
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        let screenshotItem = NSMenuItem(title: L10n.takeScreenshot, action: #selector(takeScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        menu.addItem(NSMenuItem.separator())

        let history = NSMenuItem(title: L10n.historyMenu, action: nil, keyEquivalent: "")
        let historySubmenu = NSMenu(title: L10n.historyMenu)
        historySubmenu.delegate = self
        history.submenu = historySubmenu
        historyMenu = historySubmenu
        historyItem = history
        menu.addItem(history)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu

        refreshHistoryItemState()
    }

    private func refreshHistoryItemState() {
        let entries = HistoryManager.shared.entries()
        historyItem?.isEnabled = !entries.isEmpty
    }

    @objc private func takeScreenshot() {
        onTakeScreenshot()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc fileprivate func historyItemClicked(_ sender: Any?) {
        let url: URL?
        if let item = sender as? NSMenuItem {
            url = item.representedObject as? URL
        } else if let row = sender as? HistoryMenuRow {
            url = row.fileURL
            row.enclosingMenuItem?.menu?.cancelTracking()
        } else {
            url = nil
        }
        guard let url = url, let image = NSImage(contentsOf: url) else { return }
        ClipboardManager.copyToClipboard(image: image)
        ToastWindow.show()
    }

    @objc private func clearHistoryClicked() {
        HistoryManager.shared.clearAll()
    }

    func setMenuBarVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        menu.removeAllItems()

        let entries = HistoryManager.shared.entries()
        if entries.isEmpty {
            let empty = NSMenuItem(title: L10n.historyEmpty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"

        for entry in entries {
            let item = NSMenuItem()
            let row = HistoryMenuRow(
                fileURL: entry.fileURL,
                timestamp: formatter.string(from: entry.createdAt),
                target: self,
                action: #selector(historyItemClicked(_:))
            )
            item.view = row
            item.representedObject = entry.fileURL
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: L10n.historyClear, action: #selector(clearHistoryClicked), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }
}

private final class HistoryMenuRow: NSView {
    static let itemWidth: CGFloat = 220
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let labelHeight: CGFloat = 14
    static let spacing: CGFloat = 4

    let fileURL: URL
    private weak var target: AnyObject?
    private let action: Selector
    private let timeLabel: NSTextField
    private let imageView: NSImageView
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    init(fileURL: URL, timestamp: String, target: AnyObject, action: Selector) {
        self.fileURL = fileURL
        self.target = target
        self.action = action

        let imageWidth = Self.itemWidth - Self.horizontalPadding * 2
        let (thumb, thumbHeight) = Self.makeThumbnail(url: fileURL, width: imageWidth)
        let totalHeight = Self.verticalPadding * 2 + Self.labelHeight + Self.spacing + thumbHeight

        timeLabel = NSTextField(labelWithString: timestamp)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.frame = NSRect(
            x: Self.horizontalPadding,
            y: totalHeight - Self.verticalPadding - Self.labelHeight,
            width: imageWidth,
            height: Self.labelHeight
        )
        timeLabel.autoresizingMask = [.minYMargin]

        imageView = NSImageView(frame: NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: imageWidth,
            height: thumbHeight
        ))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = thumb
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true

        super.init(frame: NSRect(x: 0, y: 0, width: Self.itemWidth, height: totalHeight))
        autoresizingMask = [.width]
        addSubview(timeLabel)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let target = target {
            _ = target.perform(action, with: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            let inset = bounds.insetBy(dx: 4, dy: 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
            path.fill()
        }
    }

    private static func makeThumbnail(url: URL, width: CGFloat) -> (NSImage?, CGFloat) {
        let fallbackHeight: CGFloat = 80
        guard let source = NSImage(contentsOf: url) else {
            return (nil, fallbackHeight)
        }
        let srcSize = source.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            return (source, fallbackHeight)
        }
        let scale = width / srcSize.width
        let height = max(20, min(srcSize.height * scale, 180))
        let target = NSSize(width: width, height: height)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return (thumb, height)
    }
}
