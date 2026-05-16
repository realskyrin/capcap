import AppKit
import Carbon

// MARK: - Tab model

enum SettingsTab: CaseIterable {
    case general
    case shortcuts
    case upload
    case permissions
    case about

    var title: String {
        switch self {
        case .general: return L10n.settingsTabGeneral
        case .shortcuts: return L10n.settingsTabShortcuts
        case .upload: return L10n.settingsTabUpload
        case .permissions: return L10n.settingsTabPermissions
        case .about: return L10n.settingsTabAbout
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "keyboard"
        case .upload: return "icloud.and.arrow.up.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var iconTint: NSColor {
        switch self {
        case .general: return NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.72, alpha: 1.0)
        case .shortcuts: return NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.98, alpha: 1.0)
        case .upload: return NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1.0)
        case .permissions: return NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.50, alpha: 1.0)
        case .about: return NSColor(calibratedRed: 0.70, green: 0.56, blue: 0.96, alpha: 1.0)
        }
    }
}

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
    private var countdownSlider: NSSlider!
    private var countdownValueLabel: NSTextField!
    private var countdownTitleLabel: NSTextField!
    private var countdownHintLabel: NSTextField!

    // Shortcut card
    private var shortcutTitleLabel: NSTextField!
    private var shortcutHintLabel: NSTextField!
    private var shortcutField: NSTextField!
    private var shortcutSetButton: NSButton!
    private var shortcutRestoreButton: NSButton!
    private var shortcutRecordingMonitor: Any?

    // Permission badges
    private var accessibilityBadge: StatusBadge!
    private var screenRecordingBadge: StatusBadge!

    // Sidebar bottom action — Launch App in startup mode, Quit App otherwise.
    private var launchButton: ActionButton?

    // Labels (kept for language switching)
    private var menuBarTitleLabel: NSTextField!
    private var launchAtLoginTitleLabel: NSTextField!
    private var demoModeTitleLabel: NSTextField!
    private var demoModeSubtitleLabel: NSTextField!
    private var langTitleLabel: NSTextField!
    private var historyCacheTitleLabel: NSTextField!
    private var historyCacheHintLabel: NSTextField!
    private var permHeaderSubtitleLabel: NSTextField?
    private var accessibilityNameLabel: NSTextField!
    private var accessibilityDescLabel: NSTextField!
    private var screenRecordingNameLabel: NSTextField!
    private var screenRecordingDescLabel: NSTextField!
    private var aboutTaglineLabel: NSTextField?
    private var aboutLicenseTitleLabel: NSTextField?
    private var aboutSourceTitleLabel: NSTextField?
    private var aboutUpdateTitleLabel: NSTextField?
    private var aboutUpdateStatusLabel: NSTextField?
    private var aboutUpdateButton: NSButton?

    // Sidebar / detail chrome
    private var selectedTab: SettingsTab = .general
    private var tabButtons: [TabButton] = []
    private var detailTitleLabel: NSTextField!
    private var detailScrollView: NSScrollView!
    private var paneContainer: NSView!
    private var paneViews: [SettingsTab: NSView] = [:]
    private var uploadPane: UploadSettingsPane?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshUpdateRow),
            name: .updateStateDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        cancelShortcutRecording()
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
        let sidebar = buildSidebar()
        addSubview(sidebar)

        let detail = buildDetailPanel()
        addSubview(detail)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            sidebar.widthAnchor.constraint(equalToConstant: 224),

            detail.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            detail.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        // Build all panes
        paneViews[.general] = buildGeneralPane()
        paneViews[.shortcuts] = buildShortcutsPane()
        paneViews[.upload] = buildUploadPane()
        paneViews[.permissions] = buildPermissionsPane()
        paneViews[.about] = buildAboutPane()

        // Default selection
        let initial: SettingsTab = isStartup ? .permissions : .general
        selectTab(initial)

        updateLaunchButtonVisibility()
        refreshPermissionStatus()
        refreshShortcutDisplay()
    }

    // MARK: - Sidebar

    private func buildSidebar() -> NSView {
        let panel = SidebarPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        for tab in SettingsTab.allCases {
            let btn = TabButton(tab: tab)
            btn.target = self
            btn.action = #selector(tabClicked(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            tabButtons.append(btn)
            stack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Hairline above the bottom action so the sidebar visually splits
        // navigation from the primary launch/quit affordance.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(divider)

        let bottomBtn = ActionButton(symbolName: "power", title: L10n.launchApp, tint: .systemGreen)
        bottomBtn.target = self
        bottomBtn.action = #selector(launchClicked)
        bottomBtn.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(bottomBtn)
        launchButton = bottomBtn

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: divider.topAnchor, constant: -8),

            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            divider.bottomAnchor.constraint(equalTo: bottomBtn.topAnchor, constant: -8),

            bottomBtn.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            bottomBtn.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            bottomBtn.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])

        return panel
    }

    private func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(short)"
    }

    @objc private func tabClicked(_ sender: TabButton) {
        selectTab(sender.tab)
    }

    private func selectTab(_ tab: SettingsTab) {
        // Drop the Upload tab's in-memory log when navigating away so it
        // starts fresh next time the user opens it.
        if selectedTab == .upload && tab != .upload {
            uploadPane?.clearLogs()
        }
        selectedTab = tab
        for btn in tabButtons {
            btn.isSelected = (btn.tab == tab)
        }
        detailTitleLabel?.stringValue = tab.title

        // Swap pane content
        guard let pane = paneViews[tab] else { return }
        for sub in paneContainer.subviews { sub.removeFromSuperview() }
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            pane.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
        ])
    }

    // MARK: - Detail panel

    private func buildDetailPanel() -> NSView {
        let panel = DetailPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let title = NSTextField(labelWithString: SettingsTab.general.title)
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.textColor = NSColor.white.withAlphaComponent(0.96)
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)
        detailTitleLabel = title

        // Scroll view fills the rest of the panel — the launch / quit action
        // lives in the sidebar bottom now, freeing the right-pane footer.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        panel.addSubview(scroll)
        detailScrollView = scroll

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        paneContainer = container

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            title.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -22),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        return panel
    }

    // MARK: - Pane builders

    private func buildGeneralPane() -> NSView {
        let stack = paneStack()

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
        langCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Toggles card
        let togglesCard = CardView()
        let togglesInner = verticalInnerStack()
        togglesCard.addSubview(togglesInner)
        pin(togglesInner, to: togglesCard, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))

        let menuBar = makeToggleRow(
            title: L10n.showMenuBarIcon,
            subtitle: nil,
            isOn: Defaults.showMenuBar,
            action: #selector(menuBarSwitchToggled(_:))
        )
        menuBarTitleLabel = menuBar.title
        menuBarSwitch = menuBar.toggle
        togglesInner.addArrangedSubview(menuBar.row)
        menuBar.row.widthAnchor.constraint(equalTo: togglesInner.widthAnchor).isActive = true
        togglesInner.addArrangedSubview(rowDivider())

        let login = makeToggleRow(
            title: L10n.launchAtLogin,
            subtitle: nil,
            isOn: LaunchAtLogin.isEnabled,
            action: #selector(launchAtLoginToggled(_:))
        )
        launchAtLoginTitleLabel = login.title
        launchAtLoginSwitch = login.toggle
        togglesInner.addArrangedSubview(login.row)
        login.row.widthAnchor.constraint(equalTo: togglesInner.widthAnchor).isActive = true
        togglesInner.addArrangedSubview(rowDivider())

        let demo = makeToggleRow(
            title: L10n.demoMode,
            subtitle: L10n.demoModeHint,
            isOn: Defaults.demoMode,
            action: #selector(demoModeToggled(_:))
        )
        demoModeTitleLabel = demo.title
        demoModeSubtitleLabel = demo.subtitle
        demoModeSwitch = demo.toggle
        togglesInner.addArrangedSubview(demo.row)
        demo.row.widthAnchor.constraint(equalTo: togglesInner.widthAnchor).isActive = true

        stack.addArrangedSubview(togglesCard)
        togglesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return wrapPane(stack)
    }

    private func buildShortcutsPane() -> NSView {
        let stack = paneStack()

        // Shortcut card
        let shortcutCard = CardView()
        let shortcutInner = NSStackView()
        shortcutInner.orientation = .vertical
        shortcutInner.alignment = .leading
        shortcutInner.spacing = 8
        shortcutInner.translatesAutoresizingMaskIntoConstraints = false
        shortcutCard.addSubview(shortcutInner)
        pin(shortcutInner, to: shortcutCard, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        let shortcutRow = NSStackView()
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 8
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false

        shortcutTitleLabel = primaryLabel(L10n.shortcutHeader)
        shortcutRow.addArrangedSubview(shortcutTitleLabel)
        shortcutRow.addArrangedSubview(flexSpacer())

        shortcutField = NSTextField()
        shortcutField.isEditable = false
        shortcutField.isSelectable = false
        shortcutField.isBordered = false
        shortcutField.drawsBackground = false
        shortcutField.alignment = .center
        shortcutField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        shortcutField.textColor = NSColor.white.withAlphaComponent(0.92)
        shortcutField.translatesAutoresizingMaskIntoConstraints = false

        let fieldBackground = NSView()
        fieldBackground.wantsLayer = true
        fieldBackground.layer?.cornerRadius = 5
        fieldBackground.layer?.cornerCurve = .continuous
        fieldBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        fieldBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        fieldBackground.layer?.borderWidth = 1
        fieldBackground.translatesAutoresizingMaskIntoConstraints = false
        fieldBackground.addSubview(shortcutField)
        NSLayoutConstraint.activate([
            shortcutField.topAnchor.constraint(equalTo: fieldBackground.topAnchor, constant: 4),
            shortcutField.bottomAnchor.constraint(equalTo: fieldBackground.bottomAnchor, constant: -4),
            shortcutField.leadingAnchor.constraint(equalTo: fieldBackground.leadingAnchor, constant: 10),
            shortcutField.trailingAnchor.constraint(equalTo: fieldBackground.trailingAnchor, constant: -10),
            fieldBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        shortcutRow.addArrangedSubview(fieldBackground)

        shortcutSetButton = NSButton(title: L10n.shortcutSet, target: self, action: #selector(shortcutSetClicked))
        shortcutSetButton.bezelStyle = .rounded
        shortcutSetButton.controlSize = .small
        shortcutSetButton.font = NSFont.systemFont(ofSize: 12)
        shortcutSetButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutRow.addArrangedSubview(shortcutSetButton)

        shortcutRestoreButton = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L10n.shortcutRestore) ?? NSImage(), target: self, action: #selector(shortcutRestoreClicked))
        shortcutRestoreButton.bezelStyle = .inline
        shortcutRestoreButton.isBordered = false
        shortcutRestoreButton.imagePosition = .imageOnly
        shortcutRestoreButton.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        shortcutRestoreButton.toolTip = L10n.shortcutRestore
        shortcutRestoreButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutRestoreButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        shortcutRow.addArrangedSubview(shortcutRestoreButton)

        shortcutInner.addArrangedSubview(shortcutRow)
        shortcutRow.widthAnchor.constraint(equalTo: shortcutInner.widthAnchor).isActive = true

        shortcutHintLabel = secondaryLabel(L10n.shortcutHint, wrapping: true)
        shortcutInner.addArrangedSubview(shortcutHintLabel)
        shortcutHintLabel.widthAnchor.constraint(equalTo: shortcutInner.widthAnchor).isActive = true

        stack.addArrangedSubview(shortcutCard)
        shortcutCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

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
        historyCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Countdown card
        let countdownCard = CardView()
        let countdownInner = NSStackView()
        countdownInner.orientation = .vertical
        countdownInner.alignment = .leading
        countdownInner.spacing = 10
        countdownInner.translatesAutoresizingMaskIntoConstraints = false
        countdownCard.addSubview(countdownInner)
        pin(countdownInner, to: countdownCard, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))

        let countdownHeader = NSStackView()
        countdownHeader.orientation = .horizontal
        countdownHeader.alignment = .firstBaseline
        countdownHeader.spacing = 8
        countdownHeader.translatesAutoresizingMaskIntoConstraints = false

        countdownTitleLabel = primaryLabel(L10n.countdownLabel)
        countdownHeader.addArrangedSubview(countdownTitleLabel)
        countdownHeader.addArrangedSubview(flexSpacer())

        countdownValueLabel = NSTextField(labelWithString: "\(Defaults.countdownSeconds)\(L10n.countdownSecondsSuffix)")
        countdownValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        countdownValueLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        countdownHeader.addArrangedSubview(countdownValueLabel)

        countdownInner.addArrangedSubview(countdownHeader)
        countdownHeader.widthAnchor.constraint(equalTo: countdownInner.widthAnchor).isActive = true

        let cdSlider = NSSlider(
            value: Double(Defaults.countdownSeconds),
            minValue: Double(Defaults.countdownSecondsMin),
            maxValue: Double(Defaults.countdownSecondsMax),
            target: self,
            action: #selector(countdownSliderChanged(_:))
        )
        cdSlider.allowsTickMarkValuesOnly = true
        cdSlider.numberOfTickMarks = Defaults.countdownSecondsMax - Defaults.countdownSecondsMin + 1
        cdSlider.controlSize = .small
        cdSlider.translatesAutoresizingMaskIntoConstraints = false
        countdownSlider = cdSlider
        countdownInner.addArrangedSubview(cdSlider)
        cdSlider.widthAnchor.constraint(equalTo: countdownInner.widthAnchor).isActive = true

        countdownHintLabel = secondaryLabel(L10n.countdownHint, wrapping: true)
        countdownInner.addArrangedSubview(countdownHintLabel)
        countdownHintLabel.widthAnchor.constraint(equalTo: countdownInner.widthAnchor).isActive = true

        stack.addArrangedSubview(countdownCard)
        countdownCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return wrapPane(stack)
    }

    private func buildUploadPane() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let pane = UploadSettingsPane()
        uploadPane = pane
        host.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    private func buildPermissionsPane() -> NSView {
        let stack = paneStack()

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
        permCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return wrapPane(stack)
    }

    private func buildAboutPane() -> NSView {
        let stack = paneStack()

        // Header card — app icon, name and version.
        let headerCard = CardView()
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 14
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(headerRow)
        pin(headerRow, to: headerCard, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 56).isActive = true
        headerRow.addArrangedSubview(iconView)

        let nameLabel = NSTextField(labelWithString: "capcap")
        nameLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.96)

        let versionLabel = NSTextField(labelWithString: appVersionString())
        versionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = NSColor.white.withAlphaComponent(0.55)

        let taglineLabel = secondaryLabel(L10n.aboutTagline, wrapping: true)
        aboutTaglineLabel = taglineLabel

        let textStack = NSStackView(views: [nameLabel, versionLabel, taglineLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(textStack)
        headerRow.addArrangedSubview(flexSpacer())

        stack.addArrangedSubview(headerCard)
        headerCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Info card — license + source link rows.
        let infoCard = CardView()
        let infoInner = verticalInnerStack()
        infoCard.addSubview(infoInner)
        pin(infoInner, to: infoCard, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))

        let updateRow = makeUpdateRow()
        infoInner.addArrangedSubview(updateRow)
        updateRow.widthAnchor.constraint(equalTo: infoInner.widthAnchor).isActive = true
        infoInner.addArrangedSubview(rowDivider())

        let license = makeInfoRow(title: L10n.aboutLicense, value: "MIT")
        aboutLicenseTitleLabel = license.title
        infoInner.addArrangedSubview(license.row)
        license.row.widthAnchor.constraint(equalTo: infoInner.widthAnchor).isActive = true
        infoInner.addArrangedSubview(rowDivider())

        let repo = makeLinkRow(
            title: L10n.aboutSourceCode,
            value: "github.com/realskyrin/capcap",
            action: #selector(openSourceRepo)
        )
        aboutSourceTitleLabel = repo.title
        infoInner.addArrangedSubview(repo.row)
        repo.row.widthAnchor.constraint(equalTo: infoInner.widthAnchor).isActive = true

        stack.addArrangedSubview(infoCard)
        infoCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return wrapPane(stack)
    }

    /// Static left-title / right-value row, mirroring the permission row chrome.
    private func makeInfoRow(title: String, value: String) -> (row: NSView, title: NSTextField) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = primaryLabel(title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(titleLabel)
        row.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
        ])
        return (row, titleLabel)
    }

    /// Tappable row that opens an external URL, with a chevron affordance.
    private func makeLinkRow(title: String, value: String, action: Selector) -> (row: NSView, title: NSTextField) {
        let button = HoverButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = action
        button.title = ""
        button.isBordered = false
        button.cornerRadius = 10

        let titleLabel = primaryLabel(title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.98, alpha: 1.0)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let chevron = NSTextField(labelWithString: "\u{203A}")
        chevron.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        chevron.textColor = NSColor.white.withAlphaComponent(0.32)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        button.addSubview(titleLabel)
        button.addSubview(valueLabel)
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 46),
            titleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
        ])
        return (button, titleLabel)
    }

    @objc private func openSourceRepo() {
        if let url = URL(string: "https://github.com/realskyrin/capcap") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Updates" row — a status label plus a button whose role tracks state:
    /// "Check for Updates" normally, "Download" once a newer release is found.
    private func makeUpdateRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = primaryLabel(L10n.aboutUpdateTitle)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        aboutUpdateTitleLabel = titleLabel

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        aboutUpdateStatusLabel = statusLabel

        let button = NSButton(title: L10n.checkForUpdates, target: self,
                              action: #selector(aboutUpdateButtonClicked))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        aboutUpdateButton = button

        row.addSubview(titleLabel)
        row.addSubview(statusLabel)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
        ])

        refreshUpdateRow()
        return row
    }

    @objc private func aboutUpdateButtonClicked() {
        if case .available(_, let url) = UpdateChecker.shared.state {
            NSWorkspace.shared.open(url)
        } else {
            UpdateChecker.shared.check(manual: true)
        }
    }

    /// Syncs the Updates row to the current check state.
    @objc private func refreshUpdateRow() {
        guard let statusLabel = aboutUpdateStatusLabel, let button = aboutUpdateButton else { return }
        let dim = NSColor.white.withAlphaComponent(0.55)
        let accent = NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.98, alpha: 1.0)
        let warn = NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.45, alpha: 1.0)

        switch UpdateChecker.shared.state {
        case .idle:
            statusLabel.stringValue = "v\(UpdateChecker.shared.currentVersion)"
            statusLabel.textColor = dim
            button.title = L10n.checkForUpdates
            button.isEnabled = true
        case .checking:
            statusLabel.stringValue = L10n.updateChecking
            statusLabel.textColor = dim
            button.title = L10n.checkForUpdates
            button.isEnabled = false
        case .upToDate:
            statusLabel.stringValue = L10n.updateUpToDateStatus
            statusLabel.textColor = dim
            button.title = L10n.checkForUpdates
            button.isEnabled = true
        case .available(let version, _):
            statusLabel.stringValue = L10n.updateNewVersionStatus(version)
            statusLabel.textColor = accent
            button.title = L10n.updateDownloadButton
            button.isEnabled = true
        case .failed:
            statusLabel.stringValue = L10n.updateFailedStatus
            statusLabel.textColor = warn
            button.title = L10n.updateRetryButton
            button.isEnabled = true
        }
    }

    private func paneStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 12
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func wrapPane(_ stack: NSStackView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22),
        ])
        return host
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
            l.preferredMaxLayoutWidth = 360
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
        // The bottom action is always visible now — its title and enablement
        // flips between Launch (startup mode) and Quit (regular mode).
        refreshBottomAction()
    }

    private func refreshBottomAction() {
        guard let btn = launchButton else { return }
        if isStartup {
            let allGranted = AXIsProcessTrusted() && checkScreenRecordingPermission()
            btn.update(symbolName: "power", title: L10n.launchApp, tint: .systemGreen)
            btn.isEnabled = allGranted
        } else {
            // Red tint — actual destructive confirmation happens in the NSAlert
            // sheet that fires on click.
            btn.update(symbolName: "power", title: L10n.settingsQuit, tint: .systemRed)
            btn.isEnabled = true
        }
    }

    func setStartupMode(_ startup: Bool) {
        isStartup = startup
        updateLaunchButtonVisibility()
        if startup {
            selectTab(.permissions)
        }
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

        // Only the startup-mode Launch button is gated on permissions; the
        // regular-mode Quit button stays enabled.
        if isStartup {
            refreshBottomAction()
        }
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

    @objc private func countdownSliderChanged(_ sender: NSSlider) {
        let value = Int(sender.doubleValue.rounded())
        Defaults.countdownSeconds = value
        countdownValueLabel?.stringValue = "\(Defaults.countdownSeconds)\(L10n.countdownSecondsSuffix)"
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
        if isStartup {
            refreshTimer?.invalidate()
            refreshTimer = nil
            onLaunch?()
        } else {
            confirmQuit()
        }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = L10n.quitConfirmTitle
        alert.informativeText = L10n.quitConfirmMessage
        alert.alertStyle = .warning
        let quitBtn = alert.addButton(withTitle: L10n.quitConfirmAction)
        if #available(macOS 11.0, *) {
            quitBtn.hasDestructiveAction = true
        }
        let cancelBtn = alert.addButton(withTitle: L10n.quitConfirmCancel)
        cancelBtn.keyEquivalent = "\u{1b}" // Escape

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            }
        }
        if let win = self.window {
            alert.beginSheetModal(for: win, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    // MARK: - Shortcut recording

    @objc private func shortcutSetClicked() {
        if shortcutRecordingMonitor != nil {
            cancelShortcutRecording()
            return
        }
        HotkeyManager.shared.beginRecording()
        shortcutSetButton.title = L10n.shortcutCancel
        shortcutField.stringValue = L10n.shortcutWaiting
        shortcutRestoreButton.isHidden = true

        shortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            // Reject bare keys (no modifier and not a function key) — the user must
            // hold at least one modifier so the shortcut won't collide with typing.
            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            Defaults.screenshotHotkeyKeyCode = Int(keyCode)
            Defaults.screenshotHotkeyModifiers = Int(carbonMods)
            self.finishShortcutRecording()
            return nil
        }
    }

    @objc private func shortcutRestoreClicked() {
        if shortcutRecordingMonitor != nil {
            cancelShortcutRecording()
        }
        Defaults.clearScreenshotHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshShortcutDisplay()
    }

    private func finishShortcutRecording() {
        if let m = shortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            shortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshShortcutDisplay()
    }

    func cancelShortcutRecording() {
        guard shortcutRecordingMonitor != nil else { return }
        if let m = shortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            shortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshShortcutDisplay()
    }

    private func refreshShortcutDisplay() {
        shortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentDisplayString() {
            shortcutField?.stringValue = display
            shortcutRestoreButton?.isHidden = false
        } else {
            shortcutField?.stringValue = L10n.shortcutDefaultDisplay
            shortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func updateLocalization() {
        menuBarTitleLabel?.stringValue = L10n.showMenuBarIcon
        launchAtLoginTitleLabel?.stringValue = L10n.launchAtLogin
        demoModeTitleLabel?.stringValue = L10n.demoMode
        demoModeSubtitleLabel?.stringValue = L10n.demoModeHint
        langTitleLabel?.stringValue = L10n.languageHeader
        accessibilityNameLabel?.stringValue = L10n.accessibilityPermission
        accessibilityDescLabel?.stringValue = L10n.accessibilityDescription
        screenRecordingNameLabel?.stringValue = L10n.screenRecordingPermission
        screenRecordingDescLabel?.stringValue = L10n.screenRecordingDescription
        historyCacheTitleLabel?.stringValue = L10n.historyCacheLabel
        historyCacheHintLabel?.stringValue = L10n.historyCacheHint
        countdownTitleLabel?.stringValue = L10n.countdownLabel
        countdownHintLabel?.stringValue = L10n.countdownHint
        countdownValueLabel?.stringValue = "\(Defaults.countdownSeconds)\(L10n.countdownSecondsSuffix)"
        shortcutTitleLabel?.stringValue = L10n.shortcutHeader
        shortcutHintLabel?.stringValue = L10n.shortcutHint
        shortcutRestoreButton?.toolTip = L10n.shortcutRestore
        aboutTaglineLabel?.stringValue = L10n.aboutTagline
        aboutLicenseTitleLabel?.stringValue = L10n.aboutLicense
        aboutSourceTitleLabel?.stringValue = L10n.aboutSourceCode
        aboutUpdateTitleLabel?.stringValue = L10n.aboutUpdateTitle
        refreshUpdateRow()
        refreshShortcutDisplay()
        refreshBottomAction()
        accessibilityBadge?.refreshTitle()
        screenRecordingBadge?.refreshTitle()
        for btn in tabButtons { btn.refreshTitle() }
        detailTitleLabel?.stringValue = selectedTab.title
        window?.title = L10n.settingsTitle
    }
}

// MARK: - Flipped view (top-aligned scroll content)

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Sidebar / detail panels

private final class SidebarPanel: NSView {
    private var gradientLayer: CAGradientLayer?

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
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1

        let g = CAGradientLayer()
        g.colors = [
            NSColor(calibratedRed: 0.11, green: 0.17, blue: 0.25, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1.0).cgColor,
        ]
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        g.cornerRadius = 22
        layer?.insertSublayer(g, at: 0)
        gradientLayer = g
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
    }
}

private final class DetailPanel: NSView {
    private var gradientLayer: CAGradientLayer?

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
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1

        let g = CAGradientLayer()
        g.colors = [
            NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0).cgColor,
        ]
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        g.cornerRadius = 24
        layer?.insertSublayer(g, at: 0)
        gradientLayer = g
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
    }
}

