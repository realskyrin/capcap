import AppKit

/// 图床配置卡片，放在设置的上传页中
final class UploadSettingsPane: NSView {
    private var defaultBadges: [UploadProviderKind: DefaultProviderBadge] = [:]
    private var setDefaultButtons: [UploadProviderKind: NSButton] = [:]
    private var providerCards: [UploadProviderKind: ProviderCard] = [:]
    private let markdownSwitch = NSSwitch()
    private let markdownTitleLabel = NSTextField(labelWithString: "")
    private let markdownSubtitleLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onProvidersChanged),
            name: .uploadProvidersDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onLanguageChanged),
            name: .languageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let markdownCard = buildMarkdownCard()
        stack.addArrangedSubview(markdownCard)
        markdownCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for kind in UploadProviderKind.allCases {
            let card = ProviderCard(kind: kind, fields: Self.fields(for: kind))
            card.translatesAutoresizingMaskIntoConstraints = false
            card.onSetDefault = { [weak self] k in self?.setDefault(k) }
            providerCards[kind] = card
            defaultBadges[kind] = card.defaultBadge
            setDefaultButtons[kind] = card.setDefaultButton
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])

        refreshDefaultIndicators()
    }

    /// Card with the "copy as Markdown link" switch, shown above the provider
    /// cards. Controls whether a successful upload copies `![](url)` or a raw URL.
    private func buildMarkdownCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.layer?.borderWidth = 1

        markdownTitleLabel.stringValue = L10n.uploadMarkdownToggleTitle
        markdownTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        markdownTitleLabel.textColor = NSColor.white.withAlphaComponent(0.94)

        markdownSubtitleLabel.stringValue = L10n.uploadMarkdownToggleSubtitle
        markdownSubtitleLabel.font = NSFont.systemFont(ofSize: 11)
        markdownSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        markdownSubtitleLabel.maximumNumberOfLines = 0
        // Let the label wrap to the card width instead of widening the window.
        markdownSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [markdownTitleLabel, markdownSubtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        markdownSwitch.controlSize = .small
        markdownSwitch.state = Defaults.copyUploadAsMarkdown ? .on : .off
        markdownSwitch.target = self
        markdownSwitch.action = #selector(markdownSwitchToggled)
        markdownSwitch.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(textStack)
        card.addSubview(markdownSwitch)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            textStack.trailingAnchor.constraint(equalTo: markdownSwitch.leadingAnchor, constant: -12),

            markdownSwitch.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            markdownSwitch.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),

            // Pin the wrapping subtitle to the stack's definite width so it
            // wraps to multiple lines instead of forcing the window wider.
            markdownSubtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])
        return card
    }

    @objc private func markdownSwitchToggled() {
        Defaults.copyUploadAsMarkdown = markdownSwitch.state == .on
    }

    private func setDefault(_ kind: UploadProviderKind) {
        // Persist whatever the user has typed before flipping the default.
        providerCards[kind]?.persistFields()
        Defaults.defaultUploadProviderKind = kind
        refreshDefaultIndicators()
    }

    /// Wipes the in-memory log of every card. Called by SettingsView when the
    /// user navigates away from the Upload tab.
    func clearLogs() {
        for card in providerCards.values { card.clearLogs() }
    }

    @objc private func onProvidersChanged() {
        refreshDefaultIndicators()
    }

    @objc private func onLanguageChanged() {
        markdownTitleLabel.stringValue = L10n.uploadMarkdownToggleTitle
        markdownSubtitleLabel.stringValue = L10n.uploadMarkdownToggleSubtitle
        for (kind, card) in providerCards {
            card.refreshLocalization(fields: Self.fields(for: kind))
        }
    }

    private func refreshDefaultIndicators() {
        let current = Defaults.defaultUploadProviderKind
        for kind in UploadProviderKind.allCases {
            let isDefault = kind == current
            defaultBadges[kind]?.isHidden = !isDefault
            let usable = ProviderConfigStore.isUsable(kind: kind)
            setDefaultButtons[kind]?.isEnabled = usable && !isDefault
            setDefaultButtons[kind]?.alphaValue = (usable && !isDefault) ? 1.0 : 0.5
        }
    }

    fileprivate static func fields(for kind: UploadProviderKind) -> [ProviderField] {
        switch kind {
        case .tencent:
            return [
                .init(key: "secretId",  label: "SecretId",  placeholder: "AKIDxxxxxxxx", secure: false),
                .init(key: "secretKey", label: "SecretKey", placeholder: "********",     secure: true),
                .init(key: "bucket",    label: L10n.uploadFieldBucket,
                      placeholder: "examplebucket-1250000000", secure: false),
                .init(key: "region",    label: L10n.uploadFieldRegion,
                      placeholder: "ap-shanghai", secure: false),
                .init(key: "path",      label: L10n.uploadFieldPathOptional,
                      placeholder: "screenshots", secure: false),
                .init(key: "customUrl", label: L10n.uploadFieldCustomUrlOptional,
                      placeholder: "https://cdn.example.com", secure: false),
            ]
        case .qiniu:
            return [
                .init(key: "accessKey", label: "AccessKey", placeholder: "********", secure: false),
                .init(key: "secretKey", label: "SecretKey", placeholder: "********", secure: true),
                .init(key: "bucket",    label: L10n.uploadFieldBucketSpace,
                      placeholder: "my-bucket", secure: false),
                .init(key: "domain",    label: L10n.uploadFieldPublicDomain,
                      placeholder: "https://cdn.example.com", secure: false),
                .init(key: "region",    label: L10n.uploadFieldRegionOptional,
                      placeholder: "z0 / z1 / z2 / na0 / as0 / cn-east-2", secure: false),
                .init(key: "path",      label: L10n.uploadFieldPathOptional,
                      placeholder: "screenshots", secure: false),
            ]
        case .aliyun:
            return [
                .init(key: "accessKeyId",     label: "AccessKey Id",     placeholder: "LTAIxxxxxxx",  secure: false),
                .init(key: "accessKeySecret", label: "AccessKey Secret", placeholder: "********",     secure: true),
                .init(key: "bucket",          label: L10n.uploadFieldBucket,
                      placeholder: "my-bucket", secure: false),
                .init(key: "area",            label: L10n.uploadFieldEndpointArea,
                      placeholder: "oss-cn-hangzhou", secure: false),
                .init(key: "path",            label: L10n.uploadFieldPathOptional,
                      placeholder: "screenshots", secure: false),
                .init(key: "customUrl",       label: L10n.uploadFieldCustomUrlOptional,
                      placeholder: "https://cdn.example.com", secure: false),
            ]
        case .s3:
            return [
                .init(key: "accessKeyId",     label: "Access Key ID",     placeholder: "AKIAxxxxxxxx", secure: false),
                .init(key: "secretAccessKey", label: "Secret Access Key", placeholder: "********",      secure: true),
                .init(key: "bucket",          label: L10n.uploadFieldBucket,
                      placeholder: "my-bucket", secure: false),
                .init(key: "region",          label: L10n.uploadFieldRegion,
                      placeholder: "us-east-1", secure: false),
                .init(key: "endpoint",        label: L10n.uploadFieldEndpointOptional,
                      placeholder: "minio.example.com", secure: false),
                .init(key: "path",            label: L10n.uploadFieldPathOptional,
                      placeholder: "screenshots", secure: false),
                .init(key: "customUrl",       label: L10n.uploadFieldCustomUrlOptional,
                      placeholder: "https://cdn.example.com", secure: false),
            ]
        case .r2:
            return [
                .init(key: "accessKeyId",     label: "Access Key ID",     placeholder: "********", secure: false),
                .init(key: "secretAccessKey", label: "Secret Access Key", placeholder: "********", secure: true),
                .init(key: "accountId",       label: L10n.uploadFieldAccountId,
                      placeholder: "Cloudflare Account ID", secure: false),
                .init(key: "bucket",          label: L10n.uploadFieldBucket,
                      placeholder: "my-bucket", secure: false),
                .init(key: "path",            label: L10n.uploadFieldPathOptional,
                      placeholder: "screenshots", secure: false),
                .init(key: "customUrl",       label: L10n.uploadFieldCustomUrlOptional,
                      placeholder: "https://img.example.com", secure: false),
            ]
        case .custom:
            return [
                .init(key: "ziplineURL", label: L10n.uploadFieldCustomSiteURL,
                      placeholder: "https://zipline.example.com", secure: false),
                .init(key: "ziplineToken", label: L10n.uploadFieldCustomToken,
                      placeholder: "Token", secure: true),
                .init(key: "easyImagesURL", label: L10n.uploadFieldCustomSiteURL,
                      placeholder: "https://images.example.com", secure: false),
                .init(key: "easyImagesToken", label: L10n.uploadFieldCustomToken,
                      placeholder: "Token", secure: true),
                .init(key: "endpoint",    label: L10n.uploadFieldCustomEndpoint,
                      placeholder: "https://img.example.com/api/upload", secure: false),
                .init(key: "fileField",   label: L10n.uploadFieldCustomFileField,
                      placeholder: "file", secure: false),
                .init(key: "headers",     label: L10n.uploadFieldCustomHeadersOptional,
                      placeholder: "Authorization: Bearer token", secure: true),
                .init(key: "formFields", label: L10n.uploadFieldCustomFormFields,
                      placeholder: "token=your_token", secure: true),
                .init(key: "responsePath", label: L10n.uploadFieldCustomResponsePathOptional,
                      placeholder: "data.url", secure: false),
            ]
        }
    }
}

