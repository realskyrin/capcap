import AppKit
import ImageIO

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let onTakeScreenshot: () -> Void
    private let onRecord: () -> Void
    private let onMergeImages: () -> Void
    private let onOpenSettings: () -> Void
    private var historyMenu: NSMenu?
    private var historyItem: NSMenuItem?

    init(
        onTakeScreenshot: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onMergeImages: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onTakeScreenshot = onTakeScreenshot
        self.onRecord = onRecord
        self.onMergeImages = onMergeImages
        self.onOpenSettings = onOpenSettings

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        super.init()

        if let button = statusItem.button {
            button.image = Self.statusBarIcon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
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
            self?.syncUpdateProgressHUD()
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        let screenshotItem = NSMenuItem(title: L10n.takeScreenshot, action: #selector(takeScreenshot), keyEquivalent: "")
        screenshotItem.target = self
        screenshotItem.image = Self.menuIcon(systemName: "crop")
        HotkeyManager.applyToMenuItem(screenshotItem)
        menu.addItem(screenshotItem)

        let recordItem = NSMenuItem(title: L10n.record, action: #selector(record), keyEquivalent: "")
        recordItem.target = self
        recordItem.image = Self.menuIcon(systemName: "record.circle")
        HotkeyManager.applyRecordToMenuItem(recordItem)
        menu.addItem(recordItem)

        let mergeItem = NSMenuItem(title: L10n.mergeImages, action: #selector(mergeImages), keyEquivalent: "")
        mergeItem.target = self
        mergeItem.image = Self.menuIcon(systemName: "square.grid.2x2")
        HotkeyManager.applyImageMergeToMenuItem(mergeItem)
        menu.addItem(mergeItem)

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

    private static func statusBarIcon() -> NSImage {
        let size = NSSize(width: 20, height: 20)
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = size
            image.isTemplate = true
            return image
        }

        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "capcap")
            ?? NSImage(size: size)
        image.size = size
        image.isTemplate = true
        return image
    }

    private func refreshHistoryItemState() {
        historyItem?.isEnabled = HistoryManager.shared.hasEntries()
    }

    @objc private func takeScreenshot() {
        onTakeScreenshot()
    }

    @objc private func record() {
        onRecord()
    }

    @objc private func mergeImages() {
        onMergeImages()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    /// Builds the update menu item — its title and action track the current
    /// state: an installable "new version" entry, a passive download/install
    /// progress line, or a "Check for Updates" action.
    private func makeUpdateMenuItem() -> NSMenuItem {
        let item: NSMenuItem
        switch UpdateChecker.shared.state {
        case .available(let version):
            item = NSMenuItem(title: L10n.updateAvailableMenu(version),
                              action: #selector(updateMenuItemClicked), keyEquivalent: "")
            item.image = Self.menuIcon(systemName: "arrow.down.circle.fill")
        case .downloading(_, let fraction):
            item = NSMenuItem(title: L10n.updateDownloadingMenu(Int(fraction * 100)),
                              action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = Self.menuIcon(systemName: "arrow.down.circle")
        case .installing:
            item = NSMenuItem(title: L10n.updateInstallingMenu, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = Self.menuIcon(systemName: "arrow.down.circle")
        case .installFailed:
            item = NSMenuItem(title: L10n.updateInstallFailedMenu,
                              action: #selector(updateMenuItemClicked), keyEquivalent: "")
            item.image = Self.menuIcon(systemName: "exclamationmark.triangle")
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
        // Give the manual check immediate feedback — the GitHub round trip can
        // take a moment, and otherwise nothing visible happens until it lands.
        UpdateProgressWindow.show(message: L10n.updateCheckingHUD, style: .spinner)
        UpdateChecker.shared.check(manual: true) { state in
            UpdateProgressWindow.dismiss()
            Self.presentManualCheckResult(state)
        }
    }

    /// Reflects an in-flight download/install into the progress HUD. The
    /// checking HUD and every dismissal are driven explicitly by the
    /// manual-check and install-failure paths, so this only advances the HUD
    /// through the download and install phases.
    private func syncUpdateProgressHUD() {
        switch UpdateChecker.shared.state {
        case .downloading(_, let fraction):
            UpdateProgressWindow.show(
                message: L10n.updateDownloadingHUD(Int(fraction * 100)),
                style: .bar(fraction: fraction)
            )
        case .installing(_, let phase):
            let message: String
            switch phase {
            case .verifying:  message = L10n.updateVerifyingHUD
            case .unzipping:  message = L10n.updateUnzippingHUD
            case .installing: message = L10n.updateInstallingHUD
            }
            UpdateProgressWindow.show(message: message, style: .spinner)
        default:
            break
        }
    }

    /// Handles a click on the update menu item once a release is known: offers
    /// the install prompt, or — after a failed install — the release page.
    @objc private func updateMenuItemClicked() {
        switch UpdateChecker.shared.state {
        case .available(let version):
            Self.presentUpdateAvailableAlert(version: version)
        case .installFailed:
            if let url = UpdateChecker.shared.latestPageURL {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    /// Reports the outcome of a user-initiated check with a standard alert.
    /// Background launch checks stay silent and only update the menu item.
    private static func presentManualCheckResult(_ state: UpdateState) {
        switch state {
        case .available(let version):
            presentUpdateAvailableAlert(version: version)
        case .upToDate:
            let alert = NSAlert()
            alert.messageText = L10n.updateUpToDateTitle
            alert.informativeText = L10n.updateUpToDateBody(UpdateChecker.shared.currentVersion)
            alert.addButton(withTitle: L10n.updateOKButton)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .failed:
            let alert = NSAlert()
            alert.messageText = L10n.updateFailedTitle
            alert.informativeText = L10n.updateFailedBody
            alert.addButton(withTitle: L10n.updateOKButton)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .idle, .checking, .downloading, .installing, .installFailed:
            // Either a check was already in flight, or an install is being
            // driven elsewhere — nothing to report here.
            break
        }
    }

    /// Prompts the user to install a newer release. The download/install runs
    /// in the background; on success the app relaunches itself.
    static func presentUpdateAvailableAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = L10n.updateAvailableTitle(version)
        alert.informativeText = L10n.updateAvailableBody
        alert.addButton(withTitle: L10n.updateInstallNowButton)
        alert.addButton(withTitle: L10n.updateSkipButton)
        alert.addButton(withTitle: L10n.updateLaterButton)
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            UpdateChecker.shared.downloadAndInstall(onFailure: presentInstallFailedAlert)
        case .alertSecondButtonReturn:
            UpdateChecker.shared.skipVersion()
        default:
            break
        }
    }

    /// Shown when a download or install fails — offers the release page as a
    /// manual fallback.
    static func presentInstallFailedAlert() {
        UpdateProgressWindow.dismiss()
        let alert = NSAlert()
        alert.messageText = L10n.updateInstallFailedTitle
        alert.informativeText = L10n.updateInstallFailedBody
        alert.addButton(withTitle: L10n.updateOpenPageButton)
        alert.addButton(withTitle: L10n.updateOKButton)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = UpdateChecker.shared.latestPageURL {
            NSWorkspace.shared.open(url)
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
            // Cloud-hosted images copy a URL; holding ⌘ copies a Markdown image
            // tag instead. Plain (non-uploaded) images always copy the image.
            if let cloudURL = entry.cloudURL {
                let asMarkdown = NSEvent.modifierFlags.contains(.command)
                let copyText = asMarkdown
                    ? "![](\(cloudURL.absoluteString))"
                    : cloudURL.absoluteString
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(copyText, forType: .string)
                ToastWindow.show(message: asMarkdown ? L10n.uploadCopiedMarkdown : L10n.uploadCopied)
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
    static let thumbnailHeight: CGFloat = 96
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
        let previewHeight = Self.thumbnailHeight
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        imageView.frame = NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: maxWidth,
            height: previewHeight
        )

        let pixelSize = Int(max(maxWidth, previewHeight) * (NSScreen.main?.backingScaleFactor ?? 2.0))
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = Self.makeThumbnail(url: url, pixelSize: pixelSize) else { return }
            DispatchQueue.main.async { [weak imageView] in
                guard let imageView = imageView else { return }
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                imageView.image = NSImage(cgImage: cgImage, size: size)
                imageView.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        return (imageView, previewHeight)
    }

    private static func makeThumbnail(url: URL, pixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
