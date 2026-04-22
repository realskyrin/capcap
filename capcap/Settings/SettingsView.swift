import AppKit

class SettingsView: NSView {

    var isStartup: Bool = false
    var onMenuBarToggle: ((Bool) -> Void)?
    var onLaunch: (() -> Void)?

    // Switches
    private var menuBarSwitch: NSSwitch!
    private var launchAtLoginSwitch: NSSwitch!
    private var demoModeSwitch: NSSwitch!

    // Picker & slider
    private var langPicker: NSPopUpButton!
    private var historyCacheSlider: NSSlider!
    private var historyCacheValueLabel: NSTextField!

    // Permission badges
    private var accessibilityBadge: StatusBadge!
    private var screenRecordingBadge: StatusBadge!

    // Launch button
    private var launchButton: NSButton?
    private var launchButtonContainer: NSView?
    private var launchSpacer: NSView?

    // Labels (kept for language switching)
    private var menuBarTitleLabel: NSTextField!
    private var launchAtLoginTitleLabel: NSTextField!
    private var demoModeTitleLabel: NSTextField!
    private var demoModeSubtitleLabel: NSTextField!
    private var langTitleLabel: NSTextField!
    private var historyCacheTitleLabel: NSTextField!
    private var historyCacheHintLabel: NSTextField!
    private var permHeaderLabel: NSTextField!
    private var accessibilityNameLabel: NSTextField!
    private var accessibilityDescLabel: NSTextField!
    private var screenRecordingNameLabel: NSTextField!
    private var screenRecordingDescLabel: NSTextField!

    private var refreshTimer: Timer?
    private var gradientLayer: CAGradientLayer?

