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
        NotificationCenter.default.addObserver(forName: .hotkeyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.setupMenu()
        }
        NotificationCenter.default.addObserver(forName: .updateStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.setupMenu()
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        let screenshotItem = NSMenuItem(title: L10n.takeScreenshot, action: #selector(takeScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        screenshotItem.image = Self.menuIcon(systemName: "crop")
        HotkeyManager.applyToMenuItem(screenshotItem)
        menu.addItem(screenshotItem)

        menu.addItem(NSMenuItem.separator())

        let history = NSMenuItem(title: L10n.historyMenu, action: nil, keyEquivalent: "")
        history.image = Self.menuIcon(systemName: "clock.arrow.circlepath")
        let historySubmenu = NSMenu(title: L10n.historyMenu)
        historySubmenu.delegate = self
        history.submenu = historySubmenu
        historyMenu = historySubmenu
        historyItem = history
        menu.addItem(history)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = Self.menuIcon(systemName: "gearshape")
        menu.addItem(settingsItem)

        menu.addItem(makeUpdateMenuItem())

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = Self.menuIcon(systemName: "power")
        menu.addItem(quitItem)

        statusItem.menu = menu

        refreshHistoryItemState()
    }

    fileprivate static func menuIcon(systemName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
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

    /// Builds the update menu item — a passive "new version" entry when one is
    /// known, otherwise a "Check for Updates" action.
    private func makeUpdateMenuItem() -> NSMenuItem {
        let item: NSMenuItem
        switch UpdateChecker.shared.state {
        case .available(let version, _):
            item = NSMenuItem(title: L10n.updateAvailableMenu(version),
                              action: #selector(openLatestRelease), keyEquivalent: "")
            item.image = Self.menuIcon(systemName: "arrow.down.circle.fill")
        case .checking:
            item = NSMenuItem(title: L10n.checkingForUpdatesMenu, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = Self.menuIcon(systemName: "arrow.triangle.2.circlepath")
        default:
            item = NSMenuItem(title: L10n.checkForUpdatesMenu,
                              action: #selector(checkForUpdatesClicked), keyEquivalent: "")
            item.image = Self.menuIcon(systemName: "arrow.triangle.2.circlepath")
        }
        item.target = self
        return item
    }

    @objc private func checkForUpdatesClicked() {
        UpdateChecker.shared.check(manual: true) { state in
            Self.presentManualCheckResult(state)
        }
    }

    @objc private func openLatestRelease() {
        if case .available(_, let url) = UpdateChecker.shared.state {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reports the outcome of a user-initiated check with a standard alert.
    /// Background launch checks stay silent and only update the menu item.
    private static func presentManualCheckResult(_ state: UpdateState) {
        let alert = NSAlert()
        switch state {
        case .available(let version, let url):
            alert.messageText = L10n.updateAvailableTitle(version)
            alert.informativeText = L10n.updateAvailableBody
            alert.addButton(withTitle: L10n.updateDownloadButton)
            alert.addButton(withTitle: L10n.updateLaterButton)
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        case .upToDate:
            alert.messageText = L10n.updateUpToDateTitle
            alert.informativeText = L10n.updateUpToDateBody(UpdateChecker.shared.currentVersion)
            alert.addButton(withTitle: L10n.updateOKButton)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .failed:
            alert.messageText = L10n.updateFailedTitle
            alert.informativeText = L10n.updateFailedBody
            alert.addButton(withTitle: L10n.updateOKButton)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .idle, .checking:
            // A check was already in flight — nothing to report yet.
            break
        }
    }

    @objc fileprivate func historyItemClicked(_ sender: Any?) {
        let entry: HistoryEntry?
        if let row = sender as? HistoryMenuRow {
            entry = row.entry
            row.enclosingMenuItem?.menu?.cancelTracking()
        } else if let item = sender as? NSMenuItem,
                  let stored = item.representedObject as? HistoryEntry {
            entry = stored
        } else {
            entry = nil
        }
        guard let entry = entry else { return }
        switch entry.kind {
        case .image:
            if let cloudURL = entry.cloudURL {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(cloudURL.absoluteString, forType: .string)
                ToastWindow.show(message: L10n.uploadCopied)
                return
            }
            guard let image = NSImage(contentsOf: entry.fileURL) else { return }
            ClipboardManager.copyToClipboard(image: image)
            ToastWindow.show()
        case .color(let hex):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hex, forType: .string)
            ToastWindow.show(message: L10n.colorCopied(hex))
        }
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
            var timestamp = formatter.string(from: entry.createdAt)
            if entry.cloudURL != nil {
                timestamp += " ☁️"
            }
            let row = HistoryMenuRow(
                entry: entry,
                timestamp: timestamp,
                target: self,
                action: #selector(historyItemClicked(_:))
            )
            item.view = row
            item.representedObject = entry
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: L10n.historyClear, action: #selector(clearHistoryClicked), keyEquivalent: "")
        clearItem.target = self
        clearItem.image = Self.menuIcon(systemName: "trash")
        menu.addItem(clearItem)
    }
}

private final class HistoryMenuRow: NSView {
    static let itemWidth: CGFloat = 220
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let labelHeight: CGFloat = 14
    static let spacing: CGFloat = 4
    static let maxThumbnailHeight: CGFloat = 180
    static let colorSwatchSize: CGFloat = 28

    let entry: HistoryEntry
    private weak var target: AnyObject?
    private let action: Selector
    private let timeLabel: NSTextField
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    init(entry: HistoryEntry, timestamp: String, target: AnyObject, action: Selector) {
        self.entry = entry
        self.target = target
        self.action = action

        let contentWidth = Self.itemWidth - Self.horizontalPadding * 2
        let previewBlock: (NSView, CGFloat) = {
            switch entry.kind {
            case .image:
                return Self.makeImagePreview(url: entry.fileURL, maxWidth: contentWidth)
            case .color(let hex):
                return Self.makeColorPreview(hex: hex, maxWidth: contentWidth)
            }
        }()
        let preview = previewBlock.0
        let previewHeight = previewBlock.1
        let totalHeight = Self.verticalPadding * 2 + Self.labelHeight + Self.spacing + previewHeight

        timeLabel = NSTextField(labelWithString: timestamp)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.frame = NSRect(
            x: Self.horizontalPadding,
            y: totalHeight - Self.verticalPadding - Self.labelHeight,
            width: contentWidth,
            height: Self.labelHeight
        )
        timeLabel.autoresizingMask = [.minYMargin]

        super.init(frame: NSRect(x: 0, y: 0, width: Self.itemWidth, height: totalHeight))
        autoresizingMask = [.width]
        addSubview(timeLabel)
        addSubview(preview)
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

    private static func makeImagePreview(url: URL, maxWidth: CGFloat) -> (NSView, CGFloat) {
        let fallbackHeight: CGFloat = 80
        let maxHeight = Self.maxThumbnailHeight
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true

        guard let source = NSImage(contentsOf: url),
              source.size.width > 0, source.size.height > 0 else {
            imageView.frame = NSRect(
                x: Self.horizontalPadding,
                y: Self.verticalPadding,
                width: maxWidth,
                height: fallbackHeight
            )
            return (imageView, fallbackHeight)
        }

        let srcSize = source.size
        let scale = min(maxWidth / srcSize.width, maxHeight / srcSize.height)
        let drawWidth = max(20, srcSize.width * scale)
        let drawHeight = max(20, srcSize.height * scale)
        let target = NSSize(width: drawWidth, height: drawHeight)
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
        imageView.image = thumb
        let xOffset = Self.horizontalPadding + (maxWidth - drawWidth) / 2
        imageView.frame = NSRect(x: xOffset, y: Self.verticalPadding, width: drawWidth, height: drawHeight)
        return (imageView, drawHeight)
    }

    private static func makeColorPreview(hex: String, maxWidth: CGFloat) -> (NSView, CGFloat) {
        let blockHeight = Self.colorSwatchSize
        let container = NSView(frame: NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: maxWidth,
            height: blockHeight
        ))

        let swatch = NSView(frame: NSRect(x: 0, y: 0, width: blockHeight, height: blockHeight))
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.backgroundColor = (NSColor(hex: hex) ?? .black).cgColor
        container.addSubview(swatch)

        let hexLabel = NSTextField(labelWithString: hex.uppercased())
        hexLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        hexLabel.textColor = .labelColor
        hexLabel.alignment = .left
        hexLabel.frame = NSRect(
            x: blockHeight + 8,
            y: 0,
            width: maxWidth - blockHeight - 8,
            height: blockHeight
        )
        hexLabel.cell?.usesSingleLineMode = true
        hexLabel.cell?.lineBreakMode = .byTruncatingTail
        container.addSubview(hexLabel)

        return (container, blockHeight)
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