// MARK: - Field model

private struct ProviderField {
    let key: String
    let label: String
    let placeholder: String
    let secure: Bool
}

/// Required field keys per provider, used to compute "missing fields" for the
/// log line before the provider's own validate() runs.
private func requiredKeys(for kind: UploadProviderKind) -> [String] {
    switch kind {
    case .tencent: return ["secretId", "secretKey", "bucket", "region"]
    case .qiniu:   return ["accessKey", "secretKey", "bucket", "domain"]
    case .aliyun:  return ["accessKeyId", "accessKeySecret", "bucket", "area"]
    case .s3:      return ["accessKeyId", "secretAccessKey", "bucket", "region"]
    case .r2:      return ["accessKeyId", "secretAccessKey", "accountId", "bucket"]
    // 自定义配置允许先保存空白草稿，必需的网络参数只在测试或上传时校验
    case .custom:  return []
    }
}

// MARK: - Validation status

private enum TestStatus {
    case untested
    case testing
    case valid
    case invalid

    var title: String {
        switch self {
        case .untested: return L10n.uploadStatusUntested
        case .testing:  return L10n.uploadStatusTesting
        case .valid:    return L10n.uploadStatusValid
        case .invalid:  return L10n.uploadStatusInvalid
        }
    }

    var color: NSColor {
        switch self {
        case .untested: return NSColor.secondaryLabelColor
        case .testing:  return NSColor.systemBlue
        case .valid:    return NSColor.systemGreen
        case .invalid:  return NSColor.systemOrange
        }
    }
}

