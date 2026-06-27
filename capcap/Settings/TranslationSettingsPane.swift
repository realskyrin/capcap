import AppKit

/// Content of the Settings "翻译" tab: one editable config card per AI
/// translation provider. The target language follows the app language.
final class TranslationSettingsPane: NSView {
    private var providerCards: [TranslationProviderCard] = []
    private let dictionaryModeSwitch = NSSwitch()
    private let dictionaryModeTitleLabel = NSTextField(labelWithString: "")
    private let dictionaryModeSubtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var providersHeaderLabel: NSTextField!
    private var providersStack: NSStackView!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: .languageDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let dictionaryModeCard = buildDictionaryModeCard()
        stack.addArrangedSubview(dictionaryModeCard)
        dictionaryModeCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Providers header.
        providersHeaderLabel = makeLabel(L10n.translationProvidersHeader, size: 12, weight: .semibold, alpha: 0.62)
        stack.addArrangedSubview(providersHeaderLabel)

        // Provider cards.
        providersStack = NSStackView()
        providersStack.orientation = .vertical
        providersStack.alignment = .leading
        providersStack.spacing = 12
        providersStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(providersStack)
        providersStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for kind in TranslationConfigStore.orderedKinds() {
            let card = TranslationProviderCard(kind: kind)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.onMoveUp = { [weak self] kind in self?.moveProvider(kind, offset: -1) }
            card.onMoveDown = { [weak self] kind in self?.moveProvider(kind, offset: 1) }
            providerCards.append(card)
            providersStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
        }
        refreshMoveButtons()

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
    }

    private func buildDictionaryModeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.layer?.borderWidth = 1

        dictionaryModeTitleLabel.stringValue = L10n.translationDictionaryModeTitle
        dictionaryModeTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        dictionaryModeTitleLabel.textColor = NSColor.white.withAlphaComponent(0.94)

        dictionaryModeSubtitleLabel.stringValue = L10n.translationDictionaryModeSubtitle
        dictionaryModeSubtitleLabel.font = NSFont.systemFont(ofSize: 11)
        dictionaryModeSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        dictionaryModeSubtitleLabel.maximumNumberOfLines = 0
        dictionaryModeSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [dictionaryModeTitleLabel, dictionaryModeSubtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        dictionaryModeSwitch.controlSize = .small
        dictionaryModeSwitch.state = Defaults.translationDictionaryMode ? .on : .off
        dictionaryModeSwitch.target = self
        dictionaryModeSwitch.action = #selector(dictionaryModeToggled)
        dictionaryModeSwitch.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(textStack)
        card.addSubview(dictionaryModeSwitch)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            textStack.trailingAnchor.constraint(equalTo: dictionaryModeSwitch.leadingAnchor, constant: -12),

            dictionaryModeSwitch.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            dictionaryModeSwitch.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),

            dictionaryModeSubtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])
        return card
    }

    @objc private func onLanguageChanged() {
        dictionaryModeTitleLabel.stringValue = L10n.translationDictionaryModeTitle
        dictionaryModeSubtitleLabel.stringValue = L10n.translationDictionaryModeSubtitle
        providersHeaderLabel.stringValue = L10n.translationProvidersHeader
        for card in providerCards { card.refreshLocalization() }
    }

    @objc private func dictionaryModeToggled() {
        Defaults.translationDictionaryMode = dictionaryModeSwitch.state == .on
    }

    private func moveProvider(_ kind: TranslationProviderKind, offset: Int) {
        guard
            let from = providerCards.firstIndex(where: { $0.kind == kind })
        else { return }

        let to = from + offset
        guard providerCards.indices.contains(to) else { return }

        let card = providerCards.remove(at: from)
        providerCards.insert(card, at: to)
        refreshProviderStack()
        refreshMoveButtons()
        TranslationConfigStore.setProviderOrder(providerCards.map(\.kind))
    }

    private func refreshProviderStack() {
        for view in providersStack.arrangedSubviews {
            providersStack.removeArrangedSubview(view)
        }
        for card in providerCards {
            providersStack.addArrangedSubview(card)
        }
    }

    private func refreshMoveButtons() {
        for (index, card) in providerCards.enumerated() {
            card.setMoveAvailability(
                canMoveUp: index > 0,
                canMoveDown: index < providerCards.count - 1
            )
        }
    }
}

// MARK: - Pasteable text field