    init(frame: NSRect, isStartup: Bool = false) {
        self.isStartup = isStartup
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        setupBackground()
        setupUI()
        startRefreshTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateLocalization),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
    }

    // MARK: - Background

    private func setupBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.17, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.10, alpha: 1.0).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)
        gradientLayer = gradient
    }

    // MARK: - Layout

    private func setupUI() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        addSubview(scrollView)

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        // General card (three toggle rows)
        let generalCard = CardView()
        let generalInner = verticalInnerStack()
        generalCard.addSubview(generalInner)
        pin(generalInner, to: generalCard, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))

        let menuBar = makeToggleRow(
            title: L10n.showMenuBarIcon,
            subtitle: nil,
            isOn: Defaults.showMenuBar,
            action: #selector(menuBarSwitchToggled(_:))
        )
        menuBarTitleLabel = menuBar.title
        menuBarSwitch = menuBar.toggle
        generalInner.addArrangedSubview(menuBar.row)
        generalInner.addArrangedSubview(rowDivider())

        let login = makeToggleRow(
            title: L10n.launchAtLogin,
            subtitle: nil,
            isOn: LaunchAtLogin.isEnabled,
            action: #selector(launchAtLoginToggled(_:))
        )
        launchAtLoginTitleLabel = login.title
        launchAtLoginSwitch = login.toggle
        generalInner.addArrangedSubview(login.row)
        generalInner.addArrangedSubview(rowDivider())

        let demo = makeToggleRow(
            title: L10n.demoMode,
            subtitle: L10n.demoModeHint,
            isOn: Defaults.demoMode,
            action: #selector(demoModeToggled(_:))
        )
        demoModeTitleLabel = demo.title
        demoModeSubtitleLabel = demo.subtitle
        demoModeSwitch = demo.toggle
        generalInner.addArrangedSubview(demo.row)

        stack.addArrangedSubview(generalCard)
        generalCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        // Language card
        let langCard = CardView()
        let langRow = NSStackView()
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 10
        langRow.translatesAutoresizingMaskIntoConstraints = false
        langCard.addSubview(langRow)
        pin(langRow, to: langCard, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))

        langTitleLabel = primaryLabel(L10n.languageHeader)
        langRow.addArrangedSubview(langTitleLabel)
        langRow.addArrangedSubview(flexSpacer())

        langPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        langPicker.addItems(withTitles: ["中文", "English"])
        langPicker.selectItem(at: Defaults.language == .zh ? 0 : 1)
        langPicker.target = self
        langPicker.action = #selector(languageChanged(_:))
        langPicker.controlSize = .small
        langPicker.font = NSFont.systemFont(ofSize: 12)
        langRow.addArrangedSubview(langPicker)

        stack.addArrangedSubview(langCard)
        langCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        // History cache card
        let historyCard = CardView()
        let historyInner = NSStackView()
        historyInner.orientation = .vertical
        historyInner.alignment = .leading
        historyInner.spacing = 10
        historyInner.translatesAutoresizingMaskIntoConstraints = false
        historyCard.addSubview(historyInner)
        pin(historyInner, to: historyCard, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))

        let historyHeader = NSStackView()
        historyHeader.orientation = .horizontal
        historyHeader.alignment = .firstBaseline
        historyHeader.spacing = 8
        historyHeader.translatesAutoresizingMaskIntoConstraints = false

        historyCacheTitleLabel = primaryLabel(L10n.historyCacheLabel)
        historyHeader.addArrangedSubview(historyCacheTitleLabel)
        historyHeader.addArrangedSubview(flexSpacer())

        historyCacheValueLabel = NSTextField(labelWithString: "\(Defaults.historyCacheLimit)")
        historyCacheValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        historyCacheValueLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        historyHeader.addArrangedSubview(historyCacheValueLabel)

        historyInner.addArrangedSubview(historyHeader)
        historyHeader.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

        let slider = NSSlider(
            value: Double(Defaults.historyCacheLimit),
            minValue: Double(Defaults.historyCacheMin),
            maxValue: Double(Defaults.historyCacheMax),
            target: self,
            action: #selector(historyCacheSliderChanged(_:))
        )
        slider.allowsTickMarkValuesOnly = true
        slider.numberOfTickMarks = Defaults.historyCacheMax - Defaults.historyCacheMin + 1
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        historyCacheSlider = slider
        historyInner.addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

        historyCacheHintLabel = secondaryLabel(L10n.historyCacheHint, wrapping: true)
        historyInner.addArrangedSubview(historyCacheHintLabel)
        historyCacheHintLabel.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

        stack.addArrangedSubview(historyCard)
        historyCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        // Permissions section header
        permHeaderLabel = NSTextField(labelWithString: L10n.permissionsHeader)
        permHeaderLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        permHeaderLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        permHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(permHeaderLabel)
        NSLayoutConstraint.activate([
            permHeaderLabel.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 6),
            permHeaderLabel.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            permHeaderLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 2),
            permHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerContainer.trailingAnchor),
        ])
        stack.addArrangedSubview(headerContainer)
        headerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(4, after: headerContainer)

        // Permissions card
        let permCard = CardView()
        let permInner = verticalInnerStack()
        permCard.addSubview(permInner)
        pin(permInner, to: permCard, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))

        let acc = makePermissionRow(
            name: L10n.accessibilityPermission,
            description: L10n.accessibilityDescription,
            action: #selector(openAccessibilitySettings)
        )
        accessibilityNameLabel = acc.name
        accessibilityDescLabel = acc.desc
        accessibilityBadge = acc.badge
        permInner.addArrangedSubview(acc.row)
        acc.row.widthAnchor.constraint(equalTo: permInner.widthAnchor).isActive = true
        permInner.addArrangedSubview(rowDivider())

        let sc = makePermissionRow(
            name: L10n.screenRecordingPermission,
            description: L10n.screenRecordingDescription,
            action: #selector(openScreenRecordingSettings)
        )
        screenRecordingNameLabel = sc.name
        screenRecordingDescLabel = sc.desc
        screenRecordingBadge = sc.badge
        permInner.addArrangedSubview(sc.row)
        sc.row.widthAnchor.constraint(equalTo: permInner.widthAnchor).isActive = true

        stack.addArrangedSubview(permCard)
        permCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        // Spacer (only shown in startup mode to breathe before launch button)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        stack.addArrangedSubview(spacer)
        launchSpacer = spacer

        // Launch button
        let btn = NSButton(title: L10n.launchApp, target: self, action: #selector(launchClicked))
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        btn.keyEquivalent = "\r"
        btn.translatesAutoresizingMaskIntoConstraints = false
        launchButton = btn

        let btnContainer = NSView()
        btnContainer.translatesAutoresizingMaskIntoConstraints = false
        btnContainer.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: btnContainer.centerXAnchor),
            btn.topAnchor.constraint(equalTo: btnContainer.topAnchor, constant: 4),
            btn.bottomAnchor.constraint(equalTo: btnContainer.bottomAnchor, constant: -4),
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        stack.addArrangedSubview(btnContainer)
        btnContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        launchButtonContainer = btnContainer

        updateLaunchButtonVisibility()
        refreshPermissionStatus()
    }

    // MARK: - Builders

    private func verticalInnerStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func rowDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func flexSpacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func primaryLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        l.textColor = NSColor.white.withAlphaComponent(0.94)
        return l
    }

    private func secondaryLabel(_ text: String, wrapping: Bool = false) -> NSTextField {
        let l = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = NSColor.white.withAlphaComponent(0.58)
        if wrapping {
            l.preferredMaxLayoutWidth = 320
        }
        return l
    }

    private func pin(_ child: NSView, to parent: NSView, insets: NSEdgeInsets) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }

    private struct ToggleRowBuild {
        let row: NSView
        let title: NSTextField
        let subtitle: NSTextField?
        let toggle: NSSwitch
    }

    private func makeToggleRow(
        title: String,
        subtitle: String?,
        isOn: Bool,
        action: Selector
    ) -> ToggleRowBuild {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = primaryLabel(title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)

        var subtitleLabel: NSTextField? = nil
        if let subtitle {
            let sub = secondaryLabel(subtitle, wrapping: true)
            textStack.addArrangedSubview(sub)
            subtitleLabel = sub
        }

        let sw = NSSwitch()
        sw.state = isOn ? .on : .off
        sw.target = self
        sw.action = action
        sw.controlSize = .small
        sw.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(textStack)
        row.addSubview(sw)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: sw.leadingAnchor, constant: -12),

            sw.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            sw.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
        ])

        return ToggleRowBuild(row: row, title: titleLabel, subtitle: subtitleLabel, toggle: sw)
    }

    private struct PermissionRowBuild {
        let row: NSView
        let name: NSTextField
        let desc: NSTextField
        let badge: StatusBadge
    }

    private func makePermissionRow(
        name: String,
        description: String,
        action: Selector
    ) -> PermissionRowBuild {
        let button = HoverButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = action
        button.title = ""
        button.isBordered = false
        button.cornerRadius = 10

        let nameLbl = primaryLabel(name)
        nameLbl.translatesAutoresizingMaskIntoConstraints = false

        let badge = StatusBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false

        let topLine = NSStackView(views: [nameLbl, badge])
        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = 8
        topLine.translatesAutoresizingMaskIntoConstraints = false

        let descLbl = secondaryLabel(description, wrapping: true)
        descLbl.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(topLine)
        textStack.addArrangedSubview(descLbl)

        let chevron = NSTextField(labelWithString: "\u{203A}")
        chevron.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        chevron.textColor = NSColor.white.withAlphaComponent(0.32)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        button.addSubview(textStack)
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: button.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12),
            textStack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -10),

            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
        ])

        return PermissionRowBuild(row: button, name: nameLbl, desc: descLbl, badge: badge)
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

    // MARK: - Permission polling

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }

    func refreshPermissionStatus() {
        let accessibilityGranted = AXIsProcessTrusted()
        let screenRecordingGranted = checkScreenRecordingPermission()

        accessibilityBadge?.configure(granted: accessibilityGranted)
        screenRecordingBadge?.configure(granted: screenRecordingGranted)

        let allGranted = accessibilityGranted && screenRecordingGranted
        launchButton?.isEnabled = allGranted
        launchButton?.keyEquivalent = allGranted ? "\r" : ""
    }

    func checkScreenRecordingPermission() -> Bool {
        if #available(macOS 15.0, *) {
            return CGPreflightScreenCaptureAccess()
        } else {
            guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let foreignWindow = windowList.first { info in
                guard let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return false }
                return pid != myPID
            }
            guard let windowID = foreignWindow?[kCGWindowNumber as String] as? CGWindowID else {
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

    // MARK: - Actions

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        Defaults.language = sender.indexOfSelectedItem == 0 ? .zh : .en
    }

    @objc private func historyCacheSliderChanged(_ sender: NSSlider) {
        let value = Int(sender.doubleValue.rounded())
        Defaults.historyCacheLimit = value
        historyCacheValueLabel?.stringValue = "\(Defaults.historyCacheLimit)"
    }

    @objc private func launchAtLoginToggled(_ sender: NSSwitch) {
        let enable = sender.state == .on
        let ok = LaunchAtLogin.setEnabled(enable)
        if !ok {
            sender.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }

    @objc private func demoModeToggled(_ sender: NSSwitch) {
        Defaults.demoMode = sender.state == .on
    }

    @objc private func menuBarSwitchToggled(_ sender: NSSwitch) {
        let visible = sender.state == .on
        Defaults.showMenuBar = visible
        onMenuBarToggle?(visible)
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecordingSettings() {
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

    @objc private func updateLocalization() {
        menuBarTitleLabel?.stringValue = L10n.showMenuBarIcon
        launchAtLoginTitleLabel?.stringValue = L10n.launchAtLogin
        demoModeTitleLabel?.stringValue = L10n.demoMode
        demoModeSubtitleLabel?.stringValue = L10n.demoModeHint
        langTitleLabel?.stringValue = L10n.languageHeader
        permHeaderLabel?.stringValue = L10n.permissionsHeader
        accessibilityNameLabel?.stringValue = L10n.accessibilityPermission
        accessibilityDescLabel?.stringValue = L10n.accessibilityDescription
        screenRecordingNameLabel?.stringValue = L10n.screenRecordingPermission
        screenRecordingDescLabel?.stringValue = L10n.screenRecordingDescription
        historyCacheTitleLabel?.stringValue = L10n.historyCacheLabel
        historyCacheHintLabel?.stringValue = L10n.historyCacheHint
        launchButton?.title = L10n.launchApp
        accessibilityBadge?.refreshTitle()
        screenRecordingBadge?.refreshTitle()
        window?.title = L10n.settingsTitle
    }
}

// MARK: - Flipped stack view (for top-aligned scrolling)

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - Card view

private final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
    }
}

// MARK: - Status badge

final class StatusBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var granted: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    func configure(granted: Bool) {
        self.granted = granted
        refreshTitle()
    }

    func refreshTitle() {
        let zh = L10n.lang == .zh
        let color: NSColor = granted ? .systemGreen : .systemOrange
        label.stringValue = granted ? (zh ? "已授权" : "Granted") : (zh ? "未授权" : "Not granted")
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
    }
}

// MARK: - Hover button (clickable permission row)

private final class HoverButton: NSButton {
    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        (cell as? NSButtonCell)?.highlightsBy = []
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }
}