// MARK: - Per-provider card

private final class ProviderCard: NSView {
    let kind: UploadProviderKind
    let defaultBadge = DefaultProviderBadge()
    let setDefaultButton = NSButton(title: L10n.uploadSetDefaultButton, target: nil, action: nil)
    let enableSwitch = NSSwitch()

    var onSetDefault: ((UploadProviderKind) -> Void)?

    private let fields: [ProviderField]
    private var inputs: [String: any ProviderFieldInput] = [:]
    private var fieldLabels: [String: NSTextField] = [:]
    private var fieldRows: [String: NSView] = [:]
    private let presetPopup = NSPopUpButton()
    private let presetLabel = NSTextField(labelWithString: "")
    private let customHint = NSTextField(wrappingLabelWithString: "")
    private var customPreset: CustomUploadPreset
    private let titleLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let testButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let statusPill = StatusPill()
    private let logView = LogView()
    private let bodyContainer = ClippingView()
    private var bodyStack: NSStackView!
    private var bodyHeightConstraint: NSLayoutConstraint!
    private var measuredBodyHeight: CGFloat = 0
    private var isExpanded: Bool
    private var status: TestStatus = .untested {
        didSet { statusPill.apply(status) }
    }
    private var pendingTestToken: UUID?

    init(kind: UploadProviderKind, fields: [ProviderField]) {
        self.kind = kind
        self.fields = fields
        self.customPreset = ProviderConfigStore.load(kind: kind).map {
            CustomUploadPreset.selected(in: $0)
        } ?? .zipline
        self.isExpanded = ProviderConfigStore.isEnabled(kind: kind)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        buildUI()
        loadFromStore()
        enableSwitch.state = isExpanded ? .on : .off
        bodyContainer.alphaValue = isExpanded ? 1 : 0
        statusPill.apply(.untested)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        let header = buildHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true
        addSubview(bodyContainer)

        bodyStack = buildBodyStack()
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(bodyStack)

        bodyHeightConstraint = bodyContainer.heightAnchor.constraint(equalToConstant: 0)
        bodyHeightConstraint.priority = .required
        bodyHeightConstraint.isActive = true

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            bodyContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            bodyStack.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            // Bottom anchored at lower priority so the height constraint can collapse it.
            {
                let c = bodyStack.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
                c.priority = .defaultHigh
                return c
            }(),
        ])
    }

    private func buildHeader() -> NSView {
        titleLabel.stringValue = kind.displayName
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        defaultBadge.stringValue = L10n.uploadCurrentDefault
        defaultBadge.isHidden = true

        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(switchToggled)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, defaultBadge, spacer(), enableSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            defaultBadge.heightAnchor.constraint(equalToConstant: 16),
            defaultBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        return header
    }

    private func buildBodyStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        if kind == .custom {
            presetLabel.stringValue = L10n.uploadPresetLabel
            presetLabel.font = .systemFont(ofSize: 11)
            presetLabel.textColor = NSColor.white.withAlphaComponent(0.74)
            presetLabel.alignment = .right
            presetLabel.widthAnchor.constraint(equalToConstant: 144).isActive = true
            presetPopup.addItems(withTitles: CustomUploadPreset.allCases.map(\.displayName))
            presetPopup.selectItem(at: CustomUploadPreset.allCases.firstIndex(of: customPreset) ?? 0)
            presetPopup.target = self
            presetPopup.action = #selector(presetChanged)
            let row = NSStackView(views: [presetLabel, presetPopup])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            presetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }

        for f in fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: f.label)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = NSColor.white.withAlphaComponent(0.74)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 144).isActive = true
            row.addArrangedSubview(label)
            fieldLabels[f.key] = label

            let input: any ProviderFieldInput = f.secure
                ? RevealableSecureField(multiline: f.key == "headers" || f.key == "formFields")
                : PasteableTextField()
            input.placeholderString = f.placeholder
            input.font = NSFont.systemFont(ofSize: 12)
            input.translatesAutoresizingMaskIntoConstraints = false
            inputs[f.key] = input
            row.addArrangedSubview(input)

            stack.addArrangedSubview(row)
            fieldRows[f.key] = row
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }

        if kind == .custom {
            customHint.font = .systemFont(ofSize: 11)
            customHint.textColor = NSColor.white.withAlphaComponent(0.55)
            customHint.maximumNumberOfLines = 0
            customHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(customHint)
            customHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            updateCustomFields()
        }

        // Footer: status pill (bottom-left) + buttons (bottom-right).
        saveButton.title = L10n.uploadSaveButton
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small

        testButton.title = L10n.uploadTestUploadButton
        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small

        clearButton.title = L10n.uploadClearButton
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small

        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.controlSize = .small
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setDefaultTapped)

        // 自定义卡片多一个测试按钮，分行放置以免长语言文案挤宽设置窗口
        if kind == .custom {
            stack.addArrangedSubview(statusPill)
            let actions = NSStackView(views: [clearButton, saveButton, testButton])
            actions.orientation = .horizontal
            actions.spacing = 8
            stack.addArrangedSubview(actions)
        }
        let footer = NSStackView(views: kind == .custom
            ? [spacer(), setDefaultButton]
            : [statusPill, spacer(), clearButton, saveButton, setDefaultButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Log area at the very bottom.
        stack.addArrangedSubview(logView)
        logView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        logView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        return stack
    }

    override func layout() {
        super.layout()
        if measuredBodyHeight == 0, bounds.width > 0 {
            bodyHeightConstraint.isActive = false
            bodyContainer.layoutSubtreeIfNeeded()
            let measured = bodyContainer.fittingSize.height
            measuredBodyHeight = measured
            bodyHeightConstraint.isActive = true
            bodyHeightConstraint.constant = isExpanded ? measured : 0
        }
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func loadFromStore() {
        guard let cfg = ProviderConfigStore.load(kind: kind) else { return }
        for (k, field) in inputs {
            field.stringValue = cfg.fields[k] ?? ""
        }
    }

    private func updateCustomFields() {
        guard kind == .custom else { return }
        let visibleKeys: Set<String>
        switch customPreset {
        case .zipline: visibleKeys = ["ziplineURL", "ziplineToken"]
        case .easyImages: visibleKeys = ["easyImagesURL", "easyImagesToken"]
        case .other: visibleKeys = ["endpoint", "fileField", "headers", "formFields", "responsePath"]
        }
        for (key, row) in fieldRows {
            row.isHidden = !visibleKeys.contains(key)
        }
        customHint.stringValue = customPreset == .other
            ? L10n.uploadCustomOtherHint : L10n.uploadCustomPresetHint
        // 预设字段数不同，切换时重新计算卡片高度，避免隐藏字段留下空白
        bodyStack?.needsLayout = true
        bodyContainer.needsLayout = true
        measuredBodyHeight = 0
        needsLayout = true
    }

    @objc private func presetChanged() {
        let index = presetPopup.indexOfSelectedItem
        guard CustomUploadPreset.allCases.indices.contains(index) else { return }
        customPreset = CustomUploadPreset.allCases[index]
        updateCustomFields()
        // 各预设使用独立字段，切换图床不会清空另一套地址或 Token
        persistFields()
        pendingTestToken = nil
        status = .untested
        logView.clear()
    }

    /// Force the current text-field values into UserDefaults without touching the
    /// status label. Used right before flipping the default so freshly typed
    /// values count as "saved".
    func persistFields() {
        var dict: [String: String] = [:]
        for (k, field) in inputs {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { dict[k] = v }
        }
        if kind == .custom { dict["preset"] = customPreset.rawValue }
        ProviderConfigStore.save(ProviderConfig(kind: kind, fields: dict))
    }

    private func hasMissingRequiredFields() -> Bool {
        requiredKeys(for: kind).contains { key in
            guard let value = inputs[key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return true
            }
            return value.isEmpty
        }
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        if measuredBodyHeight == 0 {
            bodyHeightConstraint.isActive = false
            bodyContainer.layoutSubtreeIfNeeded()
            measuredBodyHeight = bodyContainer.fittingSize.height
            bodyHeightConstraint.isActive = true
        }
        let target: CGFloat = expanded ? measuredBodyHeight : 0
        let alpha: CGFloat = expanded ? 1 : 0
        let updates = {
            self.bodyHeightConstraint.constant = target
            self.bodyContainer.alphaValue = alpha
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                updates()
            }
        } else {
            updates()
        }
    }

    @objc private func switchToggled() {
        let on = enableSwitch.state == .on
        ProviderConfigStore.setEnabled(on, kind: kind)
        if on {
            if kind == .custom {
                setExpanded(true, animated: true)
                persistFields()
                pendingTestToken = nil
                status = .untested
                return
            }
            if hasMissingRequiredFields() {
                setExpanded(true, animated: true)
            }
            runValidation()
        } else {
            // Cancel any in-flight test result so it doesn't paint a stale state.
            pendingTestToken = nil
            status = .untested
            logView.append(.info, L10n.uploadLogProviderDisabled)
            setExpanded(false, animated: true)
        }
    }

    @objc private func toggleExpanded() {
        setExpanded(!isExpanded, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        toggleExpanded()
    }

    // Forward clicks on inert chrome (labels, spacers, status pill) to the card
    // itself so any spot on the card toggles expansion. Real controls — the
    // enable switch, enabled buttons, editable text fields, the log scroll area
    // — keep their own click handling.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if let result, isPassThrough(result) { return self }
        return result
    }

    private func isPassThrough(_ view: NSView) -> Bool {
        if view === self { return false }
        var v: NSView? = view
        while let cur = v, cur !== self {
            if cur is NSSwitch { return false }
            if let btn = cur as? NSButton, btn.isEnabled { return false }
            if let tf = cur as? NSTextField, tf.isEditable { return false }
            if cur is NSTextView { return false }
            if cur is NSScrollView { return false }
            v = cur.superview
        }
        return true
    }

    @objc private func saveTapped() {
        persistFields()
        logView.append(.info, L10n.uploadLogConfigSaved)
        if kind == .custom {
            // 保存草稿不发起网络请求，完整性校验交给显式测试或实际上传
            pendingTestToken = nil
            status = .untested
            return
        }
        runValidation()
    }

    @objc private func testTapped() {
        runValidation()
    }

    @objc private func clearTapped() {
        for (_, field) in inputs { field.stringValue = "" }
        ProviderConfigStore.clear(kind: kind)
        if Defaults.defaultUploadProviderKind == kind {
            Defaults.defaultUploadProviderKind = nil
        }
        pendingTestToken = nil
        status = .untested
        logView.append(.info, L10n.uploadLogConfigCleared)
    }

    @objc private func setDefaultTapped() {
        onSetDefault?(kind)
    }

    func clearLogs() {
        logView.clear()
    }

    /// Re-renders all language-bound text without rebuilding the view tree, so
    /// switching app language while the Upload tab is mounted updates labels
    /// in place. Field placeholders are intentionally fixed strings.
    func refreshLocalization(fields: [ProviderField]) {
        titleLabel.stringValue = kind.displayName
        defaultBadge.stringValue = L10n.uploadCurrentDefault
        setDefaultButton.title = L10n.uploadSetDefaultButton
        saveButton.title = L10n.uploadSaveButton
        testButton.title = L10n.uploadTestUploadButton
        clearButton.title = L10n.uploadClearButton
        for f in fields {
            fieldLabels[f.key]?.stringValue = f.label
        }
        if kind == .custom {
            presetLabel.stringValue = L10n.uploadPresetLabel
            presetPopup.removeAllItems()
            presetPopup.addItems(withTitles: CustomUploadPreset.allCases.map(\.displayName))
            presetPopup.selectItem(at: CustomUploadPreset.allCases.firstIndex(of: customPreset) ?? 0)
            updateCustomFields()
        }
        statusPill.apply(status)
    }

    /// 显式测试会先保存配置，再校验并上传一张测试图片
    private func runValidation() {
        pendingTestToken = nil
        persistFields()
        let cfg = ProviderConfigStore.load(kind: kind) ?? ProviderConfig(kind: kind, fields: [:])

        let missing = requiredKeys(for: kind).filter { cfg.nonEmpty($0) == nil }
        if !missing.isEmpty {
            status = .invalid
            logView.append(.error, L10n.uploadLogMissingFields(missing))
            return
        }
        if let err = Uploaders.provider(for: kind).validate(cfg) {
            status = .invalid
            logView.append(.error, err)
            return
        }

        guard let png = Self.tinyTestPNG() else {
            status = .invalid
            logView.append(.error, L10n.uploadTestImageFailed)
            return
        }

        status = .testing
        logView.append(.info, L10n.uploadLogStartingTest)
        let token = UUID()
        pendingTestToken = token

        Uploaders.provider(for: kind).upload(
            data: png,
            fileName: "capcap-config-test.png",
            contentType: "image/png",
            config: cfg,
            progress: { _ in }
        ) { [weak self] result in
            guard let self else { return }
            // Drop late results from a superseded run.
            guard self.pendingTestToken == token else { return }
            self.pendingTestToken = nil
            switch result {
            case .success(let url):
                self.status = .valid
                self.logView.append(.success, L10n.uploadLogTestSucceeded(url.absoluteString))
            case .failure(let err):
                self.status = .invalid
                self.logView.append(.error, L10n.uploadLogTestFailed(err.localizedDescription))
            }
        }
    }

    /// Tiny 1×1 transparent PNG (~70 bytes). Generated on demand so the bundle
    /// stays free of binary blobs.
    private static func tinyTestPNG() -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        return rep?.representation(using: .png, properties: [:])
    }
}