// MARK: - Sidebar tab button

private final class TabButton: NSControl {
    let tab: SettingsTab
    private let iconChip = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    var isSelected: Bool = false {
        didSet { applyAppearance() }
    }

    init(tab: SettingsTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        iconChip.translatesAutoresizingMaskIntoConstraints = false
        iconChip.wantsLayer = true
        iconChip.layer?.cornerRadius = 8
        iconChip.layer?.cornerCurve = .continuous
        iconChip.layer?.borderWidth = 1
        addSubview(iconChip)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: tab.iconName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconChip.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.stringValue = tab.title
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),

            iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconChip.widthAnchor.constraint(equalToConstant: 28),
            iconChip.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconChip.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshTitle() {
        label.stringValue = tab.title
    }

    private func applyAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.85, alpha: 1.0).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            layer?.borderWidth = 1
            label.textColor = .white
            iconChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            iconChip.layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
            iconView.contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            label.textColor = NSColor.white.withAlphaComponent(0.82)
            iconChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            iconChip.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            iconView.contentTintColor = tab.iconTint
        }
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
        if !isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Action button (sidebar bottom row, mirrors TabButton's chrome)

private final class ActionButton: NSControl {
    private let iconChip = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var tint: NSColor = .systemGreen

    init(symbolName: String, title: String, tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        iconChip.translatesAutoresizingMaskIntoConstraints = false
        iconChip.wantsLayer = true
        iconChip.layer?.cornerRadius = 8
        iconChip.layer?.cornerCurve = .continuous
        iconChip.layer?.borderWidth = 1
        addSubview(iconChip)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconChip.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),

            iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconChip.widthAnchor.constraint(equalToConstant: 28),
            iconChip.heightAnchor.constraint(equalToConstant: 28),

            iconView.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconChip.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        update(symbolName: symbolName, title: title, tint: tint)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(symbolName: String, title: String, tint: NSColor) {
        self.tint = tint
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        label.stringValue = title
        applyAppearance()
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.45 }
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        // Match unselected TabButton's chip — the tint flows into the
        // icon glyph and the label so the whole row reads as a single color.
        iconChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        iconChip.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        iconView.contentTintColor = tint
        label.textColor = tint
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
        guard isEnabled else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        sendAction(action, to: target)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEnabled, event.charactersIgnoringModifiers == "\r" {
            sendAction(action, to: target)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
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
