import AppKit
import Carbon
import PermissionFlow

// MARK: - Tab model

enum SettingsTab: CaseIterable {
    case general
    case shortcuts
    case toolbar
    case upload
    case translation
    case permissions
    case about

    var title: String {
        switch self {
        case .general: return L10n.settingsTabGeneral
        case .shortcuts: return L10n.settingsTabShortcuts
        case .toolbar: return L10n.settingsTabToolbar
        case .upload: return L10n.settingsTabUpload
        case .translation: return L10n.settingsTabTranslation
        case .permissions: return L10n.settingsTabPermissions
        case .about: return L10n.settingsTabAbout
        }
    }

    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "keyboard"
        case .toolbar: return "slider.horizontal.3"
        case .upload: return "icloud.and.arrow.up.fill"
        case .translation: return "character.bubble.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var iconTint: NSColor {
        switch self {
        case .general: return NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.72, alpha: 1.0)
        case .shortcuts: return NSColor(calibratedRed: 0.36, green: 0.66, blue: 0.98, alpha: 1.0)
        case .toolbar: return NSColor(calibratedRed: 0.95, green: 0.54, blue: 0.62, alpha: 1.0)
        case .upload: return NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1.0)
        case .translation: return NSColor(calibratedRed: 0.38, green: 0.80, blue: 0.78, alpha: 1.0)
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
    private var pinAcrossSpacesSwitch: NSSwitch!

    // Picker & slider
    private var langPicker: NSPopUpButton!
    private var historyCacheSwitch: NSSwitch!
    private var historyCacheSlider: SettingsTickSlider!
    private var historyCacheValueLabel: NSTextField!
    private var countdownSlider: SettingsTickSlider!
    private var countdownValueLabel: NSTextField!
    private var countdownTitleLabel: NSTextField!
    private var countdownHintLabel: NSTextField!

    // Window-capture shadow card
    private var windowShadowSwitch: NSSwitch!
    private var windowShadowSlider: NSSlider!
    private var windowShadowSizeValueLabel: NSTextField!
    private var windowShadowPreview: ShadowPreviewView!
    private var windowShadowTitleLabel: NSTextField!
    private var windowShadowSubtitleLabel: NSTextField?
    private var windowShadowSizeTitleLabel: NSTextField!
    private var windowShadowSizeHintLabel: NSTextField!

    // Screenshot shortcut card
    private var shortcutTitleLabel: NSTextField!
    private var shortcutField: NSTextField!
    private var shortcutSetButton: NSButton!
    private var shortcutRestoreButton: NSButton!
    private var shortcutRecordingMonitor: Any?

    // Full-screen screenshot shortcut card
    private var fullScreenScreenshotShortcutTitleLabel: NSTextField!
    private var fullScreenScreenshotShortcutField: NSTextField!
    private var fullScreenScreenshotShortcutSetButton: NSButton!
    private var fullScreenScreenshotShortcutRestoreButton: NSButton!
    private var fullScreenScreenshotShortcutRecordingMonitor: Any?

    // Color picker shortcut card
    private var colorPickerShortcutTitleLabel: NSTextField!
    private var colorPickerShortcutField: NSTextField!
    private var colorPickerShortcutSetButton: NSButton!
    private var colorPickerShortcutRestoreButton: NSButton!
    private var colorPickerShortcutRecordingMonitor: Any?

    // Pin selected image shortcut card
    private var selectedImagePinShortcutTitleLabel: NSTextField!
    private var selectedImagePinShortcutField: NSTextField!
    private var selectedImagePinShortcutSetButton: NSButton!
    private var selectedImagePinShortcutRestoreButton: NSButton!
    private var selectedImagePinShortcutRecordingMonitor: Any?

    // Pin clipboard image shortcut card
    private var clipboardImagePinShortcutTitleLabel: NSTextField!
    private var clipboardImagePinShortcutField: NSTextField!
    private var clipboardImagePinShortcutSetButton: NSButton!
    private var clipboardImagePinShortcutRestoreButton: NSButton!
    private var clipboardImagePinShortcutRecordingMonitor: Any?

    // Edit selected image shortcut card
    private var selectedImageEditShortcutTitleLabel: NSTextField!
    private var selectedImageEditShortcutField: NSTextField!
    private var selectedImageEditShortcutSetButton: NSButton!
    private var selectedImageEditShortcutRestoreButton: NSButton!
    private var selectedImageEditShortcutRecordingMonitor: Any?

    // Edit clipboard image shortcut card
    private var clipboardImageEditShortcutTitleLabel: NSTextField!
    private var clipboardImageEditShortcutField: NSTextField!
    private var clipboardImageEditShortcutSetButton: NSButton!
    private var clipboardImageEditShortcutRestoreButton: NSButton!
    private var clipboardImageEditShortcutRecordingMonitor: Any?

    // Text recognition shortcut card
    private var textRecognitionShortcutTitleLabel: NSTextField!
    private var textRecognitionShortcutField: NSTextField!
    private var textRecognitionShortcutSetButton: NSButton!
    private var textRecognitionShortcutRestoreButton: NSButton!
    private var textRecognitionShortcutRecordingMonitor: Any?

    // Copy image text shortcut card
    private var copyImageTextShortcutTitleLabel: NSTextField!
    private var copyImageTextShortcutField: NSTextField!
    private var copyImageTextShortcutSetButton: NSButton!
    private var copyImageTextShortcutRestoreButton: NSButton!
    private var copyImageTextShortcutRecordingMonitor: Any?

    // Screenshot translation shortcut card
    private var screenshotTranslationShortcutTitleLabel: NSTextField!
    private var screenshotTranslationShortcutField: NSTextField!
    private var screenshotTranslationShortcutSetButton: NSButton!
    private var screenshotTranslationShortcutRestoreButton: NSButton!
    private var screenshotTranslationShortcutRecordingMonitor: Any?

    // Recording shortcut card
    private var recordShortcutTitleLabel: NSTextField!
    private var recordShortcutField: NSTextField!
    private var recordShortcutSetButton: NSButton!
    private var recordShortcutRestoreButton: NSButton!
    private var recordShortcutRecordingMonitor: Any?

    // Image Merge shortcut card
    private var imageMergeShortcutTitleLabel: NSTextField!
    private var imageMergeShortcutField: NSTextField!
    private var imageMergeShortcutSetButton: NSButton!
    private var imageMergeShortcutRestoreButton: NSButton!
    private var imageMergeShortcutRecordingMonitor: Any?

    // Copy-to-clipboard (editor confirm) shortcut card
    private var clipboardShortcutTitleLabel: NSTextField!
    private var clipboardShortcutField: NSTextField!
    private var clipboardShortcutSetButton: NSButton!
    private var clipboardShortcutRestoreButton: NSButton!
    private var clipboardShortcutRecordingMonitor: Any?

    // Save-to-file shortcut card (default ⌘S)
    private var fileSaveShortcutTitleLabel: NSTextField!
    private var fileSaveShortcutField: NSTextField!
    private var fileSaveShortcutSetButton: NSButton!
    private var fileSaveShortcutRestoreButton: NSButton!
    private var fileSaveShortcutRecordingMonitor: Any?

    // History navigation shortcut cards
    private var previousHistoryImageShortcutTitleLabel: NSTextField!
    private var previousHistoryImageShortcutField: NSTextField!
    private var previousHistoryImageShortcutSetButton: NSButton!
    private var previousHistoryImageShortcutRestoreButton: NSButton!
    private var previousHistoryImageShortcutRecordingMonitor: Any?

    private var nextHistoryImageShortcutTitleLabel: NSTextField!
    private var nextHistoryImageShortcutField: NSTextField!
    private var nextHistoryImageShortcutSetButton: NSButton!
    private var nextHistoryImageShortcutRestoreButton: NSButton!
    private var nextHistoryImageShortcutRecordingMonitor: Any?

    private var shortcutResetButton: NSButton?

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
    private var pinAcrossSpacesTitleLabel: NSTextField!
    private var pinAcrossSpacesSubtitleLabel: NSTextField!
    private var langTitleLabel: NSTextField!
    private var historyCacheToggleTitleLabel: NSTextField!
    private var historyCacheToggleHintLabel: NSTextField?
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
    private var aboutStarTitleLabel: NSTextField?
    private var aboutFeatureRequestTitleLabel: NSTextField?
    private var aboutBugReportTitleLabel: NSTextField?
    private var aboutUpdateTitleLabel: NSTextField?
    private var aboutUpdateStatusLabel: NSTextField?
    private var aboutUpdateButton: NSButton?

    // Error log card (About pane) — expandable diagnostic log viewer.
    private var errorLogTitleLabel: NSTextField?
    private var errorLogStatusLabel: NSTextField?
    private var errorLogChevron: NSImageView?
    private var errorLogContentContainer: NSView?
    private var errorLogHeightConstraint: NSLayoutConstraint?
    private var errorLogTextView: NSTextView?
    private var errorLogCopyButton: NSButton?
    private var errorLogRevealButton: NSButton?
    private var errorLogRefreshButton: NSButton?
    private var errorLogClearButton: NSButton?
    private var errorLogEntry: CrashLogReader.Entry?
    private var errorLogExpanded = false
    private var errorLogLoaded = false

    // Sidebar / detail chrome
    private var selectedTab: SettingsTab = .general
    private var tabButtons: [TabButton] = []
    private var detailTitleLabel: NSTextField!
    private var detailScrollView: NSScrollView!
    private var paneContainer: NSView!
    private var paneViews: [SettingsTab: NSView] = [:]
    private var uploadPane: UploadSettingsPane?
    private var filenameRuleCard: FilenameRuleCard?
    private var savePathTitleLabel: NSTextField!
    private var savePathSubtitleLabel: NSTextField!
    private var autoRevealSavedFilesTitleLabel: NSTextField!
    private var autoRevealSavedFilesHintLabel: NSTextField?
    private var autoRevealSavedFilesSwitch: NSSwitch!
    private var recordingSavePathTitleLabel: NSTextField!
    private var recordingSavePathValueLabel: NSTextField!
    private var recordingSavePathChooseButton: NSButton!
    private var recordingSavePathRevealButton: NSButton!
    private var recordingSaveFormatTitleLabel: NSTextField!
    private var recordingSaveFormatPopup: NSPopUpButton!
    private var screenshotSavePathTitleLabel: NSTextField!
    private var screenshotSavePathValueLabel: NSTextField!
    private var screenshotSavePathChooseButton: NSButton!
    private var screenshotSavePathRevealButton: NSButton!

    private var refreshTimer: Timer?
    private var gradientLayer: CAGradientLayer?
    private lazy var permissionFlowController = PermissionFlow.makeController(
        configuration: PermissionFlowConfiguration(
            requiredAppURLs: [Bundle.main.bundleURL],
            localeIdentifier: Defaults.language.lprojName
        )
    )

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
        cancelFullScreenScreenshotShortcutRecording()
        cancelColorPickerShortcutRecording()
        cancelSelectedImagePinShortcutRecording()
        cancelClipboardImagePinShortcutRecording()
        cancelSelectedImageEditShortcutRecording()
        cancelClipboardImageEditShortcutRecording()
        cancelTextRecognitionShortcutRecording()
        cancelCopyImageTextShortcutRecording()
        cancelScreenshotTranslationShortcutRecording()
        cancelRecordShortcutRecording()
        cancelImageMergeShortcutRecording()
        cancelClipboardShortcutRecording()
        cancelFileSaveShortcutRecording()
        cancelPreviousHistoryImageShortcutRecording()
        cancelNextHistoryImageShortcutRecording()
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

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
        paneViews[.toolbar] = buildToolbarPane()
        paneViews[.upload] = buildUploadPane()
        paneViews[.translation] = buildTranslationPane()
        paneViews[.permissions] = buildPermissionsPane()
        paneViews[.about] = buildAboutPane()

        // Default selection
        let initial: SettingsTab = isStartup ? .permissions : .general
        selectTab(initial)

        updateLaunchButtonVisibility()
        refreshPermissionStatus()
        refreshShortcutDisplay()
        refreshFullScreenScreenshotShortcutDisplay()
        refreshColorPickerShortcutDisplay()
        refreshSelectedImagePinShortcutDisplay()
        refreshClipboardImagePinShortcutDisplay()
        refreshSelectedImageEditShortcutDisplay()
        refreshClipboardImageEditShortcutDisplay()
        refreshTextRecognitionShortcutDisplay()
        refreshCopyImageTextShortcutDisplay()
        refreshScreenshotTranslationShortcutDisplay()
        refreshRecordShortcutDisplay()
        refreshImageMergeShortcutDisplay()
        refreshClipboardShortcutDisplay()
        refreshFileSaveShortcutDisplay()
        refreshPreviousHistoryImageShortcutDisplay()
        refreshNextHistoryImageShortcutDisplay()
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
        langPicker.addItems(withTitles: AppLanguage.allCases.map { $0.displayName })
        langPicker.selectItem(at: AppLanguage.allCases.firstIndex(of: Defaults.language) ?? 0)
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
        togglesInner.addArrangedSubview(rowDivider())

        let pinAcrossSpaces = makeToggleRow(
            title: L10n.pinAcrossSpaces,
            subtitle: L10n.pinAcrossSpacesHint,
            isOn: Defaults.pinAcrossSpaces,
            action: #selector(pinAcrossSpacesToggled(_:))
        )
        pinAcrossSpacesTitleLabel = pinAcrossSpaces.title
        pinAcrossSpacesSubtitleLabel = pinAcrossSpaces.subtitle
        pinAcrossSpacesSwitch = pinAcrossSpaces.toggle
        togglesInner.addArrangedSubview(pinAcrossSpaces.row)
        pinAcrossSpaces.row.widthAnchor.constraint(equalTo: togglesInner.widthAnchor).isActive = true

        stack.addArrangedSubview(togglesCard)
        togglesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        buildWindowShadowCard(into: stack)

        buildHistoryAndCountdownCards(into: stack)

        let filenameCard = FilenameRuleCard()
        filenameRuleCard = filenameCard
        stack.addArrangedSubview(filenameCard)
        filenameCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        buildSavePathCard(into: stack)

        return wrapPane(stack)
    }

    /// Window-capture shadow card: a toggle for the rounded-corner + drop
    /// shadow effect, a size slider, and a live preview of the result.
    private func buildWindowShadowCard(into stack: NSStackView) {
        let card = CardView()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        pin(inner, to: card, insets: NSEdgeInsets(top: 4, left: 14, bottom: 14, right: 14))

        // Enable toggle
        let toggle = makeToggleRow(
            title: L10n.windowShadowToggleLabel,
            subtitle: L10n.windowShadowToggleHint,
            isOn: Defaults.windowShadowEnabled,
            action: #selector(windowShadowToggled(_:))
        )
        windowShadowTitleLabel = toggle.title
        windowShadowSubtitleLabel = toggle.subtitle
        windowShadowSwitch = toggle.toggle
        inner.addArrangedSubview(toggle.row)
        toggle.row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let divider = rowDivider()
        inner.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        // Size header — title + numeric value
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        windowShadowSizeTitleLabel = primaryLabel(L10n.windowShadowSizeLabel)
        header.addArrangedSubview(windowShadowSizeTitleLabel)
        header.addArrangedSubview(flexSpacer())

        windowShadowSizeValueLabel = NSTextField(labelWithString: "\(Int(Defaults.windowShadowSize.rounded()))")
        windowShadowSizeValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        windowShadowSizeValueLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        header.addArrangedSubview(windowShadowSizeValueLabel)

        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        // Size slider
        let slider = NSSlider(
            value: Defaults.windowShadowSize,
            minValue: Defaults.windowShadowSizeMin,
            maxValue: Defaults.windowShadowSizeMax,
            target: self,
            action: #selector(windowShadowSizeChanged(_:))
        )
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        windowShadowSlider = slider
        inner.addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        // Live preview
        let preview = ShadowPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.shadowSize = CGFloat(Defaults.windowShadowSize)
        windowShadowPreview = preview
        inner.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 120).isActive = true

        windowShadowSizeHintLabel = secondaryLabel(L10n.windowShadowSizeHint, wrapping: true)
        inner.addArrangedSubview(windowShadowSizeHintLabel)
        windowShadowSizeHintLabel.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        updateWindowShadowControlsEnabled()

        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Dim and disable the size controls when the shadow toggle is off.
    private func updateWindowShadowControlsEnabled() {
        let on = Defaults.windowShadowEnabled
        windowShadowSlider?.isEnabled = on
        windowShadowSizeTitleLabel?.textColor = NSColor.white.withAlphaComponent(on ? 0.94 : 0.4)
        windowShadowSizeValueLabel?.textColor = NSColor.white.withAlphaComponent(on ? 0.88 : 0.4)
        windowShadowPreview?.isEffectEnabled = on
    }

    private func updateHistoryCacheControlsEnabled() {
        let on = Defaults.historyCacheEnabled
        historyCacheSlider?.isEnabled = on
        historyCacheTitleLabel?.textColor = NSColor.white.withAlphaComponent(on ? 0.94 : 0.4)
        historyCacheValueLabel?.textColor = NSColor.white.withAlphaComponent(on ? 0.88 : 0.4)
        historyCacheHintLabel?.textColor = NSColor.white.withAlphaComponent(on ? 0.58 : 0.35)
    }

    private func refreshSavePathControls() {
        recordingSavePathValueLabel?.stringValue = SaveDestination.displayPath(Defaults.recordingSaveDirectory)
        screenshotSavePathValueLabel?.stringValue = SaveDestination.displayPath(Defaults.screenshotSaveDirectory)
        refreshRecordingSaveFormatPopup()
    }

    private func refreshRecordingSaveFormatPopup() {
        guard let popup = recordingSaveFormatPopup else { return }
        let selected = Defaults.recordingSavePreference
        popup.removeAllItems()
        for preference in RecordingSavePreference.allCases {
            popup.addItem(withTitle: preference.displayName)
            popup.lastItem?.representedObject = preference.rawValue
        }
        if let index = RecordingSavePreference.allCases.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
    }

    private func buildShortcutsPane() -> NSView {
        let stack = paneStack()

        // Screenshot shortcut card
        let shortcut = buildShortcutCard(
            title: L10n.shortcutHeader,
            setAction: #selector(shortcutSetClicked),
            restoreAction: #selector(shortcutRestoreClicked)
        )
        shortcutTitleLabel = shortcut.title
        shortcutField = shortcut.field
        shortcutSetButton = shortcut.setButton
        shortcutRestoreButton = shortcut.restoreButton
        stack.addArrangedSubview(shortcut.card)
        shortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Copy-to-clipboard (editor confirm) shortcut card
        let clipboardShortcut = buildShortcutCard(
            title: L10n.clipboardShortcutHeader,
            setAction: #selector(clipboardShortcutSetClicked),
            restoreAction: #selector(clipboardShortcutRestoreClicked)
        )
        clipboardShortcutTitleLabel = clipboardShortcut.title
        clipboardShortcutField = clipboardShortcut.field
        clipboardShortcutSetButton = clipboardShortcut.setButton
        clipboardShortcutRestoreButton = clipboardShortcut.restoreButton
        stack.addArrangedSubview(clipboardShortcut.card)
        clipboardShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Save-to-file shortcut card (default ⌘S)
        let fileSaveShortcut = buildShortcutCard(
            title: L10n.fileSaveShortcutHeader,
            setAction: #selector(fileSaveShortcutSetClicked),
            restoreAction: #selector(fileSaveShortcutRestoreClicked)
        )
        fileSaveShortcutTitleLabel = fileSaveShortcut.title
        fileSaveShortcutField = fileSaveShortcut.field
        fileSaveShortcutSetButton = fileSaveShortcut.setButton
        fileSaveShortcutRestoreButton = fileSaveShortcut.restoreButton
        stack.addArrangedSubview(fileSaveShortcut.card)
        fileSaveShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let previousHistoryImageShortcut = buildShortcutCard(
            title: L10n.previousHistoryImageShortcutHeader,
            setAction: #selector(previousHistoryImageShortcutSetClicked),
            restoreAction: #selector(previousHistoryImageShortcutRestoreClicked)
        )
        previousHistoryImageShortcutTitleLabel = previousHistoryImageShortcut.title
        previousHistoryImageShortcutField = previousHistoryImageShortcut.field
        previousHistoryImageShortcutSetButton = previousHistoryImageShortcut.setButton
        previousHistoryImageShortcutRestoreButton = previousHistoryImageShortcut.restoreButton
        stack.addArrangedSubview(previousHistoryImageShortcut.card)
        previousHistoryImageShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let nextHistoryImageShortcut = buildShortcutCard(
            title: L10n.nextHistoryImageShortcutHeader,
            setAction: #selector(nextHistoryImageShortcutSetClicked),
            restoreAction: #selector(nextHistoryImageShortcutRestoreClicked)
        )
        nextHistoryImageShortcutTitleLabel = nextHistoryImageShortcut.title
        nextHistoryImageShortcutField = nextHistoryImageShortcut.field
        nextHistoryImageShortcutSetButton = nextHistoryImageShortcut.setButton
        nextHistoryImageShortcutRestoreButton = nextHistoryImageShortcut.restoreButton
        stack.addArrangedSubview(nextHistoryImageShortcut.card)
        nextHistoryImageShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Full-screen screenshot shortcut card
        let fullScreenScreenshotShortcut = buildShortcutCard(
            title: L10n.fullScreenScreenshotShortcutHeader,
            setAction: #selector(fullScreenScreenshotShortcutSetClicked),
            restoreAction: #selector(fullScreenScreenshotShortcutRestoreClicked)
        )
        fullScreenScreenshotShortcutTitleLabel = fullScreenScreenshotShortcut.title
        fullScreenScreenshotShortcutField = fullScreenScreenshotShortcut.field
        fullScreenScreenshotShortcutSetButton = fullScreenScreenshotShortcut.setButton
        fullScreenScreenshotShortcutRestoreButton = fullScreenScreenshotShortcut.restoreButton
        stack.addArrangedSubview(fullScreenScreenshotShortcut.card)
        fullScreenScreenshotShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Color picker shortcut card
        let colorPickerShortcut = buildShortcutCard(
            title: L10n.colorPickerShortcutHeader,
            setAction: #selector(colorPickerShortcutSetClicked),
            restoreAction: #selector(colorPickerShortcutRestoreClicked)
        )
        colorPickerShortcutTitleLabel = colorPickerShortcut.title
        colorPickerShortcutField = colorPickerShortcut.field
        colorPickerShortcutSetButton = colorPickerShortcut.setButton
        colorPickerShortcutRestoreButton = colorPickerShortcut.restoreButton
        stack.addArrangedSubview(colorPickerShortcut.card)
        colorPickerShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Edit selected image shortcut card
        let selectedImageEditShortcut = buildShortcutCard(
            title: L10n.selectedImageEditShortcutHeader,
            setAction: #selector(selectedImageEditShortcutSetClicked),
            restoreAction: #selector(selectedImageEditShortcutRestoreClicked)
        )
        selectedImageEditShortcutTitleLabel = selectedImageEditShortcut.title
        selectedImageEditShortcutField = selectedImageEditShortcut.field
        selectedImageEditShortcutSetButton = selectedImageEditShortcut.setButton
        selectedImageEditShortcutRestoreButton = selectedImageEditShortcut.restoreButton
        stack.addArrangedSubview(selectedImageEditShortcut.card)
        selectedImageEditShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Edit clipboard image shortcut card
        let clipboardImageEditShortcut = buildShortcutCard(
            title: L10n.clipboardImageEditShortcutHeader,
            setAction: #selector(clipboardImageEditShortcutSetClicked),
            restoreAction: #selector(clipboardImageEditShortcutRestoreClicked)
        )
        clipboardImageEditShortcutTitleLabel = clipboardImageEditShortcut.title
        clipboardImageEditShortcutField = clipboardImageEditShortcut.field
        clipboardImageEditShortcutSetButton = clipboardImageEditShortcut.setButton
        clipboardImageEditShortcutRestoreButton = clipboardImageEditShortcut.restoreButton
        stack.addArrangedSubview(clipboardImageEditShortcut.card)
        clipboardImageEditShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Pin selected image shortcut card
        let selectedImagePinShortcut = buildShortcutCard(
            title: L10n.selectedImagePinShortcutHeader,
            setAction: #selector(selectedImagePinShortcutSetClicked),
            restoreAction: #selector(selectedImagePinShortcutRestoreClicked)
        )
        selectedImagePinShortcutTitleLabel = selectedImagePinShortcut.title
        selectedImagePinShortcutField = selectedImagePinShortcut.field
        selectedImagePinShortcutSetButton = selectedImagePinShortcut.setButton
        selectedImagePinShortcutRestoreButton = selectedImagePinShortcut.restoreButton
        selectedImagePinShortcutRestoreButton.toolTip = L10n.selectedImagePinShortcutClear
        stack.addArrangedSubview(selectedImagePinShortcut.card)
        selectedImagePinShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Pin clipboard image shortcut card
        let clipboardImagePinShortcut = buildShortcutCard(
            title: L10n.clipboardImagePinShortcutHeader,
            setAction: #selector(clipboardImagePinShortcutSetClicked),
            restoreAction: #selector(clipboardImagePinShortcutRestoreClicked)
        )
        clipboardImagePinShortcutTitleLabel = clipboardImagePinShortcut.title
        clipboardImagePinShortcutField = clipboardImagePinShortcut.field
        clipboardImagePinShortcutSetButton = clipboardImagePinShortcut.setButton
        clipboardImagePinShortcutRestoreButton = clipboardImagePinShortcut.restoreButton
        clipboardImagePinShortcutRestoreButton.toolTip = L10n.clipboardImagePinShortcutClear
        stack.addArrangedSubview(clipboardImagePinShortcut.card)
        clipboardImagePinShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Text recognition shortcut card
        let textRecognitionShortcut = buildShortcutCard(
            title: L10n.textRecognitionShortcutHeader,
            setAction: #selector(textRecognitionShortcutSetClicked),
            restoreAction: #selector(textRecognitionShortcutRestoreClicked)
        )
        textRecognitionShortcutTitleLabel = textRecognitionShortcut.title
        textRecognitionShortcutField = textRecognitionShortcut.field
        textRecognitionShortcutSetButton = textRecognitionShortcut.setButton
        textRecognitionShortcutRestoreButton = textRecognitionShortcut.restoreButton
        stack.addArrangedSubview(textRecognitionShortcut.card)
        textRecognitionShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Copy image text shortcut card
        let copyImageTextShortcut = buildShortcutCard(
            title: L10n.copyImageTextShortcutHeader,
            setAction: #selector(copyImageTextShortcutSetClicked),
            restoreAction: #selector(copyImageTextShortcutRestoreClicked)
        )
        copyImageTextShortcutTitleLabel = copyImageTextShortcut.title
        copyImageTextShortcutField = copyImageTextShortcut.field
        copyImageTextShortcutSetButton = copyImageTextShortcut.setButton
        copyImageTextShortcutRestoreButton = copyImageTextShortcut.restoreButton
        stack.addArrangedSubview(copyImageTextShortcut.card)
        copyImageTextShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Screenshot translation shortcut card
        let screenshotTranslationShortcut = buildShortcutCard(
            title: L10n.screenshotTranslationShortcutHeader,
            setAction: #selector(screenshotTranslationShortcutSetClicked),
            restoreAction: #selector(screenshotTranslationShortcutRestoreClicked)
        )
        screenshotTranslationShortcutTitleLabel = screenshotTranslationShortcut.title
        screenshotTranslationShortcutField = screenshotTranslationShortcut.field
        screenshotTranslationShortcutSetButton = screenshotTranslationShortcut.setButton
        screenshotTranslationShortcutRestoreButton = screenshotTranslationShortcut.restoreButton
        stack.addArrangedSubview(screenshotTranslationShortcut.card)
        screenshotTranslationShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Recording shortcut card
        let recordShortcut = buildShortcutCard(
            title: L10n.recordShortcutHeader,
            setAction: #selector(recordShortcutSetClicked),
            restoreAction: #selector(recordShortcutRestoreClicked)
        )
        recordShortcutTitleLabel = recordShortcut.title
        recordShortcutField = recordShortcut.field
        recordShortcutSetButton = recordShortcut.setButton
        recordShortcutRestoreButton = recordShortcut.restoreButton
        stack.addArrangedSubview(recordShortcut.card)
        recordShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Image Merge shortcut card
        let imageMergeShortcut = buildShortcutCard(
            title: L10n.imageMergeShortcutHeader,
            setAction: #selector(imageMergeShortcutSetClicked),
            restoreAction: #selector(imageMergeShortcutRestoreClicked)
        )
        imageMergeShortcutTitleLabel = imageMergeShortcut.title
        imageMergeShortcutField = imageMergeShortcut.field
        imageMergeShortcutSetButton = imageMergeShortcut.setButton
        imageMergeShortcutRestoreButton = imageMergeShortcut.restoreButton
        stack.addArrangedSubview(imageMergeShortcut.card)
        imageMergeShortcut.card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: L10n.toolbarSettingsReset,
                                   target: self,
                                   action: #selector(shortcutsResetClicked))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .large
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        shortcutResetButton = resetButton

        footer.addArrangedSubview(flexSpacer())
        footer.addArrangedSubview(resetButton)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return wrapPane(stack)
    }

    private func buildHistoryAndCountdownCards(into stack: NSStackView) {
        // History cache card
        let historyCard = CardView()
        let historyInner = NSStackView()
        historyInner.orientation = .vertical
        historyInner.alignment = .leading
        historyInner.spacing = 10
        historyInner.translatesAutoresizingMaskIntoConstraints = false
        historyCard.addSubview(historyInner)
        pin(historyInner, to: historyCard, insets: NSEdgeInsets(top: 4, left: 14, bottom: 14, right: 14))

        let historyToggle = makeToggleRow(
            title: L10n.historyCacheToggleLabel,
            subtitle: L10n.historyCacheToggleHint,
            isOn: Defaults.historyCacheEnabled,
            action: #selector(historyCacheToggled(_:))
        )
        historyCacheToggleTitleLabel = historyToggle.title
        historyCacheToggleHintLabel = historyToggle.subtitle
        historyCacheSwitch = historyToggle.toggle
        historyInner.addArrangedSubview(historyToggle.row)
        historyToggle.row.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

        let historyDivider = rowDivider()
        historyInner.addArrangedSubview(historyDivider)
        historyDivider.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

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

        let slider = SettingsTickSlider(
            value: Double(Defaults.historyCacheLimit),
            minValue: Double(Defaults.historyCacheMin),
            maxValue: Double(Defaults.historyCacheMax),
            stepValue: Double(Defaults.historyCacheStep),
            numberOfTickMarks: (Defaults.historyCacheMax - Defaults.historyCacheMin) / Defaults.historyCacheStep + 1,
            target: self,
            action: #selector(historyCacheSliderChanged(_:))
        )
        slider.translatesAutoresizingMaskIntoConstraints = false
        historyCacheSlider = slider
        historyInner.addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

        historyCacheHintLabel = secondaryLabel(L10n.historyCacheHint, wrapping: true)
        historyInner.addArrangedSubview(historyCacheHintLabel)
        historyCacheHintLabel.widthAnchor.constraint(equalTo: historyInner.widthAnchor).isActive = true

        updateHistoryCacheControlsEnabled()

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

        let cdSlider = SettingsTickSlider(
            value: Double(Defaults.countdownSeconds),
            minValue: Double(Defaults.countdownSecondsMin),
            maxValue: Double(Defaults.countdownSecondsMax),
            stepValue: 1,
            numberOfTickMarks: Defaults.countdownSecondsMax - Defaults.countdownSecondsMin + 1,
            target: self,
            action: #selector(countdownSliderChanged(_:))
        )
        cdSlider.translatesAutoresizingMaskIntoConstraints = false
        countdownSlider = cdSlider
        countdownInner.addArrangedSubview(cdSlider)
        cdSlider.widthAnchor.constraint(equalTo: countdownInner.widthAnchor).isActive = true

        countdownHintLabel = secondaryLabel(L10n.countdownHint, wrapping: true)
        countdownInner.addArrangedSubview(countdownHintLabel)
        countdownHintLabel.widthAnchor.constraint(equalTo: countdownInner.widthAnchor).isActive = true

        stack.addArrangedSubview(countdownCard)
        countdownCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func buildSavePathCard(into stack: NSStackView) {
        let card = CardView()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        pin(inner, to: card, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false

        savePathTitleLabel = primaryLabel(L10n.savePathTitle)
        savePathSubtitleLabel = secondaryLabel(L10n.savePathSubtitle, wrapping: true)
        header.addArrangedSubview(savePathTitleLabel)
        header.addArrangedSubview(savePathSubtitleLabel)
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        savePathSubtitleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let topDivider = rowDivider()
        inner.addArrangedSubview(topDivider)
        topDivider.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let autoReveal = makeToggleRow(
            title: L10n.autoRevealSavedFilesLabel,
            subtitle: L10n.autoRevealSavedFilesHint,
            isOn: Defaults.autoRevealSavedFiles,
            action: #selector(autoRevealSavedFilesToggled(_:))
        )
        autoRevealSavedFilesTitleLabel = autoReveal.title
        autoRevealSavedFilesHintLabel = autoReveal.subtitle
        autoRevealSavedFilesSwitch = autoReveal.toggle
        inner.addArrangedSubview(autoReveal.row)
        autoReveal.row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let autoRevealDivider = rowDivider()
        inner.addArrangedSubview(autoRevealDivider)
        autoRevealDivider.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let recordingPath = makeSavePathRow(
            title: L10n.recordingSavePathLabel,
            chooseAction: #selector(chooseRecordingSavePathClicked),
            revealAction: #selector(revealRecordingSavePathClicked)
        )
        recordingSavePathTitleLabel = recordingPath.title
        recordingSavePathValueLabel = recordingPath.value
        recordingSavePathChooseButton = recordingPath.chooseButton
        recordingSavePathRevealButton = recordingPath.revealButton
        inner.addArrangedSubview(recordingPath.row)
        recordingPath.row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let formatDivider = rowDivider()
        inner.addArrangedSubview(formatDivider)
        formatDivider.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let formatRow = NSStackView()
        formatRow.orientation = .horizontal
        formatRow.alignment = .centerY
        formatRow.spacing = 10
        formatRow.translatesAutoresizingMaskIntoConstraints = false

        recordingSaveFormatTitleLabel = primaryLabel(L10n.recordingSaveFormatSettingLabel)
        formatRow.addArrangedSubview(recordingSaveFormatTitleLabel)
        formatRow.addArrangedSubview(flexSpacer())

        recordingSaveFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        recordingSaveFormatPopup.controlSize = .small
        recordingSaveFormatPopup.font = NSFont.systemFont(ofSize: 12)
        recordingSaveFormatPopup.target = self
        recordingSaveFormatPopup.action = #selector(recordingSaveFormatPreferenceChanged(_:))
        recordingSaveFormatPopup.translatesAutoresizingMaskIntoConstraints = false
        recordingSaveFormatPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        formatRow.addArrangedSubview(recordingSaveFormatPopup)
        inner.addArrangedSubview(formatRow)
        formatRow.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let bottomDivider = rowDivider()
        inner.addArrangedSubview(bottomDivider)
        bottomDivider.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let screenshotPath = makeSavePathRow(
            title: L10n.screenshotSavePathLabel,
            chooseAction: #selector(chooseScreenshotSavePathClicked),
            revealAction: #selector(revealScreenshotSavePathClicked)
        )
        screenshotSavePathTitleLabel = screenshotPath.title
        screenshotSavePathValueLabel = screenshotPath.value
        screenshotSavePathChooseButton = screenshotPath.chooseButton
        screenshotSavePathRevealButton = screenshotPath.revealButton
        inner.addArrangedSubview(screenshotPath.row)
        screenshotPath.row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        refreshSavePathControls()

        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeSavePathRow(
        title: String,
        chooseAction: Selector,
        revealAction: Selector
    ) -> (row: NSView, title: NSTextField, value: NSTextField, chooseButton: NSButton, revealButton: NSButton) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = primaryLabel(title)
        let valueLabel = secondaryLabel("", wrapping: false)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(valueLabel)
        row.addArrangedSubview(labelStack)
        labelStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        row.addArrangedSubview(flexSpacer())

        let chooseButton = NSButton(title: L10n.savePathChoose, target: self, action: chooseAction)
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.font = NSFont.systemFont(ofSize: 11)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(chooseButton)

        let revealButton = NSButton(title: L10n.savePathReveal, target: self, action: revealAction)
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.font = NSFont.systemFont(ofSize: 11)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(revealButton)

        return (row, titleLabel, valueLabel, chooseButton, revealButton)
    }

    private func buildToolbarPane() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let pane = ToolbarSettingsPane()
        host.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: host.topAnchor),
            pane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
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

    private func buildTranslationPane() -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let pane = TranslationSettingsPane()
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
            action: #selector(openAccessibilitySettings(_:))
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
            action: #selector(openScreenRecordingSettings(_:))
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
        infoInner.addArrangedSubview(rowDivider())

        let star = makeLinkRow(
            title: L10n.aboutStarOnGitHub,
            value: "",
            action: #selector(openStarOnGitHub)
        )
        aboutStarTitleLabel = star.title
        infoInner.addArrangedSubview(star.row)
        star.row.widthAnchor.constraint(equalTo: infoInner.widthAnchor).isActive = true
        infoInner.addArrangedSubview(rowDivider())

        let featureRequest = makeLinkRow(
            title: L10n.aboutFeatureRequest,
            value: "",
            action: #selector(openFeatureRequest)
        )
        aboutFeatureRequestTitleLabel = featureRequest.title
        infoInner.addArrangedSubview(featureRequest.row)
        featureRequest.row.widthAnchor.constraint(equalTo: infoInner.widthAnchor).isActive = true
        infoInner.addArrangedSubview(rowDivider())

        let bugReport = makeLinkRow(
            title: L10n.aboutBugReport,
            value: "",
            action: #selector(openBugReport)
        )
        aboutBugReportTitleLabel = bugReport.title
        infoInner.addArrangedSubview(bugReport.row)
        bugReport.row.widthAnchor.constraint(equalTo: infoInner.widthAnchor).isActive = true

        stack.addArrangedSubview(infoCard)
        infoCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Error log card — collapsed by default, expands to show the most
        // recent diagnostic log so users can copy it into a bug report.
        let errorLogCard = buildErrorLogCard()
        stack.addArrangedSubview(errorLogCard)
        errorLogCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return wrapPane(stack)
    }

    /// Builds the expandable "Error Log" card for the About pane. The header is
    /// a clickable row; tapping it animates the crash-log viewer open or shut.
    private func buildErrorLogCard() -> NSView {
        let card = CardView()
        card.layer?.masksToBounds = true

        // Clickable header — toggles the expand / collapse animation.
        let header = HoverButton()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.target = self
        header.action = #selector(toggleErrorLog)
        header.title = ""
        header.isBordered = false
        header.cornerRadius = 0

        let titleLabel = primaryLabel(L10n.aboutErrorLog)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLogTitleLabel = titleLabel

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLogStatusLabel = statusLabel

        // The chevron lives inside a fixed-size Auto Layout container, while the
        // image view itself uses a static frame. This keeps Auto Layout from
        // resetting the image view's frame on each layout pass — which would
        // otherwise discard the pivot compensation `frameCenterRotation` needs
        // and make the chevron rotate around its corner instead of its center.
        let chevronBox = NSView()
        chevronBox.translatesAutoresizingMaskIntoConstraints = false
        chevronBox.setContentHuggingPriority(.required, for: .horizontal)

        let chevron = NSImageView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = NSColor.white.withAlphaComponent(0.32)
        chevron.imageScaling = .scaleProportionallyUpOrDown
        chevron.wantsLayer = true
        chevron.autoresizingMask = []
        chevronBox.addSubview(chevron)
        errorLogChevron = chevron

        header.addSubview(titleLabel)
        header.addSubview(statusLabel)
        header.addSubview(chevronBox)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 46),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chevronBox.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            chevronBox.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chevronBox.widthAnchor.constraint(equalToConstant: 12),
            chevronBox.heightAnchor.constraint(equalToConstant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: chevronBox.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
        ])

        // Expandable content — clipped to its animatable height.
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.alphaValue = 0
        errorLogContentContainer = content

        let divider = rowDivider()
        content.addSubview(divider)

        // Crash log — read-only, selectable, monospace.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.black.withAlphaComponent(0.22)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = NSColor.white.withAlphaComponent(0.82)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        errorLogTextView = textView

        // Action buttons.
        func makeLogButton(title: String, action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 12)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }

        let copyButton = makeLogButton(title: L10n.aboutErrorLogCopy, action: #selector(copyErrorLog))
        errorLogCopyButton = copyButton

        let revealButton = makeLogButton(title: L10n.aboutErrorLogReveal, action: #selector(revealErrorLog))
        errorLogRevealButton = revealButton

        let refreshButton = makeLogButton(title: L10n.aboutErrorLogRefresh, action: #selector(refreshErrorLog))
        errorLogRefreshButton = refreshButton

        let clearButton = makeLogButton(title: L10n.aboutErrorLogClear, action: #selector(clearErrorLog))
        errorLogClearButton = clearButton

        content.addSubview(scroll)
        content.addSubview(copyButton)
        content.addSubview(revealButton)
        content.addSubview(refreshButton)
        content.addSubview(clearButton)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.heightAnchor.constraint(equalToConstant: 220),

            copyButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            copyButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            revealButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            revealButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8),

            refreshButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: 8),

            clearButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            clearButton.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 8),
        ])

        let inner = verticalInnerStack()
        card.addSubview(inner)
        pin(inner, to: card, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
        inner.addArrangedSubview(header)
        inner.addArrangedSubview(content)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let heightConstraint = content.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        errorLogHeightConstraint = heightConstraint

        refreshErrorLogStatus()
        return card
    }

    /// Expands or collapses the crash-log viewer with a height animation.
    @objc private func toggleErrorLog() {
        errorLogExpanded.toggle()
        if errorLogExpanded { loadErrorLogIfNeeded() }

        guard let content = errorLogContentContainer,
              let heightConstraint = errorLogHeightConstraint else { return }

        // Measure the content's natural height with the clamp lifted.
        var target: CGFloat = 0
        if errorLogExpanded {
            heightConstraint.isActive = false
            content.layoutSubtreeIfNeeded()
            target = content.fittingSize.height
            heightConstraint.isActive = true
            heightConstraint.constant = 0
            content.layoutSubtreeIfNeeded()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            heightConstraint.animator().constant = target
            content.animator().alphaValue = errorLogExpanded ? 1 : 0
            errorLogChevron?.animator().frameCenterRotation = errorLogExpanded ? -90 : 0
            self.layoutSubtreeIfNeeded()
        }
    }

    /// Reads the latest diagnostic log into the text view on first expansion.
    private func loadErrorLogIfNeeded() {
        guard !errorLogLoaded else { return }
        renderErrorLogContent()
    }

    /// Re-scans log files and refreshes the visible error-log content.
    private func reloadErrorLogFromDisk() {
        refreshErrorLogStatus()
        renderErrorLogContent()
    }

    private func renderErrorLogContent() {
        errorLogLoaded = true
        if let entry = errorLogEntry {
            errorLogTextView?.string = CrashLogReader.readableText(at: entry.url)
            errorLogTextView?.textColor = NSColor.white.withAlphaComponent(0.82)
            errorLogCopyButton?.isEnabled = true
            errorLogRevealButton?.isEnabled = true
            errorLogClearButton?.isEnabled = true
        } else {
            errorLogTextView?.string = L10n.aboutErrorLogEmptyBody
            errorLogTextView?.textColor = NSColor.white.withAlphaComponent(0.55)
            errorLogCopyButton?.isEnabled = false
            errorLogRevealButton?.isEnabled = false
            errorLogClearButton?.isEnabled = false
        }
    }

    /// Syncs the header status label to whether a diagnostic log exists.
    private func refreshErrorLogStatus() {
        errorLogEntry = CrashLogReader.latestLogFile()
        guard let label = errorLogStatusLabel else { return }
        if let entry = errorLogEntry {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            label.stringValue = L10n.aboutErrorLogLastCrash(formatter.string(from: entry.date))
            label.textColor = NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.45, alpha: 1.0)
            errorLogCopyButton?.isEnabled = errorLogLoaded
            errorLogRevealButton?.isEnabled = errorLogLoaded
            errorLogClearButton?.isEnabled = true
        } else {
            label.stringValue = L10n.aboutErrorLogNoCrash
            label.textColor = NSColor.white.withAlphaComponent(0.55)
            errorLogCopyButton?.isEnabled = false
            errorLogRevealButton?.isEnabled = false
            errorLogClearButton?.isEnabled = false
        }
    }

    /// Copies the diagnostic log to the clipboard, flashing the button as feedback.
    @objc private func copyErrorLog() {
        guard errorLogEntry != nil,
              let text = errorLogTextView?.string, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let button = errorLogCopyButton else { return }
        button.title = L10n.aboutErrorLogCopied
        button.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.errorLogCopyButton?.title = L10n.aboutErrorLogCopy
            self?.errorLogCopyButton?.isEnabled = true
        }
    }

    /// Reveals the diagnostic log file in Finder.
    @objc private func revealErrorLog() {
        guard let url = errorLogEntry?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Manually reloads logs from disk.
    @objc private func refreshErrorLog() {
        reloadErrorLogFromDisk()
    }

    /// Deletes all capcap diagnostic logs and resets the visible error-log UI.
    @objc private func clearErrorLog() {
        CrashLogReader.deleteAllLogs()
        errorLogEntry = nil
        errorLogLoaded = true
        errorLogTextView?.string = L10n.aboutErrorLogEmptyBody
        errorLogTextView?.textColor = NSColor.white.withAlphaComponent(0.55)
        errorLogCopyButton?.isEnabled = false
        errorLogRevealButton?.isEnabled = false
        errorLogClearButton?.isEnabled = false
        refreshErrorLogStatus()
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

    @objc private func openStarOnGitHub() {
        if let url = URL(string: "https://github.com/realskyrin/capcap") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFeatureRequest() {
        if let url = URL(string: "https://github.com/realskyrin/capcap/issues/new?template=feature_request.yml") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openBugReport() {
        if let url = URL(string: "https://github.com/realskyrin/capcap/issues/new?template=bug_report.yml") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Updates" row — a status label plus a button whose role tracks state:
    /// "Check for Updates" normally, "Update Now" once a newer release is found.
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
        switch UpdateChecker.shared.state {
        case .available(let version):
            StatusBarController.presentUpdateAvailableAlert(version: version)
        case .installFailed:
            if let url = UpdateChecker.shared.latestPageURL {
                NSWorkspace.shared.open(url)
            }
        default:
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
        case .available(let version):
            statusLabel.stringValue = L10n.updateNewVersionStatus(version)
            statusLabel.textColor = accent
            button.title = L10n.updateInstallNowButton
            button.isEnabled = true
        case .downloading(_, let fraction):
            statusLabel.stringValue = L10n.updateDownloadingStatus(Int(fraction * 100))
            statusLabel.textColor = accent
            button.title = L10n.updateInstallNowButton
            button.isEnabled = false
        case .installing:
            statusLabel.stringValue = L10n.updateInstallingStatus
            statusLabel.textColor = accent
            button.title = L10n.updateInstallNowButton
            button.isEnabled = false
        case .failed:
            statusLabel.stringValue = L10n.updateFailedStatus
            statusLabel.textColor = warn
            button.title = L10n.updateRetryButton
            button.isEnabled = true
        case .installFailed:
            statusLabel.stringValue = L10n.updateInstallFailedStatus
            statusLabel.textColor = warn
            button.title = L10n.updateDownloadButton
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

    private struct ShortcutCardBuild {
        let card: CardView
        let title: NSTextField
        let field: NSTextField
        let setButton: NSButton
        let restoreButton: NSButton
    }

    private func buildShortcutCard(
        title: String,
        setAction: Selector,
        restoreAction: Selector
    ) -> ShortcutCardBuild {
        let card = CardView()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        pin(inner, to: card, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = primaryLabel(title)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(flexSpacer())

        let field = NSTextField()
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .center
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.textColor = NSColor.white.withAlphaComponent(0.92)
        field.translatesAutoresizingMaskIntoConstraints = false

        let fieldBackground = NSView()
        fieldBackground.wantsLayer = true
        fieldBackground.layer?.cornerRadius = 5
        fieldBackground.layer?.cornerCurve = .continuous
        fieldBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        fieldBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        fieldBackground.layer?.borderWidth = 1
        fieldBackground.translatesAutoresizingMaskIntoConstraints = false
        fieldBackground.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: fieldBackground.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: fieldBackground.bottomAnchor, constant: -4),
            field.leadingAnchor.constraint(equalTo: fieldBackground.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldBackground.trailingAnchor, constant: -10),
            fieldBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        row.addArrangedSubview(fieldBackground)

        let setButton = NSButton(title: L10n.shortcutSet, target: self, action: setAction)
        setButton.bezelStyle = .rounded
        setButton.controlSize = .small
        setButton.font = NSFont.systemFont(ofSize: 12)
        setButton.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(setButton)

        let restoreButton = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.counterclockwise.circle.fill",
                accessibilityDescription: L10n.shortcutRestore
            ) ?? NSImage(),
            target: self,
            action: restoreAction
        )
        restoreButton.bezelStyle = .inline
        restoreButton.isBordered = false
        restoreButton.imagePosition = .imageOnly
        restoreButton.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        restoreButton.toolTip = L10n.shortcutRestore
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(restoreButton)

        inner.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        return ShortcutCardBuild(
            card: card,
            title: titleLabel,
            field: field,
            setButton: setButton,
            restoreButton: restoreButton
        )
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
            let allGranted = AppPermissions.allRequiredGranted
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
        let wasStartup = isStartup
        isStartup = startup
        updateLaunchButtonVisibility()
        if startup {
            selectTab(.permissions)
        } else if wasStartup && selectedTab == .permissions && AppPermissions.allRequiredGranted {
            selectTab(.general)
        }
    }

    func showPermissionsTab() {
        selectTab(.permissions)
    }

    // MARK: - Permission polling

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }

    func refreshPermissionStatus() {
        let accessibilityGranted = AppPermissions.accessibilityGranted
        let screenRecordingGranted = AppPermissions.screenRecordingGranted

        accessibilityBadge?.configure(granted: accessibilityGranted)
        screenRecordingBadge?.configure(granted: screenRecordingGranted)

        // Only the startup-mode Launch button is gated on permissions; the
        // regular-mode Quit button stays enabled.
        if isStartup {
            refreshBottomAction()
        }
    }

    // MARK: - Actions

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let cases = AppLanguage.allCases
        let index = sender.indexOfSelectedItem
        guard cases.indices.contains(index) else { return }
        Defaults.language = cases[index]
    }

    @objc private func recordingSaveFormatPreferenceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let preference = RecordingSavePreference(rawValue: raw)
        else {
            return
        }
        Defaults.recordingSavePreference = preference
    }

    @objc private func autoRevealSavedFilesToggled(_ sender: NSSwitch) {
        Defaults.autoRevealSavedFiles = sender.state == .on
    }

    @objc private func chooseRecordingSavePathClicked() {
        chooseSaveDirectory(
            title: L10n.chooseRecordingSavePathTitle,
            currentURL: Defaults.recordingSaveDirectory
        ) { url in
            Defaults.recordingSaveDirectory = url
            self.refreshSavePathControls()
        }
    }

    @objc private func chooseScreenshotSavePathClicked() {
        chooseSaveDirectory(
            title: L10n.chooseScreenshotSavePathTitle,
            currentURL: Defaults.screenshotSaveDirectory
        ) { url in
            Defaults.screenshotSaveDirectory = url
            self.refreshSavePathControls()
        }
    }

    @objc private func revealRecordingSavePathClicked() {
        revealSaveDirectory(Defaults.recordingSaveDirectory)
    }

    @objc private func revealScreenshotSavePathClicked() {
        revealSaveDirectory(Defaults.screenshotSaveDirectory)
    }

    private func chooseSaveDirectory(
        title: String,
        currentURL: URL,
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = L10n.savePathChoose
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directoryURLForPanel(currentURL)

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }

    private func directoryURLForPanel(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let parent = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            return parent
        }
        return Defaults.defaultScreenshotSaveDirectory.deletingLastPathComponent()
    }

    private func revealSaveDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func historyCacheSliderChanged(_ sender: SettingsTickSlider) {
        guard Defaults.historyCacheEnabled else {
            sender.doubleValue = Double(Defaults.historyCacheLimit)
            return
        }
        let value = Int(sender.doubleValue.rounded())
        Defaults.historyCacheLimit = value
        let normalizedValue = Defaults.historyCacheLimit
        sender.doubleValue = Double(normalizedValue)
        historyCacheValueLabel?.stringValue = "\(normalizedValue)"
    }

    @objc private func historyCacheToggled(_ sender: NSSwitch) {
        Defaults.historyCacheEnabled = sender.state == .on
        updateHistoryCacheControlsEnabled()
    }

    @objc private func countdownSliderChanged(_ sender: SettingsTickSlider) {
        let value = Int(sender.doubleValue.rounded())
        Defaults.countdownSeconds = value
        countdownValueLabel?.stringValue = "\(Defaults.countdownSeconds)\(L10n.countdownSecondsSuffix)"
    }

    @objc private func windowShadowToggled(_ sender: NSSwitch) {
        Defaults.windowShadowEnabled = sender.state == .on
        updateWindowShadowControlsEnabled()
    }

    @objc private func windowShadowSizeChanged(_ sender: NSSlider) {
        Defaults.windowShadowSize = sender.doubleValue
        windowShadowSizeValueLabel?.stringValue = "\(Int(Defaults.windowShadowSize.rounded()))"
        windowShadowPreview?.shadowSize = CGFloat(Defaults.windowShadowSize)
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

    @objc private func pinAcrossSpacesToggled(_ sender: NSSwitch) {
        Defaults.pinAcrossSpaces = sender.state == .on
    }

    @objc private func menuBarSwitchToggled(_ sender: NSSwitch) {
        let visible = sender.state == .on
        Defaults.showMenuBar = visible
        onMenuBarToggle?(visible)
    }

    @objc private func openAccessibilitySettings(_ sender: NSButton) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPermissionFlow(.accessibility, from: sender)
    }

    @objc private func openScreenRecordingSettings(_ sender: NSButton) {
        if #available(macOS 15.0, *) {
            CGRequestScreenCaptureAccess()
        }
        startPermissionFlow(.screenRecording, from: sender)
    }

    private func startPermissionFlow(_ pane: PermissionFlowPane, from sourceView: NSView) {
        permissionFlowController.setLocaleIdentifier(Defaults.language.lprojName)
        permissionFlowController.authorize(
            pane: pane,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: sourceFrameInScreen(for: sourceView)
        )
    }

    private func sourceFrameInScreen(for view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    func closePermissionFlowPanel() {
        permissionFlowController.closePanel()
    }

    @objc private func launchClicked() {
        if isStartup {
            guard AppPermissions.allRequiredGranted else {
                showPermissionsTab()
                refreshPermissionStatus()
                return
            }
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

    /// Tells the user a recorded combo is already taken by another function,
    /// so they can pick a different one. Recording is already cancelled by the
    /// caller before this is shown.
    private func presentHotkeyConflictAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.shortcutConflictTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        if let win = self.window {
            alert.beginSheetModal(for: win, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func cancelShortcutRecordings(except slot: HotkeyManager.HotkeySlot) {
        if slot != .screenshot, shortcutRecordingMonitor != nil {
            cancelShortcutRecording()
        }
        if slot != .fullScreenScreenshot, fullScreenScreenshotShortcutRecordingMonitor != nil {
            cancelFullScreenScreenshotShortcutRecording()
        }
        if slot != .colorPicker, colorPickerShortcutRecordingMonitor != nil {
            cancelColorPickerShortcutRecording()
        }
        if slot != .selectedImagePin, selectedImagePinShortcutRecordingMonitor != nil {
            cancelSelectedImagePinShortcutRecording()
        }
        if slot != .clipboardImagePin, clipboardImagePinShortcutRecordingMonitor != nil {
            cancelClipboardImagePinShortcutRecording()
        }
        if slot != .selectedImageEdit, selectedImageEditShortcutRecordingMonitor != nil {
            cancelSelectedImageEditShortcutRecording()
        }
        if slot != .clipboardImageEdit, clipboardImageEditShortcutRecordingMonitor != nil {
            cancelClipboardImageEditShortcutRecording()
        }
        if slot != .textRecognition, textRecognitionShortcutRecordingMonitor != nil {
            cancelTextRecognitionShortcutRecording()
        }
        if slot != .copyImageText, copyImageTextShortcutRecordingMonitor != nil {
            cancelCopyImageTextShortcutRecording()
        }
        if slot != .screenshotTranslation, screenshotTranslationShortcutRecordingMonitor != nil {
            cancelScreenshotTranslationShortcutRecording()
        }
        if slot != .record, recordShortcutRecordingMonitor != nil {
            cancelRecordShortcutRecording()
        }
        if slot != .imageMerge, imageMergeShortcutRecordingMonitor != nil {
            cancelImageMergeShortcutRecording()
        }
        if slot != .clipboard, clipboardShortcutRecordingMonitor != nil {
            cancelClipboardShortcutRecording()
        }
        if slot != .fileSave, fileSaveShortcutRecordingMonitor != nil {
            cancelFileSaveShortcutRecording()
        }
        if slot != .previousHistoryImage, previousHistoryImageShortcutRecordingMonitor != nil {
            cancelPreviousHistoryImageShortcutRecording()
        }
        if slot != .nextHistoryImage, nextHistoryImageShortcutRecordingMonitor != nil {
            cancelNextHistoryImageShortcutRecording()
        }
    }

    @objc private func shortcutSetClicked() {
        if shortcutRecordingMonitor != nil {
            cancelShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .screenshot)
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

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .screenshot) {
                self.cancelShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
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

    @objc private func fullScreenScreenshotShortcutSetClicked() {
        if fullScreenScreenshotShortcutRecordingMonitor != nil {
            cancelFullScreenScreenshotShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .fullScreenScreenshot)
        HotkeyManager.shared.beginRecording()
        fullScreenScreenshotShortcutSetButton.title = L10n.shortcutCancel
        fullScreenScreenshotShortcutField.stringValue = L10n.shortcutWaiting
        fullScreenScreenshotShortcutRestoreButton.isHidden = true

        fullScreenScreenshotShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelFullScreenScreenshotShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .fullScreenScreenshot) {
                self.cancelFullScreenScreenshotShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.fullScreenScreenshotHotkeyKeyCode = Int(keyCode)
            Defaults.fullScreenScreenshotHotkeyModifiers = Int(carbonMods)
            self.finishFullScreenScreenshotShortcutRecording()
            return nil
        }
    }

    @objc private func fullScreenScreenshotShortcutRestoreClicked() {
        if fullScreenScreenshotShortcutRecordingMonitor != nil {
            cancelFullScreenScreenshotShortcutRecording()
        }
        Defaults.clearFullScreenScreenshotHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshFullScreenScreenshotShortcutDisplay()
    }

    private func finishFullScreenScreenshotShortcutRecording() {
        if let m = fullScreenScreenshotShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            fullScreenScreenshotShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshFullScreenScreenshotShortcutDisplay()
    }

    func cancelFullScreenScreenshotShortcutRecording() {
        guard fullScreenScreenshotShortcutRecordingMonitor != nil else { return }
        if let m = fullScreenScreenshotShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            fullScreenScreenshotShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshFullScreenScreenshotShortcutDisplay()
    }

    private func refreshFullScreenScreenshotShortcutDisplay() {
        fullScreenScreenshotShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentFullScreenScreenshotDisplayString() {
            fullScreenScreenshotShortcutField?.stringValue = display
            fullScreenScreenshotShortcutRestoreButton?.isHidden = false
        } else {
            fullScreenScreenshotShortcutField?.stringValue = L10n.fullScreenScreenshotShortcutDefaultDisplay
            fullScreenScreenshotShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func colorPickerShortcutSetClicked() {
        if colorPickerShortcutRecordingMonitor != nil {
            cancelColorPickerShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .colorPicker)
        HotkeyManager.shared.beginRecording()
        colorPickerShortcutSetButton.title = L10n.shortcutCancel
        colorPickerShortcutField.stringValue = L10n.shortcutWaiting
        colorPickerShortcutRestoreButton.isHidden = true

        colorPickerShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelColorPickerShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .colorPicker) {
                self.cancelColorPickerShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.colorPickerHotkeyKeyCode = Int(keyCode)
            Defaults.colorPickerHotkeyModifiers = Int(carbonMods)
            self.finishColorPickerShortcutRecording()
            return nil
        }
    }

    @objc private func colorPickerShortcutRestoreClicked() {
        if colorPickerShortcutRecordingMonitor != nil {
            cancelColorPickerShortcutRecording()
        }
        Defaults.clearColorPickerHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshColorPickerShortcutDisplay()
    }

    private func finishColorPickerShortcutRecording() {
        if let m = colorPickerShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            colorPickerShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshColorPickerShortcutDisplay()
    }

    func cancelColorPickerShortcutRecording() {
        guard colorPickerShortcutRecordingMonitor != nil else { return }
        if let m = colorPickerShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            colorPickerShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshColorPickerShortcutDisplay()
    }

    private func refreshColorPickerShortcutDisplay() {
        colorPickerShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentColorPickerDisplayString() {
            colorPickerShortcutField?.stringValue = display
            colorPickerShortcutRestoreButton?.isHidden = false
        } else {
            colorPickerShortcutField?.stringValue = L10n.colorPickerShortcutDefaultDisplay
            colorPickerShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func selectedImagePinShortcutSetClicked() {
        if selectedImagePinShortcutRecordingMonitor != nil {
            cancelSelectedImagePinShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .selectedImagePin)
        HotkeyManager.shared.beginRecording()
        selectedImagePinShortcutSetButton.title = L10n.shortcutCancel
        selectedImagePinShortcutField.stringValue = L10n.shortcutWaiting
        selectedImagePinShortcutRestoreButton.isHidden = true

        selectedImagePinShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelSelectedImagePinShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            // No two functions may share a shortcut — reject a combo already
            // bound to the screenshot or countdown hotkey.
            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .selectedImagePin) {
                self.cancelSelectedImagePinShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.selectedImagePinHotkeyKeyCode = Int(keyCode)
            Defaults.selectedImagePinHotkeyModifiers = Int(carbonMods)
            self.finishSelectedImagePinShortcutRecording()
            return nil
        }
    }

    @objc private func selectedImagePinShortcutRestoreClicked() {
        if selectedImagePinShortcutRecordingMonitor != nil {
            cancelSelectedImagePinShortcutRecording()
        }
        Defaults.clearSelectedImagePinHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshSelectedImagePinShortcutDisplay()
    }

    private func finishSelectedImagePinShortcutRecording() {
        if let m = selectedImagePinShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            selectedImagePinShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshSelectedImagePinShortcutDisplay()
    }

    func cancelSelectedImagePinShortcutRecording() {
        guard selectedImagePinShortcutRecordingMonitor != nil else { return }
        if let m = selectedImagePinShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            selectedImagePinShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshSelectedImagePinShortcutDisplay()
    }

    private func refreshSelectedImagePinShortcutDisplay() {
        selectedImagePinShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentSelectedImagePinDisplayString() {
            selectedImagePinShortcutField?.stringValue = display
            selectedImagePinShortcutRestoreButton?.isHidden = false
        } else {
            selectedImagePinShortcutField?.stringValue = L10n.selectedImagePinShortcutDefaultDisplay
            selectedImagePinShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func clipboardImagePinShortcutSetClicked() {
        if clipboardImagePinShortcutRecordingMonitor != nil {
            cancelClipboardImagePinShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .clipboardImagePin)
        HotkeyManager.shared.beginRecording()
        clipboardImagePinShortcutSetButton.title = L10n.shortcutCancel
        clipboardImagePinShortcutField.stringValue = L10n.shortcutWaiting
        clipboardImagePinShortcutRestoreButton.isHidden = true

        clipboardImagePinShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelClipboardImagePinShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            // No two functions may share a shortcut — reject a combo already
            // bound to the screenshot or countdown hotkey.
            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .clipboardImagePin) {
                self.cancelClipboardImagePinShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.clipboardImagePinHotkeyKeyCode = Int(keyCode)
            Defaults.clipboardImagePinHotkeyModifiers = Int(carbonMods)
            self.finishClipboardImagePinShortcutRecording()
            return nil
        }
    }

    @objc private func clipboardImagePinShortcutRestoreClicked() {
        if clipboardImagePinShortcutRecordingMonitor != nil {
            cancelClipboardImagePinShortcutRecording()
        }
        Defaults.clearClipboardImagePinHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshClipboardImagePinShortcutDisplay()
    }

    private func finishClipboardImagePinShortcutRecording() {
        if let m = clipboardImagePinShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            clipboardImagePinShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshClipboardImagePinShortcutDisplay()
    }

    func cancelClipboardImagePinShortcutRecording() {
        guard clipboardImagePinShortcutRecordingMonitor != nil else { return }
        if let m = clipboardImagePinShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            clipboardImagePinShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshClipboardImagePinShortcutDisplay()
    }

    private func refreshClipboardImagePinShortcutDisplay() {
        clipboardImagePinShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentClipboardImagePinDisplayString() {
            clipboardImagePinShortcutField?.stringValue = display
            clipboardImagePinShortcutRestoreButton?.isHidden = false
        } else {
            clipboardImagePinShortcutField?.stringValue = L10n.clipboardImagePinShortcutDefaultDisplay
            clipboardImagePinShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func selectedImageEditShortcutSetClicked() {
        if selectedImageEditShortcutRecordingMonitor != nil {
            cancelSelectedImageEditShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .selectedImageEdit)
        HotkeyManager.shared.beginRecording()
        selectedImageEditShortcutSetButton.title = L10n.shortcutCancel
        selectedImageEditShortcutField.stringValue = L10n.shortcutWaiting
        selectedImageEditShortcutRestoreButton.isHidden = true

        selectedImageEditShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelSelectedImageEditShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .selectedImageEdit) {
                self.cancelSelectedImageEditShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.selectedImageEditHotkeyKeyCode = Int(keyCode)
            Defaults.selectedImageEditHotkeyModifiers = Int(carbonMods)
            self.finishSelectedImageEditShortcutRecording()
            return nil
        }
    }

    @objc private func selectedImageEditShortcutRestoreClicked() {
        if selectedImageEditShortcutRecordingMonitor != nil {
            cancelSelectedImageEditShortcutRecording()
        }
        Defaults.clearSelectedImageEditHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshSelectedImageEditShortcutDisplay()
    }

    private func finishSelectedImageEditShortcutRecording() {
        if let m = selectedImageEditShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            selectedImageEditShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshSelectedImageEditShortcutDisplay()
    }

    func cancelSelectedImageEditShortcutRecording() {
        guard selectedImageEditShortcutRecordingMonitor != nil else { return }
        if let m = selectedImageEditShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            selectedImageEditShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshSelectedImageEditShortcutDisplay()
    }

    private func refreshSelectedImageEditShortcutDisplay() {
        selectedImageEditShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentSelectedImageEditDisplayString() {
            selectedImageEditShortcutField?.stringValue = display
            selectedImageEditShortcutRestoreButton?.isHidden = false
        } else {
            selectedImageEditShortcutField?.stringValue = L10n.selectedImageEditShortcutDefaultDisplay
            selectedImageEditShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func clipboardImageEditShortcutSetClicked() {
        if clipboardImageEditShortcutRecordingMonitor != nil {
            cancelClipboardImageEditShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .clipboardImageEdit)
        HotkeyManager.shared.beginRecording()
        clipboardImageEditShortcutSetButton.title = L10n.shortcutCancel
        clipboardImageEditShortcutField.stringValue = L10n.shortcutWaiting
        clipboardImageEditShortcutRestoreButton.isHidden = true

        clipboardImageEditShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelClipboardImageEditShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .clipboardImageEdit) {
                self.cancelClipboardImageEditShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.clipboardImageEditHotkeyKeyCode = Int(keyCode)
            Defaults.clipboardImageEditHotkeyModifiers = Int(carbonMods)
            self.finishClipboardImageEditShortcutRecording()
            return nil
        }
    }

    @objc private func clipboardImageEditShortcutRestoreClicked() {
        if clipboardImageEditShortcutRecordingMonitor != nil {
            cancelClipboardImageEditShortcutRecording()
        }
        Defaults.clearClipboardImageEditHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshClipboardImageEditShortcutDisplay()
    }

    private func finishClipboardImageEditShortcutRecording() {
        if let m = clipboardImageEditShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            clipboardImageEditShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshClipboardImageEditShortcutDisplay()
    }

    func cancelClipboardImageEditShortcutRecording() {
        guard clipboardImageEditShortcutRecordingMonitor != nil else { return }
        if let m = clipboardImageEditShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            clipboardImageEditShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshClipboardImageEditShortcutDisplay()
    }

    private func refreshClipboardImageEditShortcutDisplay() {
        clipboardImageEditShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentClipboardImageEditDisplayString() {
            clipboardImageEditShortcutField?.stringValue = display
            clipboardImageEditShortcutRestoreButton?.isHidden = false
        } else {
            clipboardImageEditShortcutField?.stringValue = L10n.clipboardImageEditShortcutDefaultDisplay
            clipboardImageEditShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func textRecognitionShortcutSetClicked() {
        if textRecognitionShortcutRecordingMonitor != nil {
            cancelTextRecognitionShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .textRecognition)
        HotkeyManager.shared.beginRecording()
        textRecognitionShortcutSetButton.title = L10n.shortcutCancel
        textRecognitionShortcutField.stringValue = L10n.shortcutWaiting
        textRecognitionShortcutRestoreButton.isHidden = true

        textRecognitionShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelTextRecognitionShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .textRecognition) {
                self.cancelTextRecognitionShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.textRecognitionHotkeyKeyCode = Int(keyCode)
            Defaults.textRecognitionHotkeyModifiers = Int(carbonMods)
            self.finishTextRecognitionShortcutRecording()
            return nil
        }
    }

    @objc private func textRecognitionShortcutRestoreClicked() {
        if textRecognitionShortcutRecordingMonitor != nil {
            cancelTextRecognitionShortcutRecording()
        }
        Defaults.clearTextRecognitionHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshTextRecognitionShortcutDisplay()
    }

    private func finishTextRecognitionShortcutRecording() {
        if let m = textRecognitionShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            textRecognitionShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshTextRecognitionShortcutDisplay()
    }

    func cancelTextRecognitionShortcutRecording() {
        guard textRecognitionShortcutRecordingMonitor != nil else { return }
        if let m = textRecognitionShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            textRecognitionShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshTextRecognitionShortcutDisplay()
    }

    private func refreshTextRecognitionShortcutDisplay() {
        textRecognitionShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentTextRecognitionDisplayString() {
            textRecognitionShortcutField?.stringValue = display
            textRecognitionShortcutRestoreButton?.isHidden = false
        } else {
            textRecognitionShortcutField?.stringValue = L10n.textRecognitionShortcutDefaultDisplay
            textRecognitionShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func copyImageTextShortcutSetClicked() {
        if copyImageTextShortcutRecordingMonitor != nil {
            cancelCopyImageTextShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .copyImageText)
        HotkeyManager.shared.beginRecording()
        copyImageTextShortcutSetButton.title = L10n.shortcutCancel
        copyImageTextShortcutField.stringValue = L10n.shortcutWaiting
        copyImageTextShortcutRestoreButton.isHidden = true

        copyImageTextShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelCopyImageTextShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .copyImageText) {
                self.cancelCopyImageTextShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.copyImageTextHotkeyKeyCode = Int(keyCode)
            Defaults.copyImageTextHotkeyModifiers = Int(carbonMods)
            self.finishCopyImageTextShortcutRecording()
            return nil
        }
    }

    @objc private func copyImageTextShortcutRestoreClicked() {
        if copyImageTextShortcutRecordingMonitor != nil {
            cancelCopyImageTextShortcutRecording()
        }
        Defaults.clearCopyImageTextHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshCopyImageTextShortcutDisplay()
    }

    private func finishCopyImageTextShortcutRecording() {
        if let m = copyImageTextShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            copyImageTextShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshCopyImageTextShortcutDisplay()
    }

    func cancelCopyImageTextShortcutRecording() {
        guard copyImageTextShortcutRecordingMonitor != nil else { return }
        if let m = copyImageTextShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            copyImageTextShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshCopyImageTextShortcutDisplay()
    }

    private func refreshCopyImageTextShortcutDisplay() {
        copyImageTextShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentCopyImageTextDisplayString() {
            copyImageTextShortcutField?.stringValue = display
            copyImageTextShortcutRestoreButton?.isHidden = false
        } else {
            copyImageTextShortcutField?.stringValue = L10n.copyImageTextShortcutDefaultDisplay
            copyImageTextShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func screenshotTranslationShortcutSetClicked() {
        if screenshotTranslationShortcutRecordingMonitor != nil {
            cancelScreenshotTranslationShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .screenshotTranslation)
        HotkeyManager.shared.beginRecording()
        screenshotTranslationShortcutSetButton.title = L10n.shortcutCancel
        screenshotTranslationShortcutField.stringValue = L10n.shortcutWaiting
        screenshotTranslationShortcutRestoreButton.isHidden = true

        screenshotTranslationShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelScreenshotTranslationShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .screenshotTranslation) {
                self.cancelScreenshotTranslationShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.screenshotTranslationHotkeyKeyCode = Int(keyCode)
            Defaults.screenshotTranslationHotkeyModifiers = Int(carbonMods)
            self.finishScreenshotTranslationShortcutRecording()
            return nil
        }
    }

    @objc private func screenshotTranslationShortcutRestoreClicked() {
        if screenshotTranslationShortcutRecordingMonitor != nil {
            cancelScreenshotTranslationShortcutRecording()
        }
        Defaults.clearScreenshotTranslationHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshScreenshotTranslationShortcutDisplay()
    }

    private func finishScreenshotTranslationShortcutRecording() {
        if let m = screenshotTranslationShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            screenshotTranslationShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshScreenshotTranslationShortcutDisplay()
    }

    func cancelScreenshotTranslationShortcutRecording() {
        guard screenshotTranslationShortcutRecordingMonitor != nil else { return }
        if let m = screenshotTranslationShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            screenshotTranslationShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshScreenshotTranslationShortcutDisplay()
    }

    private func refreshScreenshotTranslationShortcutDisplay() {
        screenshotTranslationShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentScreenshotTranslationDisplayString() {
            screenshotTranslationShortcutField?.stringValue = display
            screenshotTranslationShortcutRestoreButton?.isHidden = false
        } else {
            screenshotTranslationShortcutField?.stringValue = L10n.screenshotTranslationShortcutDefaultDisplay
            screenshotTranslationShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func recordShortcutSetClicked() {
        if recordShortcutRecordingMonitor != nil {
            cancelRecordShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .record)
        HotkeyManager.shared.beginRecording()
        recordShortcutSetButton.title = L10n.shortcutCancel
        recordShortcutField.stringValue = L10n.shortcutWaiting
        recordShortcutRestoreButton.isHidden = true

        recordShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelRecordShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .record) {
                self.cancelRecordShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.recordHotkeyKeyCode = Int(keyCode)
            Defaults.recordHotkeyModifiers = Int(carbonMods)
            self.finishRecordShortcutRecording()
            return nil
        }
    }

    @objc private func recordShortcutRestoreClicked() {
        if recordShortcutRecordingMonitor != nil {
            cancelRecordShortcutRecording()
        }
        Defaults.clearRecordHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshRecordShortcutDisplay()
    }

    private func finishRecordShortcutRecording() {
        if let m = recordShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            recordShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshRecordShortcutDisplay()
    }

    func cancelRecordShortcutRecording() {
        guard recordShortcutRecordingMonitor != nil else { return }
        if let m = recordShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            recordShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshRecordShortcutDisplay()
    }

    private func refreshRecordShortcutDisplay() {
        recordShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentRecordDisplayString() {
            recordShortcutField?.stringValue = display
            recordShortcutRestoreButton?.isHidden = false
        } else {
            recordShortcutField?.stringValue = L10n.recordShortcutDefaultDisplay
            recordShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func imageMergeShortcutSetClicked() {
        if imageMergeShortcutRecordingMonitor != nil {
            cancelImageMergeShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .imageMerge)
        HotkeyManager.shared.beginRecording()
        imageMergeShortcutSetButton.title = L10n.shortcutCancel
        imageMergeShortcutField.stringValue = L10n.shortcutWaiting
        imageMergeShortcutRestoreButton.isHidden = true

        imageMergeShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelImageMergeShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) {
                return nil
            }

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .imageMerge) {
                self.cancelImageMergeShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.imageMergeHotkeyKeyCode = Int(keyCode)
            Defaults.imageMergeHotkeyModifiers = Int(carbonMods)
            self.finishImageMergeShortcutRecording()
            return nil
        }
    }

    @objc private func imageMergeShortcutRestoreClicked() {
        if imageMergeShortcutRecordingMonitor != nil {
            cancelImageMergeShortcutRecording()
        }
        Defaults.clearImageMergeHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshImageMergeShortcutDisplay()
    }

    private func finishImageMergeShortcutRecording() {
        if let m = imageMergeShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            imageMergeShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshImageMergeShortcutDisplay()
    }

    func cancelImageMergeShortcutRecording() {
        guard imageMergeShortcutRecordingMonitor != nil else { return }
        if let m = imageMergeShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            imageMergeShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshImageMergeShortcutDisplay()
    }

    private func refreshImageMergeShortcutDisplay() {
        imageMergeShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentImageMergeDisplayString() {
            imageMergeShortcutField?.stringValue = display
            imageMergeShortcutRestoreButton?.isHidden = false
        } else {
            imageMergeShortcutField?.stringValue = L10n.imageMergeShortcutDefaultDisplay
            imageMergeShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func clipboardShortcutSetClicked() {
        if clipboardShortcutRecordingMonitor != nil {
            cancelClipboardShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .clipboard)
        HotkeyManager.shared.beginRecording()
        clipboardShortcutSetButton.title = L10n.shortcutCancel
        clipboardShortcutField.stringValue = L10n.shortcutWaiting
        clipboardShortcutRestoreButton.isHidden = true

        clipboardShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelClipboardShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            // Unlike the screenshot/pin hotkeys, the editor hotkeys are
            // allowed to be bare — they only fire inside the editor overlay,
            // where typing is restricted to text-annotation editing (already
            // guarded against in the local key monitor).

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .clipboard) {
                self.cancelClipboardShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.clipboardHotkeyKeyCode = Int(keyCode)
            Defaults.clipboardHotkeyModifiers = Int(carbonMods)
            NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
            self.finishClipboardShortcutRecording()
            return nil
        }
    }

    @objc private func clipboardShortcutRestoreClicked() {
        if clipboardShortcutRecordingMonitor != nil {
            cancelClipboardShortcutRecording()
        }
        Defaults.clearClipboardHotkey()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshClipboardShortcutDisplay()
    }

    private func finishClipboardShortcutRecording() {
        if let m = clipboardShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            clipboardShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshClipboardShortcutDisplay()
    }

    func cancelClipboardShortcutRecording() {
        guard clipboardShortcutRecordingMonitor != nil else { return }
        if let m = clipboardShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            clipboardShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshClipboardShortcutDisplay()
    }

    private func refreshClipboardShortcutDisplay() {
        clipboardShortcutSetButton?.title = L10n.shortcutSet
        if let display = HotkeyManager.currentClipboardDisplayString() {
            clipboardShortcutField?.stringValue = display
            clipboardShortcutRestoreButton?.isHidden = false
        } else {
            clipboardShortcutField?.stringValue = L10n.clipboardShortcutDefaultDisplay
            clipboardShortcutRestoreButton?.isHidden = true
        }
    }

    @objc private func fileSaveShortcutSetClicked() {
        if fileSaveShortcutRecordingMonitor != nil {
            cancelFileSaveShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .fileSave)
        HotkeyManager.shared.beginRecording()
        fileSaveShortcutSetButton.title = L10n.shortcutCancel
        fileSaveShortcutField.stringValue = L10n.shortcutWaiting
        fileSaveShortcutRestoreButton.isHidden = true

        fileSaveShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelFileSaveShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .fileSave) {
                self.cancelFileSaveShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.fileSaveHotkeyKeyCode = Int(keyCode)
            Defaults.fileSaveHotkeyModifiers = Int(carbonMods)
            self.finishFileSaveShortcutRecording()
            return nil
        }
    }

    @objc private func fileSaveShortcutRestoreClicked() {
        if fileSaveShortcutRecordingMonitor != nil {
            cancelFileSaveShortcutRecording()
        }
        Defaults.clearFileSaveHotkey()
        refreshFileSaveShortcutDisplay()
    }

    private func finishFileSaveShortcutRecording() {
        if let m = fileSaveShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            fileSaveShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshFileSaveShortcutDisplay()
    }

    func cancelFileSaveShortcutRecording() {
        guard fileSaveShortcutRecordingMonitor != nil else { return }
        if let m = fileSaveShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            fileSaveShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshFileSaveShortcutDisplay()
    }

    private func refreshFileSaveShortcutDisplay() {
        fileSaveShortcutSetButton?.title = L10n.shortcutSet
        fileSaveShortcutField?.stringValue = HotkeyManager.currentFileSaveDisplayString()
        fileSaveShortcutRestoreButton?.isHidden = !Defaults.hasCustomFileSaveHotkey
    }

    @objc private func previousHistoryImageShortcutSetClicked() {
        if previousHistoryImageShortcutRecordingMonitor != nil {
            cancelPreviousHistoryImageShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .previousHistoryImage)
        HotkeyManager.shared.beginRecording()
        previousHistoryImageShortcutSetButton.title = L10n.shortcutCancel
        previousHistoryImageShortcutField.stringValue = L10n.shortcutWaiting
        previousHistoryImageShortcutRestoreButton.isHidden = true

        previousHistoryImageShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelPreviousHistoryImageShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .previousHistoryImage) {
                self.cancelPreviousHistoryImageShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.previousHistoryImageHotkeyKeyCode = Int(keyCode)
            Defaults.previousHistoryImageHotkeyModifiers = Int(carbonMods)
            self.finishPreviousHistoryImageShortcutRecording()
            return nil
        }
    }

    @objc private func previousHistoryImageShortcutRestoreClicked() {
        if previousHistoryImageShortcutRecordingMonitor != nil {
            cancelPreviousHistoryImageShortcutRecording()
        }
        Defaults.clearPreviousHistoryImageHotkey()
        refreshPreviousHistoryImageShortcutDisplay()
    }

    private func finishPreviousHistoryImageShortcutRecording() {
        if let m = previousHistoryImageShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            previousHistoryImageShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshPreviousHistoryImageShortcutDisplay()
    }

    func cancelPreviousHistoryImageShortcutRecording() {
        guard previousHistoryImageShortcutRecordingMonitor != nil else { return }
        if let m = previousHistoryImageShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            previousHistoryImageShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshPreviousHistoryImageShortcutDisplay()
    }

    private func refreshPreviousHistoryImageShortcutDisplay() {
        previousHistoryImageShortcutSetButton?.title = L10n.shortcutSet
        previousHistoryImageShortcutField?.stringValue = HotkeyManager.currentPreviousHistoryImageDisplayString()
        previousHistoryImageShortcutRestoreButton?.isHidden = !Defaults.hasCustomPreviousHistoryImageHotkey
    }

    @objc private func nextHistoryImageShortcutSetClicked() {
        if nextHistoryImageShortcutRecordingMonitor != nil {
            cancelNextHistoryImageShortcutRecording()
            return
        }
        cancelShortcutRecordings(except: .nextHistoryImage)
        HotkeyManager.shared.beginRecording()
        nextHistoryImageShortcutSetButton.title = L10n.shortcutCancel
        nextHistoryImageShortcutField.stringValue = L10n.shortcutWaiting
        nextHistoryImageShortcutRestoreButton.isHidden = true

        nextHistoryImageShortcutRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            let isEscape = event.keyCode == UInt16(kVK_Escape)
            let activeModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let pressedModifiers = modifiers.intersection(activeModifierMask)

            if isEscape && pressedModifiers.isEmpty {
                self.cancelNextHistoryImageShortcutRecording()
                return nil
            }

            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)

            if let conflict = HotkeyManager.shared.hotkeyConflictMessage(
                forKeyCode: keyCode, modifiers: carbonMods, assigningTo: .nextHistoryImage) {
                self.cancelNextHistoryImageShortcutRecording()
                self.presentHotkeyConflictAlert(conflict)
                return nil
            }

            Defaults.nextHistoryImageHotkeyKeyCode = Int(keyCode)
            Defaults.nextHistoryImageHotkeyModifiers = Int(carbonMods)
            self.finishNextHistoryImageShortcutRecording()
            return nil
        }
    }

    @objc private func nextHistoryImageShortcutRestoreClicked() {
        if nextHistoryImageShortcutRecordingMonitor != nil {
            cancelNextHistoryImageShortcutRecording()
        }
        Defaults.clearNextHistoryImageHotkey()
        refreshNextHistoryImageShortcutDisplay()
    }

    private func finishNextHistoryImageShortcutRecording() {
        if let m = nextHistoryImageShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            nextHistoryImageShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshNextHistoryImageShortcutDisplay()
    }

    func cancelNextHistoryImageShortcutRecording() {
        guard nextHistoryImageShortcutRecordingMonitor != nil else { return }
        if let m = nextHistoryImageShortcutRecordingMonitor {
            NSEvent.removeMonitor(m)
            nextHistoryImageShortcutRecordingMonitor = nil
        }
        HotkeyManager.shared.endRecording()
        refreshNextHistoryImageShortcutDisplay()
    }

    private func refreshNextHistoryImageShortcutDisplay() {
        nextHistoryImageShortcutSetButton?.title = L10n.shortcutSet
        nextHistoryImageShortcutField?.stringValue = HotkeyManager.currentNextHistoryImageDisplayString()
        nextHistoryImageShortcutRestoreButton?.isHidden = !Defaults.hasCustomNextHistoryImageHotkey
    }

    @objc private func shortcutsResetClicked() {
        cancelShortcutRecording()
        cancelFullScreenScreenshotShortcutRecording()
        cancelColorPickerShortcutRecording()
        cancelSelectedImagePinShortcutRecording()
        cancelClipboardImagePinShortcutRecording()
        cancelSelectedImageEditShortcutRecording()
        cancelClipboardImageEditShortcutRecording()
        cancelTextRecognitionShortcutRecording()
        cancelCopyImageTextShortcutRecording()
        cancelScreenshotTranslationShortcutRecording()
        cancelRecordShortcutRecording()
        cancelImageMergeShortcutRecording()
        cancelClipboardShortcutRecording()
        cancelFileSaveShortcutRecording()
        cancelPreviousHistoryImageShortcutRecording()
        cancelNextHistoryImageShortcutRecording()

        Defaults.resetShortcutHotkeysToDefaults()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
        refreshShortcutDisplay()
        refreshFullScreenScreenshotShortcutDisplay()
        refreshColorPickerShortcutDisplay()
        refreshSelectedImagePinShortcutDisplay()
        refreshClipboardImagePinShortcutDisplay()
        refreshSelectedImageEditShortcutDisplay()
        refreshClipboardImageEditShortcutDisplay()
        refreshTextRecognitionShortcutDisplay()
        refreshCopyImageTextShortcutDisplay()
        refreshScreenshotTranslationShortcutDisplay()
        refreshRecordShortcutDisplay()
        refreshImageMergeShortcutDisplay()
        refreshClipboardShortcutDisplay()
        refreshFileSaveShortcutDisplay()
        refreshPreviousHistoryImageShortcutDisplay()
        refreshNextHistoryImageShortcutDisplay()
    }

    @objc private func updateLocalization() {
        permissionFlowController.setLocaleIdentifier(Defaults.language.lprojName)
        menuBarTitleLabel?.stringValue = L10n.showMenuBarIcon
        launchAtLoginTitleLabel?.stringValue = L10n.launchAtLogin
        demoModeTitleLabel?.stringValue = L10n.demoMode
        demoModeSubtitleLabel?.stringValue = L10n.demoModeHint
        pinAcrossSpacesTitleLabel?.stringValue = L10n.pinAcrossSpaces
        pinAcrossSpacesSubtitleLabel?.stringValue = L10n.pinAcrossSpacesHint
        pinAcrossSpacesSwitch?.state = Defaults.pinAcrossSpaces ? .on : .off
        langTitleLabel?.stringValue = L10n.languageHeader
        filenameRuleCard?.refreshLocalization()
        savePathTitleLabel?.stringValue = L10n.savePathTitle
        savePathSubtitleLabel?.stringValue = L10n.savePathSubtitle
        autoRevealSavedFilesTitleLabel?.stringValue = L10n.autoRevealSavedFilesLabel
        autoRevealSavedFilesHintLabel?.stringValue = L10n.autoRevealSavedFilesHint
        autoRevealSavedFilesSwitch?.state = Defaults.autoRevealSavedFiles ? .on : .off
        recordingSavePathTitleLabel?.stringValue = L10n.recordingSavePathLabel
        recordingSaveFormatTitleLabel?.stringValue = L10n.recordingSaveFormatSettingLabel
        screenshotSavePathTitleLabel?.stringValue = L10n.screenshotSavePathLabel
        recordingSavePathChooseButton?.title = L10n.savePathChoose
        recordingSavePathRevealButton?.title = L10n.savePathReveal
        screenshotSavePathChooseButton?.title = L10n.savePathChoose
        screenshotSavePathRevealButton?.title = L10n.savePathReveal
        refreshSavePathControls()
        accessibilityNameLabel?.stringValue = L10n.accessibilityPermission
        accessibilityDescLabel?.stringValue = L10n.accessibilityDescription
        screenRecordingNameLabel?.stringValue = L10n.screenRecordingPermission
        screenRecordingDescLabel?.stringValue = L10n.screenRecordingDescription
        historyCacheToggleTitleLabel?.stringValue = L10n.historyCacheToggleLabel
        historyCacheToggleHintLabel?.stringValue = L10n.historyCacheToggleHint
        historyCacheTitleLabel?.stringValue = L10n.historyCacheLabel
        historyCacheHintLabel?.stringValue = L10n.historyCacheHint
        windowShadowTitleLabel?.stringValue = L10n.windowShadowToggleLabel
        windowShadowSubtitleLabel?.stringValue = L10n.windowShadowToggleHint
        windowShadowSizeTitleLabel?.stringValue = L10n.windowShadowSizeLabel
        windowShadowSizeHintLabel?.stringValue = L10n.windowShadowSizeHint
        countdownTitleLabel?.stringValue = L10n.countdownLabel
        countdownHintLabel?.stringValue = L10n.countdownHint
        countdownValueLabel?.stringValue = "\(Defaults.countdownSeconds)\(L10n.countdownSecondsSuffix)"
        shortcutTitleLabel?.stringValue = L10n.shortcutHeader
        shortcutRestoreButton?.toolTip = L10n.shortcutRestore
        fullScreenScreenshotShortcutTitleLabel?.stringValue = L10n.fullScreenScreenshotShortcutHeader
        fullScreenScreenshotShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        colorPickerShortcutTitleLabel?.stringValue = L10n.colorPickerShortcutHeader
        colorPickerShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        selectedImagePinShortcutTitleLabel?.stringValue = L10n.selectedImagePinShortcutHeader
        selectedImagePinShortcutRestoreButton?.toolTip = L10n.selectedImagePinShortcutClear
        clipboardImagePinShortcutTitleLabel?.stringValue = L10n.clipboardImagePinShortcutHeader
        clipboardImagePinShortcutRestoreButton?.toolTip = L10n.clipboardImagePinShortcutClear
        selectedImageEditShortcutTitleLabel?.stringValue = L10n.selectedImageEditShortcutHeader
        selectedImageEditShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        clipboardImageEditShortcutTitleLabel?.stringValue = L10n.clipboardImageEditShortcutHeader
        clipboardImageEditShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        textRecognitionShortcutTitleLabel?.stringValue = L10n.textRecognitionShortcutHeader
        textRecognitionShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        copyImageTextShortcutTitleLabel?.stringValue = L10n.copyImageTextShortcutHeader
        copyImageTextShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        screenshotTranslationShortcutTitleLabel?.stringValue = L10n.screenshotTranslationShortcutHeader
        screenshotTranslationShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        recordShortcutTitleLabel?.stringValue = L10n.recordShortcutHeader
        recordShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        imageMergeShortcutTitleLabel?.stringValue = L10n.imageMergeShortcutHeader
        imageMergeShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        clipboardShortcutTitleLabel?.stringValue = L10n.clipboardShortcutHeader
        clipboardShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        fileSaveShortcutTitleLabel?.stringValue = L10n.fileSaveShortcutHeader
        fileSaveShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        previousHistoryImageShortcutTitleLabel?.stringValue = L10n.previousHistoryImageShortcutHeader
        previousHistoryImageShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        nextHistoryImageShortcutTitleLabel?.stringValue = L10n.nextHistoryImageShortcutHeader
        nextHistoryImageShortcutRestoreButton?.toolTip = L10n.shortcutRestore
        shortcutResetButton?.title = L10n.toolbarSettingsReset
        aboutTaglineLabel?.stringValue = L10n.aboutTagline
        aboutLicenseTitleLabel?.stringValue = L10n.aboutLicense
        aboutSourceTitleLabel?.stringValue = L10n.aboutSourceCode
        aboutStarTitleLabel?.stringValue = L10n.aboutStarOnGitHub
        aboutFeatureRequestTitleLabel?.stringValue = L10n.aboutFeatureRequest
        aboutBugReportTitleLabel?.stringValue = L10n.aboutBugReport
        aboutUpdateTitleLabel?.stringValue = L10n.aboutUpdateTitle
        errorLogTitleLabel?.stringValue = L10n.aboutErrorLog
        errorLogCopyButton?.title = L10n.aboutErrorLogCopy
        errorLogRevealButton?.title = L10n.aboutErrorLogReveal
        errorLogRefreshButton?.title = L10n.aboutErrorLogRefresh
        errorLogClearButton?.title = L10n.aboutErrorLogClear
        if errorLogLoaded, errorLogEntry == nil {
            errorLogTextView?.string = L10n.aboutErrorLogEmptyBody
        }
        refreshErrorLogStatus()
        refreshUpdateRow()
        refreshShortcutDisplay()
        refreshFullScreenScreenshotShortcutDisplay()
        refreshColorPickerShortcutDisplay()
        refreshSelectedImagePinShortcutDisplay()
        refreshClipboardImagePinShortcutDisplay()
        refreshSelectedImageEditShortcutDisplay()
        refreshClipboardImageEditShortcutDisplay()
        refreshTextRecognitionShortcutDisplay()
        refreshCopyImageTextShortcutDisplay()
        refreshScreenshotTranslationShortcutDisplay()
        refreshRecordShortcutDisplay()
        refreshImageMergeShortcutDisplay()
        refreshClipboardShortcutDisplay()
        refreshFileSaveShortcutDisplay()
        refreshPreviousHistoryImageShortcutDisplay()
        refreshNextHistoryImageShortcutDisplay()
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

// MARK: - Settings tick slider

private final class SettingsTickSlider: NSControl {
    var minValue: Double
    var maxValue: Double
    var stepValue: Double
    var numberOfTickMarks: Int

    override var doubleValue: Double {
        get { value }
        set { setValue(newValue, notify: false) }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isDragging = false
            }
            needsDisplay = true
        }
    }

    private var value: Double
    private var isDragging = false {
        didSet { needsDisplay = true }
    }

    private let knobSize = NSSize(width: 9, height: 18)
    private let trackHeight: CGFloat = 3.5
    private let tickDiameter: CGFloat = 2.5
    private let tickGap: CGFloat = 5
    private let accentColor = NSColor(
        calibratedRed: 0x11 / 255.0,
        green: 0x7D / 255.0,
        blue: 0xFF / 255.0,
        alpha: 1.0
    )

    init(
        frame: NSRect = .zero,
        value: Double,
        minValue: Double,
        maxValue: Double,
        stepValue: Double,
        numberOfTickMarks: Int,
        target: AnyObject?,
        action: Selector?
    ) {
        self.minValue = minValue
        self.maxValue = maxValue
        self.stepValue = stepValue
        self.numberOfTickMarks = max(0, numberOfTickMarks)
        self.value = Self.normalizedValue(
            value,
            minValue: minValue,
            maxValue: maxValue,
            stepValue: stepValue
        )
        super.init(frame: frame)
        self.target = target
        self.action = action
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

    override func draw(_ dirtyRect: NSRect) {
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.35
        let trackRect = NSRect(
            x: 0,
            y: floor(bounds.midY - trackHeight / 2),
            width: bounds.width,
            height: trackHeight
        )
        let travelRect = NSRect(
            x: knobSize.width / 2,
            y: trackRect.minY,
            width: max(1, bounds.width - knobSize.width),
            height: trackRect.height
        )

        let trackPath = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight / 2,
            yRadius: trackHeight / 2
        )
        NSColor.white.withAlphaComponent(0.15 * enabledAlpha).setFill()
        trackPath.fill()

        let knobCenterX = travelRect.minX + normalizedFraction * travelRect.width
        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: max(0, knobCenterX - trackRect.minX),
            height: trackRect.height
        )
        if fillRect.width > 0 {
            let fillPath = NSBezierPath(
                roundedRect: fillRect,
                xRadius: trackHeight / 2,
                yRadius: trackHeight / 2
            )
            accentColor.withAlphaComponent(enabledAlpha).setFill()
            fillPath.fill()
        }

        drawKnob(centerX: knobCenterX, enabledAlpha: enabledAlpha)
        drawTickMarks(in: travelRect, enabledAlpha: enabledAlpha)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isDragging = true
        updateValue(with: event, notify: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        updateValue(with: event, notify: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            isDragging = false
            return
        }
        updateValue(with: event, notify: true)
        isDragging = false
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let step = stepValue > 0 ? stepValue : (maxValue - minValue) / 10
        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_DownArrow:
            setValue(value - step, notify: true)
        case kVK_RightArrow, kVK_UpArrow:
            setValue(value + step, notify: true)
        default:
            super.keyDown(with: event)
        }
    }

    private var normalizedFraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((value - minValue) / (maxValue - minValue))
    }

    private func drawTickMarks(in trackRect: NSRect, enabledAlpha: CGFloat) {
        guard numberOfTickMarks > 1 else { return }
        let dotY = trackRect.minY - tickGap - tickDiameter
        for index in 0..<numberOfTickMarks {
            let fraction = CGFloat(index) / CGFloat(numberOfTickMarks - 1)
            let x = trackRect.minX + fraction * trackRect.width
            let tickRect = NSRect(
                x: x - tickDiameter / 2,
                y: dotY,
                width: tickDiameter,
                height: tickDiameter
            )
            NSColor.white.withAlphaComponent(0.24 * enabledAlpha).setFill()
            NSBezierPath(ovalIn: tickRect).fill()
        }
    }

    private func drawKnob(centerX: CGFloat, enabledAlpha: CGFloat) {
        let knobRect = NSRect(
            x: centerX - knobSize.width / 2,
            y: bounds.midY - knobSize.height / 2,
            width: knobSize.width,
            height: knobSize.height
        )
        let knobPath = NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobSize.width / 2,
            yRadius: knobSize.width / 2
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18 * enabledAlpha)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor(white: isDragging ? 0.88 : 0.78, alpha: enabledAlpha).setFill()
        knobPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.18 * enabledAlpha).setStroke()
        knobPath.lineWidth = 0.5
        knobPath.stroke()
    }

    private func updateValue(with event: NSEvent, notify: Bool) {
        guard bounds.width > knobSize.width else { return }
        let location = convert(event.locationInWindow, from: nil)
        let trackMinX = knobSize.width / 2
        let trackWidth = max(1, bounds.width - knobSize.width)
        let fraction = min(max((location.x - trackMinX) / trackWidth, 0), 1)
        let newValue = minValue + Double(fraction) * (maxValue - minValue)
        setValue(newValue, notify: notify)
    }

    private func setValue(_ newValue: Double, notify: Bool) {
        let normalized = Self.normalizedValue(
            newValue,
            minValue: minValue,
            maxValue: maxValue,
            stepValue: stepValue
        )
        value = normalized
        needsDisplay = true
        if notify {
            sendAction(action, to: target)
        }
    }

    private static func normalizedValue(
        _ rawValue: Double,
        minValue: Double,
        maxValue: Double,
        stepValue: Double
    ) -> Double {
        let clamped = min(max(rawValue, minValue), maxValue)
        guard stepValue > 0 else { return clamped }
        let steps = ((clamped - minValue) / stepValue).rounded()
        let snapped = minValue + steps * stepValue
        return min(max(snapped, minValue), maxValue)
    }
}

// MARK: - Card view

/// Live preview of the window-capture shadow: a small window-like card
/// floating on a desktop-like backdrop. The shadow scales with `shadowSize`
/// so the user sees how high the captured window will appear to float.
private final class ShadowPreviewView: NSView {
    var shadowSize: CGFloat = 22 { didSet { needsDisplay = true } }
    var isEffectEnabled: Bool = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let backdrop = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        backdrop.addClip()

        // Desktop-like light backdrop so the dark shadow stays visible
        // (the settings UI itself is dark).
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.74, green: 0.78, blue: 0.85, alpha: 1),
            NSColor(calibratedRed: 0.60, green: 0.64, blue: 0.72, alpha: 1)
        ])
        gradient?.draw(in: bounds, angle: -90)

        // Window card geometry, centered; floats higher as the shadow grows.
        let cardW = min(bounds.width * 0.56, 210)
        let cardH: CGFloat = 64
        let lift = isEffectEnabled ? min(shadowSize, 60) * 0.10 : 0
        let cardRect = NSRect(
            x: ((bounds.width - cardW) / 2).rounded(),
            y: ((bounds.height - cardH) / 2 + lift).rounded(),
            width: cardW,
            height: cardH
        )
        let radius: CGFloat = 9
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)

        guard let ctx = NSGraphicsContext.current else { return }

        // Shadow pass. Scaled down relative to the real export — the preview
        // card is tiny — but proportional, so the slider's effect reads.
        ctx.saveGraphicsState()
        if isEffectEnabled, shadowSize > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
            shadow.shadowBlurRadius = shadowSize * 0.62
            shadow.shadowOffset = NSSize(width: 0, height: -shadowSize * 0.30)
            shadow.set()
        }
        NSColor.white.setFill()
        cardPath.fill()
        ctx.restoreGraphicsState()

        // Title-bar strip + traffic-light dots, clipped to the card.
        ctx.saveGraphicsState()
        cardPath.addClip()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(
            x: cardRect.minX, y: cardRect.maxY - 16,
            width: cardRect.width, height: 16
        )).fill()
        let dotColors: [NSColor] = [
            NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.35, alpha: 1),
            NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(calibratedRed: 0.31, green: 0.79, blue: 0.31, alpha: 1)
        ]
        for (i, color) in dotColors.enumerated() {
            color.setFill()
            let d: CGFloat = 7
            NSBezierPath(ovalIn: NSRect(
                x: cardRect.minX + 9 + CGFloat(i) * 12,
                y: cardRect.maxY - 11.5, width: d, height: d
            )).fill()
        }
        ctx.restoreGraphicsState()

        // Hairline border for crispness.
        NSColor.black.withAlphaComponent(0.08).setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()
    }
}

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
        let color: NSColor = granted ? .systemGreen : .systemOrange
        label.stringValue = granted ? L10n.permissionGranted : L10n.permissionNotGranted
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
