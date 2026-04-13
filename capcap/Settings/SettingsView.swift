import AppKit

class SettingsView: NSView {

    var isStartup: Bool = false
    var onMenuBarToggle: ((Bool) -> Void)?
    var onLaunch: (() -> Void)?

    private var accessibilityStatusLabel: NSTextField!
    private var screenRecordingStatusLabel: NSTextField!
    private var accessibilityDescLabel: NSTextField!
    private var screenRecordingDescLabel: NSTextField!
    private var launchButton: NSButton?
    private var launchSpacer: NSView?
    private var launchButtonContainer: NSView?
    private var menuBarCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var refreshTimer: Timer?

    // Localized label references for dynamic language switching
    private var langLabel: NSTextField!
    private var permHeader: NSTextField!
    private var accessibilityNameLabel: NSTextField!
    private var screenRecordingNameLabel: NSTextField!

    init(frame: NSRect, isStartup: Bool = false) {
        self.isStartup = isStartup
        super.init(frame: frame)
        setupUI()
        startRefreshTimer()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLocalization), name: .languageDidChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Menu bar checkbox
        menuBarCheckbox = NSButton(checkboxWithTitle: L10n.showMenuBarIcon, target: self, action: #selector(menuBarCheckboxToggled(_:)))
        menuBarCheckbox.state = Defaults.showMenuBar ? .on : .off
        menuBarCheckbox.font = NSFont.systemFont(ofSize: 13)
        contentStack.addArrangedSubview(menuBarCheckbox)

        // Launch at login checkbox
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: L10n.launchAtLogin, target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginCheckbox.font = NSFont.systemFont(ofSize: 13)
        contentStack.addArrangedSubview(launchAtLoginCheckbox)

        // Language picker
        let langRow = NSStackView()
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 8

        langLabel = NSTextField(labelWithString: L10n.languageHeader)
        langLabel.font = NSFont.systemFont(ofSize: 13)
        langRow.addArrangedSubview(langLabel)

        let langPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        langPicker.addItems(withTitles: ["中文", "English"])
        langPicker.selectItem(at: Defaults.language == .zh ? 0 : 1)
        langPicker.target = self
        langPicker.action = #selector(languageChanged(_:))
        langRow.addArrangedSubview(langPicker)

        contentStack.addArrangedSubview(langRow)

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        contentStack.addArrangedSubview(sep2)
        sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true

        // Permissions header
        permHeader = NSTextField(labelWithString: L10n.permissionsHeader)
        permHeader.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        contentStack.addArrangedSubview(permHeader)

        // Accessibility row
        let accessibilityRow = makePermissionRow(
            name: L10n.accessibilityPermission,
            description: L10n.accessibilityDescription,
            nameLabel: &accessibilityNameLabel,
            statusLabel: &accessibilityStatusLabel,
            descLabel: &accessibilityDescLabel,
            action: #selector(openAccessibilitySettings)
        )
        contentStack.addArrangedSubview(accessibilityRow)
        accessibilityRow.translatesAutoresizingMaskIntoConstraints = false
        accessibilityRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true

        // Screen Recording row
        let screenRow = makePermissionRow(
            name: L10n.screenRecordingPermission,
            description: L10n.screenRecordingDescription,
            nameLabel: &screenRecordingNameLabel,
            statusLabel: &screenRecordingStatusLabel,
            descLabel: &screenRecordingDescLabel,
            action: #selector(openScreenRecordingSettings)
        )
        contentStack.addArrangedSubview(screenRow)
        screenRow.translatesAutoresizingMaskIntoConstraints = false
        screenRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true

        // Spacer (for launch mode)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentStack.addArrangedSubview(spacer)
        launchSpacer = spacer

        // Launch button
        let btn = NSButton(title: L10n.launchApp, target: self, action: #selector(launchClicked))
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        btn.controlSize = .large
        btn.translatesAutoresizingMaskIntoConstraints = false
        launchButton = btn

        let buttonContainer = NSView()
        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        buttonContainer.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: buttonContainer.centerXAnchor),
            btn.topAnchor.constraint(equalTo: buttonContainer.topAnchor),
            btn.bottomAnchor.constraint(equalTo: buttonContainer.bottomAnchor),
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        contentStack.addArrangedSubview(buttonContainer)
        buttonContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -48).isActive = true
        launchButtonContainer = buttonContainer

        updateLaunchButtonVisibility()