/// Text field that honors Cmd+C/V/X/A in a menu-less LSUIElement app.
private final class TKTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector
        switch event.charactersIgnoringModifiers {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

// MARK: - Provider card

private final class TranslationProviderCard: NSView {
    private static let maxFailureSummaryLength = 220
    private static let maxFailureDetailLength = 4_000
    private static let failureDetailSize = NSSize(width: 480, height: 160)

    let kind: TranslationProviderKind
    var onMoveUp: ((TranslationProviderKind) -> Void)?
    var onMoveDown: ((TranslationProviderKind) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let enableSwitch = NSSwitch()
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()
    private let apiKeyField = RevealableSecureField()
    private let modelField = TKTextField()
    private let endpointField = TKTextField()
    private let apiKeyLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let endpointLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let bodyContainer = ClippingView()
    private var bodyHeightConstraint: NSLayoutConstraint!
    private var measuredBodyHeight: CGFloat = 0
    private var isExpanded: Bool

    init(kind: TranslationProviderKind) {
        self.kind = kind
        self.isExpanded = TranslationConfigStore.isEnabled(kind)
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

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        pin(outer, to: self, inset: 14)

        // Header.
        titleLabel.stringValue = kind.displayName
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(switchToggled)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(moveUpButton, symbolName: "chevron.up", label: L10n.translationMoveUp)
        moveUpButton.target = self
        moveUpButton.action = #selector(moveUpTapped)

        configureIconButton(moveDownButton, symbolName: "chevron.down", label: L10n.translationMoveDown)
        moveDownButton.target = self
        moveDownButton.action = #selector(moveDownTapped)

        let header = NSStackView(views: [titleLabel, flexSpacer(), moveUpButton, moveDownButton, enableSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        // Body.
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.wantsLayer = true
        bodyContainer.layer?.masksToBounds = true
        bodyContainer.addSubview(body)

        bodyHeightConstraint = bodyContainer.heightAnchor.constraint(equalToConstant: 0)
        bodyHeightConstraint.priority = .required
        bodyHeightConstraint.isActive = true

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            body.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            {
                let c = body.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
                c.priority = .defaultHigh
                return c
            }(),
        ])

        body.addArrangedSubview(makeFieldRow(apiKeyLabel, apiKeyField,
                                             label: apiKeyLabelText(),
                                             placeholder: "API key", width: body))
        if !kind.isDirectTranslationAPI {
            body.addArrangedSubview(makeFieldRow(modelLabel, modelField,
                                                 label: L10n.translationModel,
                                                 placeholder: modelPlaceholder(), width: body))
        }
        body.addArrangedSubview(makeFieldRow(endpointLabel, endpointField,
                                             label: endpointLabelText(),
                                             placeholder: endpointPlaceholder(), width: body))

        saveButton.title = L10n.translationSave
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        clearButton.title = L10n.translationClear
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        let footer = NSStackView(views: [flexSpacer(), clearButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        outer.addArrangedSubview(bodyContainer)
        bodyContainer.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }

    override func layout() {
        super.layout()
        if measuredBodyHeight == 0, bounds.width > 0 {
            bodyHeightConstraint.isActive = false
            bodyContainer.layoutSubtreeIfNeeded()
            measuredBodyHeight = bodyContainer.fittingSize.height
            bodyHeightConstraint.isActive = true
            bodyHeightConstraint.constant = isExpanded ? measuredBodyHeight : 0
        }
    }

    private func makeFieldRow(_ label: NSTextField, _ field: any ProviderFieldInput,
                              label labelText: String, placeholder: String,
                              width: NSView) -> NSView {
        label.stringValue = labelText
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.74)
        label.alignment = .right
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return row
    }

    // MARK: Field metadata

    private func modelPlaceholder() -> String {
        return kind.defaultModel.isEmpty ? "e.g. gpt-4o-mini" : kind.defaultModel
    }

    private func apiKeyLabelText() -> String {
        kind.isDeepLX ? L10n.translationApiKeyOptional : L10n.translationApiKey
    }

    private func endpointLabelText() -> String {
        kind.endpointRequired ? L10n.translationEndpoint : L10n.translationEndpointOptional
    }

    private func endpointPlaceholder() -> String {
        if kind.isDeepL {
            return "Auto: api-free.deepl.com for :fx keys"
        }
        if kind.isDeepLX {
            return kind.defaultEndpoint
        }
        return kind.defaultEndpoint.isEmpty
            ? "https://api.example.com/v1/chat/completions"
            : kind.defaultEndpoint
    }

    // MARK: Persistence

    private func loadFromStore() {
        let cfg = TranslationConfigStore.load(kind)
        apiKeyField.stringValue = cfg.apiKey
        modelField.stringValue = cfg.model
        endpointField.stringValue = cfg.endpoint
    }

    private func currentConfig() -> TranslationConfig {
        TranslationConfig(
            apiKey: apiKeyField.stringValue,
            model: kind.isDirectTranslationAPI ? "" : modelField.stringValue,
            endpoint: endpointField.stringValue
        )
    }

    @objc private func switchToggled() {
        let on = enableSwitch.state == .on
        let config = currentConfig()
        if on {
            TranslationConfigStore.save(config, for: kind)
            if config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setExpanded(true, animated: true)
            }
        } else {
            setExpanded(false, animated: true)
        }
        TranslationConfigStore.setEnabled(on, for: kind)
    }

    @objc private func toggleExpanded() {
        setExpanded(!isExpanded, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        toggleExpanded()
    }

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

    @objc private func moveUpTapped() {
        onMoveUp?(kind)
    }

    @objc private func moveDownTapped() {
        onMoveDown?(kind)
    }

    @objc private func saveTapped() {
        let config = currentConfig()
        TranslationConfigStore.save(config, for: kind)

        // Nothing to test against without an API key — just confirm the save.
        if kind.isAPIKeyRequired {
            guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flashButton(saveButton, to: L10n.translationConfigSaved, restore: L10n.translationSave)
                return
            }
        }

        saveButton.isEnabled = false
        clearButton.isEnabled = false
        saveButton.title = L10n.translationTesting

        let testedKind = kind
        Task { [weak self] in
            let error = await TranslationService.verify(kind: testedKind, config: config)
            await MainActor.run {
                guard let self else { return }
                self.saveButton.isEnabled = true
                self.clearButton.isEnabled = true
                if let error {
                    flashButton(self.saveButton, to: L10n.translationTestFailed,
                                restore: L10n.translationSave)
                    self.showTestFailure(error)
                } else {
                    flashButton(self.saveButton, to: L10n.translationTestPassed,
                                restore: L10n.translationSave)
                }
            }
        }
    }

    /// Reports a failed connection test. The config was already saved.
    private func showTestFailure(_ error: Error) {
        let alertText = Self.alertText(for: error.localizedDescription)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.translationTestFailedTitle
        alert.informativeText = alertText.summary
        if let detail = alertText.detail {
            alert.accessoryView = Self.makeFailureDetailView(detail)
        }
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func alertText(for rawText: String) -> (summary: String, detail: String?) {
        let detail = normalizedFailureText(rawText)
        let summary = failureSummary(from: detail)
        return detail == summary ? (summary, nil) : (summary, detail)
    }

    private static func normalizedFailureText(_ rawText: String) -> String {
        let normalizedNewlines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let cleanedScalars = normalizedNewlines.unicodeScalars.map { scalar -> String in
            if scalar.value == 9 || scalar.value == 10 {
                return String(scalar)
            }
            return CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }

        let cleanedLines = cleanedScalars
            .joined()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let cleaned = cleanedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return L10n.translationErrBadResponse
        }
        return String(cleaned.prefix(maxFailureDetailLength))
    }

    private static func failureSummary(from text: String) -> String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text

        let compact = firstLine
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if compact.count <= maxFailureSummaryLength {
            return compact
        }
        let endIndex = compact.index(compact.startIndex, offsetBy: maxFailureSummaryLength)
        return String(compact[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeFailureDetailView(_ text: String) -> NSView {
        let frame = NSRect(origin: .zero, size: failureDetailSize)
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: failureDetailSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    @objc private func clearTapped() {
        apiKeyField.stringValue = ""
        modelField.stringValue = ""
        endpointField.stringValue = ""
        TranslationConfigStore.clear(kind)
    }

    func refreshLocalization() {
        titleLabel.stringValue = kind.displayName
        apiKeyLabel.stringValue = apiKeyLabelText()
        modelLabel.stringValue = L10n.translationModel
        endpointLabel.stringValue = endpointLabelText()
        saveButton.title = L10n.translationSave
        clearButton.title = L10n.translationClear
        moveUpButton.toolTip = L10n.translationMoveUp
        moveUpButton.setAccessibilityLabel(L10n.translationMoveUp)
        moveDownButton.toolTip = L10n.translationMoveDown
        moveDownButton.setAccessibilityLabel(L10n.translationMoveDown)
    }

    func setMoveAvailability(canMoveUp: Bool, canMoveDown: Bool) {
        moveUpButton.isEnabled = canMoveUp
        moveUpButton.alphaValue = canMoveUp ? 1.0 : 0.35
        moveDownButton.isEnabled = canMoveDown
        moveDownButton.alphaValue = canMoveDown ? 1.0 : 0.35
    }
}

private final class ClippingView: NSView {
    override var wantsDefaultClipping: Bool { true }
}
