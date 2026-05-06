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

        let hint = NSTextField(wrappingLabelWithString: L10n.uploadFieldsHint)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.58)
        hint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

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

// MARK: - Per-provider card

private final class ProviderCard: NSView {
    let kind: UploadProviderKind
    let defaultBadge = NSTextField(labelWithString: "")
    let setDefaultButton = NSButton(title: L10n.uploadSetDefaultButton, target: nil, action: nil)
    let enableSwitch = NSSwitch()

    var onSetDefault: ((UploadProviderKind) -> Void)?

    private let fields: [ProviderField]
    private var inputs: [String: NSTextField] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyContainer = ClippingView()
    private var bodyHeightConstraint: NSLayoutConstraint!
    private var measuredBodyHeight: CGFloat = 0
    private var isExpanded: Bool

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        // Header (always visible) + bodyContainer (collapsible).
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

        // Field rows
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
            input.target = self
            input.action = #selector(fieldDidEnter(_:))
            inputs[f.key] = input
            row.addArrangedSubview(input)

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }

        // Footer: status + buttons
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

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

        let footer = NSStackView(views: [statusLabel, spacer(), clearBtn, saveBtn, setDefaultButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    override func layout() {
        super.layout()
        // Measure the natural body height once everything is laid out, then
        // commit the initial expansion state.
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
        // Re-measure if needed (handles the case where measuredBodyHeight is still 0).
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
    }

    @objc private func fieldDidEnter(_ sender: NSTextField) {
        saveTapped()
    }

    @objc private func saveTapped() {
        persistFields()
        let cfg = ProviderConfigStore.load(kind: kind) ?? ProviderConfig(kind: kind, fields: [:])
        if let err = Uploaders.provider(for: kind).validate(cfg) {
            statusLabel.stringValue = err
            statusLabel.textColor = NSColor.systemOrange
        } else {
            statusLabel.stringValue = L10n.uploadSavedToast
            statusLabel.textColor = NSColor.systemGreen
        }
    }

    @objc private func clearTapped() {
        for (_, field) in inputs { field.stringValue = "" }
        ProviderConfigStore.clear(kind: kind)
        if Defaults.defaultUploadProviderKind == kind {
            Defaults.defaultUploadProviderKind = nil
        }
        statusLabel.stringValue = ""
    }

    @objc private func setDefaultTapped() {
        onSetDefault?(kind)
    }
}

/// NSView subclass that flips clipping on so collapsed body content doesn't
/// bleed past the card's rounded corners during animation.
private final class ClippingView: NSView {
    override var wantsDefaultClipping: Bool { true }
}