// MARK: - Default provider badge

private final class DefaultProviderBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    var stringValue: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous

        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor.systemGreen
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: ceil(labelSize.width) + 16, height: 16)
    }
}

// MARK: - Status pill

private final class StatusPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ status: TestStatus) {
        let color = status.color
        label.stringValue = status.title
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        dot.layer?.backgroundColor = color.cgColor
    }
}

// MARK: - Log view

private enum LogLevel {
    case info, success, error

    var color: NSColor {
        switch self {
        case .info:    return NSColor.white.withAlphaComponent(0.78)
        case .success: return NSColor.systemGreen
        case .error:   return NSColor.systemOrange
        }
    }
}

private final class LogView: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.78)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func append(_ level: LogLevel, _ message: String) {
        let ts = formatter.string(from: Date())
        let prefix = "[\(ts)] "
        let storage = textView.textStorage
        let leadingNewline = (storage?.length ?? 0) > 0 ? "\n" : ""

        let prefixAttr = NSAttributedString(
            string: leadingNewline + prefix,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ]
        )
        let bodyAttr = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: level.color,
            ]
        )
        storage?.append(prefixAttr)
        storage?.append(bodyAttr)
        textView.scrollRangeToVisible(NSRange(location: storage?.length ?? 0, length: 0))
    }
}

