import AppKit

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let onTakeScreenshot: () -> Void
    private let onTakeFullScreenScreenshot: () -> Void
    private let onRecord: () -> Void
    private let onMergeImages: () -> Void
    private let onColorPicker: () -> Void
    private let onOpenHistoryPanel: () -> Void
    private let onOpenSettings: () -> Void
    private var historyMenu: NSMenu?
    private var historyItem: NSMenuItem?

    init(
        onTakeScreenshot: @escaping () -> Void,
        onTakeFullScreenScreenshot: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onMergeImages: @escaping () -> Void,
        onColorPicker: @escaping () -> Void,
        onOpenHistoryPanel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onTakeScreenshot = onTakeScreenshot
        self.onTakeFullScreenScreenshot = onTakeFullScreenScreenshot
        self.onRecord = onRecord
        self.onMergeImages = onMergeImages
        self.onColorPicker = onColorPicker
        self.onOpenHistoryPanel = onOpenHistoryPanel
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
        NotificationCenter.default.addObserver(forName: .historyCacheEnabledDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.setupMenu()
        }
        NotificationCenter.default.addObserver(forName: .clipboardTextCacheEnabledDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.setupMenu()
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

        let fullScreenItem = NSMenuItem(title: L10n.takeFullScreenScreenshot, action: #selector(takeFullScreenScreenshot), keyEquivalent: "")
        fullScreenItem.target = self
        fullScreenItem.image = Self.menuIcon(systemName: "display")
        HotkeyManager.applyFullScreenScreenshotToMenuItem(fullScreenItem)
        menu.addItem(fullScreenItem)

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

        let colorPickerItem = NSMenuItem(title: L10n.colorPicker, action: #selector(colorPicker), keyEquivalent: "")
        colorPickerItem.target = self
        colorPickerItem.image = Self.menuIcon(systemName: "eyedropper")
        HotkeyManager.applyColorPickerToMenuItem(colorPickerItem)
        menu.addItem(colorPickerItem)

        menu.addItem(NSMenuItem.separator())

        if Defaults.isHistoryCacheAvailable {
            let history = NSMenuItem(title: L10n.historyMenu, action: nil, keyEquivalent: "")
            history.image = Self.menuIcon(systemName: "clock.arrow.circlepath")
            let historySubmenu = NSMenu(title: L10n.historyMenu)
            historySubmenu.delegate = self
            history.submenu = historySubmenu
            historyMenu = historySubmenu
            historyItem = history
            menu.addItem(history)

            let historyPanelItem = NSMenuItem(title: L10n.historyPanelMenu, action: #selector(openHistoryPanel), keyEquivalent: "")
            historyPanelItem.target = self
            historyPanelItem.image = Self.menuIcon(systemName: "rectangle.stack")
            HotkeyManager.applyHistoryPanelToMenuItem(historyPanelItem)
            menu.addItem(historyPanelItem)

            menu.addItem(NSMenuItem.separator())
        } else {
            historyMenu = nil
            historyItem = nil
        }

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
        historyItem?.isEnabled = Defaults.isHistoryCacheAvailable
    }

    @objc private func takeScreenshot() {
        onTakeScreenshot()
    }

    @objc private func takeFullScreenScreenshot() {
        onTakeFullScreenScreenshot()
    }

    @objc private func record() {
        onRecord()
    }

    @objc private func mergeImages() {
        onMergeImages()
    }

    @objc private func colorPicker() {
        onColorPicker()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openHistoryPanel() {
        onOpenHistoryPanel()
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
            Self.presentUpdateAvailableAlertAfterRefresh(fallbackVersion: version)
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

    /// Refreshes GitHub before showing the install prompt so a long-running app
    /// does not offer an older release after a newer one is published.
    static func presentUpdateAvailableAlertAfterRefresh(fallbackVersion: String) {
        UpdateProgressWindow.show(message: L10n.updateCheckingHUD, style: .spinner)
        UpdateChecker.shared.check(manual: true) { state in
            UpdateProgressWindow.dismiss()
            switch state {
            case .available(let version):
                presentUpdateAvailableAlert(version: version)
            case .upToDate, .failed:
                presentManualCheckResult(state)
            case .idle, .checking, .downloading, .installing, .installFailed:
                presentUpdateAvailableAlert(version: fallbackVersion)
            }
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
            // Cloud-hosted images follow the user's upload copy format setting.
            // Plain non-uploaded images always copy the image itself.
            if let cloudURL = entry.cloudURL {
                let asMarkdown = Defaults.copyUploadAsMarkdown
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
        case .video:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([entry.fileURL as NSURL])
            ToastWindow.show(message: L10n.copiedToClipboard)
        case .color(let hex):
            ClipboardManager.copyColorToClipboard(hex: hex)
            ToastWindow.show(message: L10n.colorCopied(hex))
        case .text(let text):
            ClipboardManager.copyHistoryTextToClipboard(text.value)
            ToastWindow.show(message: L10n.copiedToClipboard)
        }
    }

    @objc private func clearHistoryClicked() {
        HistoryManager.shared.clearAll {
            ToastWindow.show(message: L10n.historyCleared)
        }
    }

    @objc private func showHistoryInFinderClicked() {
        NSWorkspace.shared.open(HistoryManager.shared.cacheDirectoryURL())
    }

    func setMenuBarVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard Defaults.isHistoryCacheAvailable, menu === historyMenu else { return }
        menu.removeAllItems()

        let entries = HistoryManager.shared.entries()
        addHistoryUtilityItems(to: menu, hasEntries: !entries.isEmpty)

        if entries.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let empty = NSMenuItem(title: L10n.historyEmpty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        menu.addItem(NSMenuItem.separator())

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"

        for entry in entries {
            let item = NSMenuItem()
            let timestamp = formatter.string(from: entry.createdAt)
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
    }

    private func addHistoryUtilityItems(to menu: NSMenu, hasEntries: Bool) {
        let clearItem = NSMenuItem(title: L10n.historyClear, action: #selector(clearHistoryClicked), keyEquivalent: "")
        clearItem.target = self
        clearItem.image = Self.menuIcon(systemName: "trash")
        clearItem.isEnabled = hasEntries
        menu.addItem(clearItem)

        let showInFinderItem = NSMenuItem(
            title: L10n.historyShowInFinder,
            action: #selector(showHistoryInFinderClicked),
            keyEquivalent: ""
        )
        showInFinderItem.target = self
        showInFinderItem.image = Self.menuIcon(systemName: "folder")
        menu.addItem(showInFinderItem)
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
    static let textPreviewHeight: CGFloat = 64

    let entry: HistoryEntry
    private weak var target: AnyObject?
    private let action: Selector
    private let timeLabel: NSTextField

    init(entry: HistoryEntry, timestamp: String, target: AnyObject, action: Selector) {
        self.entry = entry
        self.target = target
        self.action = action

        let contentWidth = Self.itemWidth - Self.horizontalPadding * 2
        let previewBlock: (NSView, CGFloat) = {
            switch entry.kind {
            case .image:
                return Self.makeImagePreview(
                    url: entry.fileURL,
                    maxWidth: contentWidth,
                    badgeKind: HistoryMediaBadgeKind(entry: entry)
                )
            case .video:
                return Self.makeVideoPreview(url: entry.fileURL, maxWidth: contentWidth)
            case .color(let hex):
                return Self.makeColorPreview(hex: hex, maxWidth: contentWidth)
            case .text(let text):
                return Self.makeTextPreview(text.value, maxWidth: contentWidth)
            }
        }()
        let preview = previewBlock.0
        let previewHeight = previewBlock.1
        let totalHeight = Self.verticalPadding * 2 + Self.labelHeight + Self.spacing + previewHeight

        timeLabel = NSTextField(labelWithString: timestamp)
        timeLabel.isSelectable = false
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
        if entry.cloudURL != nil {
            let cloudLabel = NSTextField(labelWithString: "☁️")
            cloudLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            cloudLabel.textColor = .secondaryLabelColor
            cloudLabel.frame = NSRect(
                x: timeLabel.frame.minX + min(timeLabel.intrinsicContentSize.width, contentWidth - 18) + 4,
                y: timeLabel.frame.minY,
                width: 18,
                height: Self.labelHeight
            )
            cloudLabel.autoresizingMask = [.minYMargin]
            addSubview(cloudLabel)
        }
        addSubview(preview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseUp(with event: NSEvent) {
        if let target = target {
            _ = target.perform(action, with: self)
        }
    }

    private static func makeImagePreview(
        url: URL,
        maxWidth: CGFloat,
        badgeKind: HistoryMediaBadgeKind?
    ) -> (NSView, CGFloat) {
        makeMediaPreview(url: url, maxWidth: maxWidth, badgeKind: badgeKind, isVideo: false)
    }

    private static func makeVideoPreview(url: URL, maxWidth: CGFloat) -> (NSView, CGFloat) {
        makeMediaPreview(url: url, maxWidth: maxWidth, badgeKind: .mp4, isVideo: true)
    }

    private static func makeMediaPreview(
        url: URL,
        maxWidth: CGFloat,
        badgeKind: HistoryMediaBadgeKind?,
        isVideo: Bool
    ) -> (NSView, CGFloat) {
        let previewHeight = Self.thumbnailHeight
        let container = HistoryMenuPreviewView(frame: NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: maxWidth,
            height: previewHeight
        ))

        let imageView = NSImageView()
        imageView.isEditable = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        imageView.frame = container.bounds
        container.addSubview(imageView)

        if isVideo {
            let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
            let image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: L10n.historyPanelFilterMP4)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            imageView.image = image
            imageView.contentTintColor = .secondaryLabelColor
        }

        if let badgeKind {
            let badge = HistoryMediaBadgeView(kind: badgeKind)
            let badgeSize = badge.intrinsicContentSize
            badge.frame = NSRect(
                x: maxWidth - badgeSize.width - 6,
                y: previewHeight - badgeSize.height - 6,
                width: badgeSize.width,
                height: badgeSize.height
            )
            container.addSubview(badge)
        }

        let pixelSize = Int(max(maxWidth, previewHeight) * (NSScreen.main?.backingScaleFactor ?? 2.0))
        let completion: (HistoryImagePreview) -> Void = { [weak imageView] preview in
            guard let imageView, let cgImage = preview.cgImage else { return }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            imageView.image = NSImage(cgImage: cgImage, size: size)
            imageView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        if isVideo {
            HistoryImagePreviewLoader.shared.loadVideoFrame(url: url, pixelSize: pixelSize, completion: completion)
        } else {
            HistoryImagePreviewLoader.shared.load(url: url, pixelSize: pixelSize, completion: completion)
        }

        return (container, previewHeight)
    }

    private static func makeColorPreview(hex: String, maxWidth: CGFloat) -> (NSView, CGFloat) {
        let blockHeight = Self.colorSwatchSize
        let container = HistoryMenuPreviewView(frame: NSRect(
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
        hexLabel.isSelectable = false
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

    private static func makeTextPreview(_ text: String, maxWidth: CGFloat) -> (NSView, CGFloat) {
        let container = HistoryMenuPreviewView(frame: NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: maxWidth,
            height: Self.textPreviewHeight
        ))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor

        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 4
        label.frame = container.bounds.insetBy(dx: 9, dy: 7)
        label.autoresizingMask = [.width, .height]
        label.toolTip = text
        container.addSubview(label)
        return (container, Self.textPreviewHeight)
    }
}

private final class HistoryMenuPreviewView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
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