        refreshPermissionStatus()
    }

    private func updateLaunchButtonVisibility() {
        let visible = isStartup
        launchSpacer?.isHidden = !visible
        launchButtonContainer?.isHidden = !visible
    }

    func setStartupMode(_ startup: Bool) {
        isStartup = startup
        updateLaunchButtonVisibility()
    }

    private func makePermissionRow(
        name: String,
        description: String,
        nameLabel: inout NSTextField!,
        statusLabel: inout NSTextField!,
        descLabel: inout NSTextField!,
        action: Selector
    ) -> NSView {
        let container = NSButton()
        container.title = ""
        container.bezelStyle = .recessed
        container.isBordered = false
        container.target = self
        container.action = action
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconLabel = NSTextField(labelWithString: "")
        iconLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel = iconLabel

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let nameLbl = NSTextField(labelWithString: name)
        nameLbl.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel = nameLbl
        textStack.addArrangedSubview(nameLbl)

        let desc = NSTextField(wrappingLabelWithString: description)
        desc.font = NSFont.systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 300
        descLabel = desc
        textStack.addArrangedSubview(desc)

        let arrowLabel = NSTextField(labelWithString: "\u{203A}")
        arrowLabel.font = NSFont.systemFont(ofSize: 16)
        arrowLabel.textColor = .tertiaryLabelColor
        arrowLabel.translatesAutoresizingMaskIntoConstraints = false
        arrowLabel.setContentHuggingPriority(.required, for: .horizontal)

        let rowStack = NSStackView(views: [iconLabel, textStack, arrowLabel])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])

        return container
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }

    func refreshPermissionStatus() {
        let accessibilityGranted = AXIsProcessTrusted()
        let screenRecordingGranted = checkScreenRecordingPermission()

        updateStatusLabel(accessibilityStatusLabel, granted: accessibilityGranted)
        updateStatusLabel(screenRecordingStatusLabel, granted: screenRecordingGranted)

        let allGranted = accessibilityGranted && screenRecordingGranted
        launchButton?.isEnabled = allGranted
        if allGranted {
            launchButton?.keyEquivalent = "\r"
        } else {
            launchButton?.keyEquivalent = ""
        }
    }

    private func updateStatusLabel(_ label: NSTextField, granted: Bool) {
        if granted {
            label.stringValue = "\u{2713}"
            label.textColor = .systemGreen
        } else {
            label.stringValue = "\u{2717}"
            label.textColor = .systemRed
        }
    }

    func checkScreenRecordingPermission() -> Bool {
        if #available(macOS 15.0, *) {
            return CGPreflightScreenCaptureAccess()
        } else {
            // Fallback: try to capture a 1x1 region; if screen recording is denied
            // the result will be nil or a blank image for non-owned windows.
            guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            // Find a window not owned by our app
            let myPID = ProcessInfo.processInfo.processIdentifier
            let foreignWindow = windowList.first { info in
                guard let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return false }
                return pid != myPID
            }
            guard let windowID = foreignWindow?[kCGWindowNumber as String] as? CGWindowID else {
                // No foreign windows on screen; assume granted since we can't test
                return true
            }
            let image = CGWindowListCreateImage(
                CGRect(x: 0, y: 0, width: 1, height: 1),
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming]
            )
            return image != nil
        }
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        Defaults.language = sender.indexOfSelectedItem == 0 ? .zh : .en
    }

    @objc private func updateLocalization() {
        menuBarCheckbox?.title = L10n.showMenuBarIcon
        launchAtLoginCheckbox?.title = L10n.launchAtLogin
        langLabel?.stringValue = L10n.languageHeader
        permHeader?.stringValue = L10n.permissionsHeader
        accessibilityNameLabel?.stringValue = L10n.accessibilityPermission
        accessibilityDescLabel?.stringValue = L10n.accessibilityDescription
        screenRecordingNameLabel?.stringValue = L10n.screenRecordingPermission
        screenRecordingDescLabel?.stringValue = L10n.screenRecordingDescription
        launchButton?.title = L10n.launchApp
        window?.title = L10n.settingsTitle
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let enable = sender.state == .on
        let ok = LaunchAtLogin.setEnabled(enable)
        if !ok {
            sender.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    @objc private func menuBarCheckboxToggled(_ sender: NSButton) {
        let visible = sender.state == .on
        Defaults.showMenuBar = visible
        onMenuBarToggle?(visible)
    }

    @objc private func openAccessibilitySettings() {
        // Trigger the system permission prompt, then open System Settings
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() {
        // Trigger the system permission prompt on macOS 15+, then open System Settings
        if #available(macOS 15.0, *) {
            CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func launchClicked() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onLaunch?()
    }
}