/// NSView subclass that flips clipping on so collapsed body content doesn't
/// bleed past the card's rounded corners during animation.
private final class ClippingView: NSView {
    override var wantsDefaultClipping: Bool { true }
}

// MARK: - Provider field input

/// Common surface for the row's input view so secret rows (with reveal toggle)
/// and plain rows can both live in the same `inputs` map.
protocol ProviderFieldInput: NSView {
    var stringValue: String { get set }
    var placeholderString: String? { get set }
    var font: NSFont? { get set }
}

extension NSTextField: ProviderFieldInput {}

/// Secure input that shows a small eye button on the right; clicking it swaps
/// to a plain field so the user can read back the value they typed.
final class RevealableSecureField: NSView, ProviderFieldInput, NSTextFieldDelegate {
    private let secureField = PasteableSecureTextField()
    private let plainField = PasteableTextField()
    private let toggleButton = NSButton()
    private var isRevealed = false
    private let multiline: Bool

    var stringValue: String {
        get { (isRevealed ? plainField : secureField).stringValue }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    var placeholderString: String? {
        get { secureField.placeholderString }
        set {
            secureField.placeholderString = newValue
            plainField.placeholderString = newValue
        }
    }

    var font: NSFont? {
        get { secureField.font }
        set {
            secureField.font = newValue
            plainField.font = newValue
        }
    }

    init(multiline: Bool = false) {
        self.multiline = multiline
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for f in [secureField, plainField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.delegate = self
            if multiline {
                f.usesSingleLineMode = false
                f.cell?.isScrollable = false
                f.cell?.wraps = true
                f.lineBreakMode = .byWordWrapping
                f.maximumNumberOfLines = 0
            }
            addSubview(f)
        }
        plainField.isHidden = true

        toggleButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show secret")
        toggleButton.imagePosition = .imageOnly
        toggleButton.isBordered = false
        toggleButton.bezelStyle = .accessoryBarAction
        toggleButton.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        toggleButton.target = self
        toggleButton.action = #selector(toggleReveal)
        toggleButton.refusesFirstResponder = true
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggleButton)

        NSLayoutConstraint.activate([
            secureField.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureField.topAnchor.constraint(equalTo: topAnchor),
            secureField.bottomAnchor.constraint(equalTo: bottomAnchor),
            secureField.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -6),

            plainField.leadingAnchor.constraint(equalTo: secureField.leadingAnchor),
            plainField.trailingAnchor.constraint(equalTo: secureField.trailingAnchor),
            plainField.topAnchor.constraint(equalTo: secureField.topAnchor),
            plainField.bottomAnchor.constraint(equalTo: secureField.bottomAnchor),

            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 22),
            toggleButton.heightAnchor.constraint(equalToConstant: 18),
        ])
        if multiline {
            heightAnchor.constraint(equalToConstant: 66).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleReveal() {
        isRevealed.toggle()
        secureField.isHidden = isRevealed
        plainField.isHidden = !isRevealed
        let symbol = isRevealed ? "eye.slash" : "eye"
        toggleButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isRevealed ? "Hide secret" : "Show secret"
        )

        // If the user was editing the field, transfer focus + caret to the
        // newly visible one so they can keep typing without re-clicking.
        guard let win = window else { return }
        let wasFirstResponder = (win.firstResponder as? NSText)?.delegate as? NSTextField === (isRevealed ? secureField : plainField)
        if wasFirstResponder {
            let target = isRevealed ? plainField : secureField
            win.makeFirstResponder(target)
            if let editor = target.currentEditor() {
                editor.selectedRange = NSRange(location: target.stringValue.count, length: 0)
            }
        }
    }

    // Keep the two fields in sync so toggling at any moment shows the latest value.
    func controlTextDidChange(_ obj: Notification) {
        guard let src = obj.object as? NSTextField else { return }
        if src === secureField {
            plainField.stringValue = secureField.stringValue
        } else if src === plainField {
            secureField.stringValue = plainField.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard multiline, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // 字段编辑器默认用回车结束编辑，这两类配置需要保留回车作为参数分隔符
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
}

// MARK: - Pasteable text fields

// capcap is an LSUIElement app with no main menu, so the standard Edit-menu
// key equivalents that normally route Cmd+X/C/V/A to the field editor never
// fire. These subclasses handle the shortcuts directly via the responder chain.

private func dispatchEditingShortcut(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
        return false
    }
    let action: Selector
    switch event.charactersIgnoringModifiers {
    case "x": action = #selector(NSText.cut(_:))
    case "c": action = #selector(NSText.copy(_:))
    case "v": action = #selector(NSText.paste(_:))
    case "a": action = #selector(NSText.selectAll(_:))
    default: return false
    }
    return NSApp.sendAction(action, to: nil, from: nil)
}

final class PasteableTextField: NSTextField {
    var onFocus: ((PasteableTextField) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocus?(self)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            onFocus?(self)
        }
        return didBecome
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if dispatchEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PasteableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if dispatchEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
