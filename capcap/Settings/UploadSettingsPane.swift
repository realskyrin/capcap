import AppKit

/// Editable cards for the three image-host providers. Lives inside the Settings
/// "Upload" tab built by SettingsView.
final class UploadSettingsPane: NSView {
    private var defaultBadges: [UploadProviderKind: NSTextField] = [:]
    private var setDefaultButtons: [UploadProviderKind: NSButton] = [:]
    private var providerCards: [UploadProviderKind: ProviderCard] = [:]

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

    private static func fields(for kind: UploadProviderKind) -> [ProviderField] {
        switch kind {
        case .tencent:
            return [
                .init(key: "secretId",  label: "SecretId",  placeholder: "AKIDxxxxxxxx", secure: false),
                .init(key: "secretKey", label: "SecretKey", placeholder: "********",     secure: true),
                .init(key: "bucket",    label: L10n.lang == .zh ? "存储桶" : "Bucket",
                      placeholder: "examplebucket-1250000000", secure: false),
                .init(key: "region",    label: L10n.lang == .zh ? "地域" : "Region",
                      placeholder: "ap-shanghai", secure: false),
                .init(key: "path",      label: L10n.lang == .zh ? "路径(可选)" : "Path (optional)",
                      placeholder: "screenshots", secure: false),
                .init(key: "customUrl", label: L10n.lang == .zh ? "自定义域名(可选)" : "Custom URL (optional)",
                      placeholder: "https://cdn.example.com", secure: false),
            ]
        case .qiniu:
            return [
                .init(key: "accessKey", label: "AccessKey", placeholder: "********", secure: false),
                .init(key: "secretKey", label: "SecretKey", placeholder: "********", secure: true),
                .init(key: "bucket",    label: L10n.lang == .zh ? "存储空间" : "Bucket",
                      placeholder: "my-bucket", secure: false),
                .init(key: "domain",    label: L10n.lang == .zh ? "外链域名" : "Public Domain",
                      placeholder: "https://cdn.example.com", secure: false),
                .init(key: "region",    label: L10n.lang == .zh ? "区域(可选)" : "Region (optional)",
                      placeholder: "z0 / z1 / z2 / na0 / as0 / cn-east-2", secure: false),
                .init(key: "path",      label: L10n.lang == .zh ? "路径(可选)" : "Path (optional)",
                      placeholder: "screenshots", secure: false),
            ]
        case .aliyun:
            return [
                .init(key: "accessKeyId",     label: "AccessKey Id",     placeholder: "LTAIxxxxxxx",  secure: false),
                .init(key: "accessKeySecret", label: "AccessKey Secret", placeholder: "********",     secure: true),
                .init(key: "bucket",          label: L10n.lang == .zh ? "存储桶" : "Bucket",
                      placeholder: "my-bucket", secure: false),
                .init(key: "area",            label: L10n.lang == .zh ? "Endpoint 地域" : "Endpoint",
                      placeholder: "oss-cn-hangzhou", secure: false),
                .init(key: "path",            label: L10n.lang == .zh ? "路径(可选)" : "Path (optional)",
                      placeholder: "screenshots", secure: false),
                .init(key: "customUrl",       label: L10n.lang == .zh ? "自定义域名(可选)" : "Custom URL (optional)",
                      placeholder: "https://cdn.example.com", secure: false),
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
    let defaultBadge = NSTextField(labelWithString: "")
    let setDefaultButton = NSButton(title: L10n.uploadSetDefaultButton, target: nil, action: nil)
    let enableSwitch = NSSwitch()

    var onSetDefault: ((UploadProviderKind) -> Void)?

    private let fields: [ProviderField]
    private var inputs: [String: NSTextField] = [:]
    private let statusPill = StatusPill()
    private let logView = LogView()
    private let bodyContainer = ClippingView()
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

        let bodyStack = buildBodyStack()
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
        let title = NSTextField(labelWithString: kind.displayName)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.94)
        title.translatesAutoresizingMaskIntoConstraints = false

        defaultBadge.stringValue = L10n.uploadCurrentDefault
        defaultBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        defaultBadge.textColor = NSColor.systemGreen
        defaultBadge.wantsLayer = true
        defaultBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
        defaultBadge.layer?.cornerRadius = 4
        defaultBadge.layer?.cornerCurve = .continuous
        defaultBadge.alignment = .center
        defaultBadge.isHidden = true
        defaultBadge.translatesAutoresizingMaskIntoConstraints = false

        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(switchToggled)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [title, defaultBadge, spacer(), enableSwitch])
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
        stack.translatesAutoresizingMaskIntoConstraints = false

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

            let input: NSTextField = f.secure ? NSSecureTextField() : NSTextField()
            input.placeholderString = f.placeholder
            input.font = NSFont.systemFont(ofSize: 12)
            input.translatesAutoresizingMaskIntoConstraints = false
            inputs[f.key] = input
            row.addArrangedSubview(input)

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }

        // Footer: status pill (bottom-left) + buttons (bottom-right).
        let saveBtn = NSButton(title: L10n.uploadSaveButton, target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .small

        let clearBtn = NSButton(title: L10n.uploadClearButton, target: self, action: #selector(clearTapped))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small

        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.controlSize = .small
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setDefaultTapped)

        let footer = NSStackView(views: [statusPill, spacer(), clearBtn, saveBtn, setDefaultButton])
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

    /// Force the current text-field values into UserDefaults without touching the
    /// status label. Used right before flipping the default so freshly typed
    /// values count as "saved".
    func persistFields() {
        var dict: [String: String] = [:]
        for (k, field) in inputs {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { dict[k] = v }
        }
        ProviderConfigStore.save(ProviderConfig(kind: kind, fields: dict))
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
        setExpanded(on, animated: true)
        if on {
            runValidation()
        } else {
            // Cancel any in-flight test result so it doesn't paint a stale state.
            pendingTestToken = nil
            status = .untested
            logView.append(.info, L10n.uploadLogProviderDisabled)
        }
    }

    @objc private func saveTapped() {
        persistFields()
        logView.append(.info, L10n.uploadLogConfigSaved)
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

    /// Persists the current values, then runs validate() + a tiny test PUT.
    /// Updates the pill and log as the work progresses.
    private func runValidation() {
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
            logView.append(.error, L10n.lang == .zh ? "无法生成测试图片" : "Failed to build test image")
            return
        }

        status = .testing
        logView.append(.info, L10n.uploadLogStartingTest)
        let token = UUID()
        pendingTestToken = token

        Uploaders.provider(for: kind).upload(
            data: png,
            fileName: "capcap-config-test.png",
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
