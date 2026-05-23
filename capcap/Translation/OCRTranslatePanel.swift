import AppKit

// MARK: - Shared helpers

/// capcap is an LSUIElement app with no main menu, so Cmd+C/V/X/A never reach
/// the field editor on their own. Route them through the responder chain.
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

/// NSTextView that honors copy/paste shortcuts without a menu.
final class PanelTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if dispatchEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Top-aligned content host for the scroll view's document.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - OCR image preview

private final class OCRPreviewView: NSView {
    private let image: NSImage
    var showsLineBoxes = false {
        didSet { needsDisplay = true }
    }
    var lines: [RecognizedTextLine] = [] {
        didSet { needsDisplay = true }
    }
    var onCopyText: ((String) -> Void)?

    private var copiedLineIndex: Int?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let imageRect = fittedImageRect()
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        NSColor.black.withAlphaComponent(0.26).setFill()
        bounds.fill()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        let imageBorder = NSBezierPath(
            roundedRect: imageRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: min(8, imageRect.width / 2),
            yRadius: min(8, imageRect.height / 2)
        )
        NSColor.black.withAlphaComponent(0.46).setStroke()
        imageBorder.lineWidth = 1
        imageBorder.stroke()

        if showsLineBoxes {
            for (index, line) in lines.enumerated() {
                let rect = displayRect(for: line.boundingBox, in: imageRect)
                    .insetBy(dx: -2, dy: -1)
                guard rect.width > 2, rect.height > 2 else { continue }
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                let isCopied = index == copiedLineIndex
                (isCopied
                    ? NSColor.systemGreen.withAlphaComponent(0.24)
                    : NSColor.systemTeal.withAlphaComponent(0.12)
                ).setFill()
                path.fill()
                (isCopied
                    ? NSColor.systemGreen.withAlphaComponent(0.95)
                    : NSColor.systemTeal.withAlphaComponent(0.88)
                ).setStroke()
                path.lineWidth = isCopied ? 2 : 1.2
                path.stroke()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard showsLineBoxes else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = fittedImageRect()
        for (index, line) in lines.enumerated().reversed() {
            let rect = displayRect(for: line.boundingBox, in: imageRect).insetBy(dx: -4, dy: -3)
            guard rect.contains(point) else { continue }
            copiedLineIndex = index
            onCopyText?(line.text)
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard self?.copiedLineIndex == index else { return }
                self?.copiedLineIndex = nil
                self?.needsDisplay = true
            }
            return
        }
        super.mouseDown(with: event)
    }

    private func fittedImageRect() -> NSRect {
        guard image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func displayRect(for normalizedRect: CGRect, in imageRect: NSRect) -> NSRect {
        NSRect(
            x: imageRect.minX + normalizedRect.minX * imageRect.width,
            y: imageRect.minY + normalizedRect.minY * imageRect.height,
            width: normalizedRect.width * imageRect.width,
            height: normalizedRect.height * imageRect.height
        )
    }
}

private final class PanelPinButton: NSButton {
    private var pinned = false
    private let pinSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.borderWidth = 1.2
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 3
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        setPinned(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }

    func setPinned(_ pinned: Bool) {
        self.pinned = pinned
        let label = pinned ? "Unpin dialog" : "Pin dialog"
        let symbolName = pinned ? "pin.fill" : "pin"
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(pinSymbolConfiguration)
        contentTintColor = pinned ? .white : NSColor.black.withAlphaComponent(0.82)
        layer?.backgroundColor = (pinned
            ? NSColor.systemTeal.withAlphaComponent(0.96)
            : NSColor.white.withAlphaComponent(0.90)
        ).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.48).cgColor
        toolTip = label
        setAccessibilityLabel(label)
    }
}

private final class TranslationHeaderView: NSView {
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}

private final class TranslationResultView: NSView {
    let kind: TranslationProviderKind

    private let statusLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private let textContainer = NSView()
    private let textView: PanelTextView
    private let textHeightConstraint: NSLayoutConstraint
    private let retryButton: NSButton
    private let copyButton: NSButton
    private let chevronView = NSImageView()
    private var retrySleeve: ClosureSleeve?
    private var isCollapsed = false
    private let onLayoutChange: () -> Void

    init(
        kind: TranslationProviderKind,
        onRetry: @escaping () -> Void,
        onLayoutChange: @escaping () -> Void
    ) {
        self.kind = kind
        self.onLayoutChange = onLayoutChange

        let retryButton = makeSmallButton(L10n.ocrRetry, action: #selector(ClosureSleeve.invoke))
        let copyButton = NSButton(title: "", target: nil, action: #selector(copyTapped))
        let textView = PanelTextView()
        self.retryButton = retryButton
        self.copyButton = copyButton
        self.textView = textView
        self.textHeightConstraint = textContainer.heightAnchor.constraint(equalToConstant: 34)

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        pin(stack, to: self, inset: 0)

        let title = makeLabel(kind.displayName, size: 12, weight: .semibold, alpha: 0.9)
        retryButton.isHidden = true
        retrySleeve = ClosureSleeve(onRetry)
        retryButton.target = retrySleeve

        copyButton.target = self
        copyButton.isEnabled = false
        configureIconButton(copyButton, symbolName: "doc.on.doc", label: L10n.ocrCopy)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevronView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        updateChevron()

        let header = TranslationHeaderView()
        header.onToggle = { [weak self] in self?.toggleCollapsed() }
        let headerStack = NSStackView(views: [title, flexSpacer(), retryButton, chevronView])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        pin(headerStack, to: header, inset: 0)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        chevronView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        chevronView.heightAnchor.constraint(equalToConstant: 14).isActive = true

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 7
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(contentStack)
        contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.52)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.usesSingleLineMode = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textContainer)
        textContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        textHeightConstraint.isActive = true

        configureExpandingTextView(textView)
        textContainer.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: textContainer.topAnchor),
            textView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
        ])

        let footer = NSStackView(views: [copyButton, flexSpacer()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        reset()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        textView.string = ""
        statusLabel.stringValue = L10n.ocrTranslating
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.52)
        statusLabel.isHidden = false
        retryButton.isHidden = true
        copyButton.isEnabled = false
        updateTextHeight()
    }

    func append(_ delta: String) {
        textView.string += delta
        updateTextHeight()
        onLayoutChange()
    }

    func markSuccess() {
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
        copyButton.isEnabled = !textView.string.isEmpty
        onLayoutChange()
    }

    func markFailure(_ error: Error) {
        statusLabel.stringValue = L10n.ocrTranslateFailedPrefix + error.localizedDescription
        statusLabel.textColor = NSColor.systemOrange
        statusLabel.isHidden = false
        retryButton.isHidden = false
        copyButton.isEnabled = !textView.string.isEmpty
        onLayoutChange()
    }

    @objc private func copyTapped() {
        guard !textView.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        flashIconButton(copyButton, symbolName: "checkmark", restoreSymbolName: "doc.on.doc")
    }

    private func toggleCollapsed() {
        isCollapsed.toggle()
        contentStack.isHidden = isCollapsed
        updateChevron()
        onLayoutChange()
    }

    private func updateChevron() {
        let symbolName = isCollapsed ? "chevron.right" : "chevron.down"
        chevronView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func updateTextHeight() {
        guard !textContainer.isHidden,
              let layoutContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }
        textContainer.layoutSubtreeIfNeeded()
        let width = max(self.textContainer.bounds.width, 220)
        layoutContainer.containerSize = NSSize(
            width: max(width - textView.textContainerInset.width * 2, 1),
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: layoutContainer)
        let used = layoutManager.usedRect(for: layoutContainer).height
        textHeightConstraint.constant = max(34, ceil(used + textView.textContainerInset.height * 2))
    }
}

// MARK: - OCR / screenshot translation panel

/// Floating dialog shown after text recognition or screenshot translation.
/// It stays centered near the top of the target screen.
final class OCRTranslatePanel: NSPanel {

    private enum Mode {
        case textRecognition
        case screenshotTranslation
    }

    private static var current: OCRTranslatePanel?
    private static let topMargin: CGFloat = 24

    private let screenshot: NSImage
    private let anchorScreen: NSScreen
    private let panelWidth: CGFloat
    private let mode: Mode

    private let padding: CGFloat = 14
    private var contentStack: NSStackView!
    private var docView: FlippedView!
    private var clipView: NSClipView!
    private var previewView: OCRPreviewView!

    private var ocrTextView: PanelTextView?
    private var ocrCopyButton: NSButton?
    private var translationPlaceholderLabel: NSTextField?
    private var translationResultsStack: NSStackView?
    private var translationResultViews: [TranslationProviderKind: TranslationResultView] = [:]
    private var translationLanguageButton: NSButton?
    private var pinButton: PanelPinButton?

    private var keyMonitor: Any?
    private var outsideClickLocalMonitor: Any?
    private var outsideClickGlobalMonitor: Any?
    private var languagePopover: NSPopover?
    private var translationTasks: [TranslationProviderKind: Task<Void, Never>] = [:]
    private var translationRunID = UUID()
    private var translationAttemptIDs: [TranslationProviderKind: UUID] = [:]
    private var recognizedText = ""
    private var ocrReady = false
    private var selectedTarget = TranslationLanguage.appDefault
    private var isPinned = false {
        didSet { pinButton?.setPinned(isPinned) }
    }

    // MARK: Presentation

    static func present(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        presentTextRecognition(image: image, anchorRect: anchorRect, screen: screen)
    }

    static func presentTextRecognition(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        present(image: image, anchorRect: anchorRect, screen: screen, mode: .textRecognition)
    }

    static func presentScreenshotTranslation(image: NSImage, anchorRect: NSRect, screen: NSScreen) {
        present(image: image, anchorRect: anchorRect, screen: screen, mode: .screenshotTranslation)
    }

    private static func present(image: NSImage, anchorRect: NSRect, screen: NSScreen, mode: Mode) {
        current?.dismiss()
        let panel = OCRTranslatePanel(image: image, anchorRect: anchorRect, screen: screen, mode: mode)
        current = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.runOCR()
    }

    private init(image: NSImage, anchorRect: NSRect, screen: NSScreen, mode: Mode) {
        let panelWidth = min(max(anchorRect.width, 360), 500)
        self.screenshot = image
        self.anchorScreen = screen
        self.panelWidth = panelWidth
        self.mode = mode
        let initialHeight: CGFloat = 320
        let initialFrame = Self.topCenteredFrame(
            width: panelWidth,
            height: initialHeight,
            on: screen
        )

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildUI()
        installEventMonitors()
        refreshHeight()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: UI

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1.0).cgColor
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        root.layer?.borderWidth = 1
        contentView = root

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)
        clipView = scrollView.contentView

        docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(contentStack)

        let pinButton = PanelPinButton()
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        self.pinButton = pinButton
        root.addSubview(pinButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -padding),

            docView.topAnchor.constraint(equalTo: contentStack.topAnchor),
            docView.heightAnchor.constraint(equalTo: contentStack.heightAnchor),
            docView.widthAnchor.constraint(equalTo: clipView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: docView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),

            pinButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            pinButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        buildScreenshotCard()
        switch mode {
        case .textRecognition:
            buildOCRCard()
        case .screenshotTranslation:
            buildTranslationCard()
        }
    }

    private func addStackRow(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func buildScreenshotCard() {
        previewView = OCRPreviewView(image: screenshot)
        previewView.showsLineBoxes = mode == .textRecognition
        previewView.onCopyText = { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ToastWindow.show(message: L10n.ocrLineCopied, duration: 0.9)
            if let button = self?.ocrCopyButton {
                flashButton(button, to: L10n.ocrCopied, restore: L10n.ocrCopy)
            }
        }

        let size = screenshot.size
        let aspect = size.width > 0 ? size.height / size.width : 0.5
        let contentWidth = panelWidth - padding * 2
        let height = min(max(contentWidth * aspect, 64), 260)
        previewView.heightAnchor.constraint(equalToConstant: height).isActive = true

        addStackRow(previewView)
    }

    private func buildOCRCard() {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        let title = makeLabel(L10n.ocrTextHeader, size: 12, weight: .semibold, alpha: 0.92)
        let copyButton = makeSmallButton(L10n.ocrCopy, action: #selector(copyOCRTapped))
        copyButton.target = self
        copyButton.isEnabled = false
        ocrCopyButton = copyButton

        let header = NSStackView(views: [title, flexSpacer(), copyButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let (scroll, textView) = makeTextScroll(editable: true, height: 116)
        textView.string = L10n.ocrRecognizing
        textView.textColor = NSColor.white.withAlphaComponent(0.4)
        ocrTextView = textView
        inner.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        addStackRow(card)
    }

    private func buildTranslationCard() {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        let title = makeLabel(L10n.screenshotTranslationHeader, size: 12, weight: .semibold, alpha: 0.92)

        let languageButton = makeSmallButton(languageButtonTitle(), action: #selector(languageTapped))
        languageButton.target = self
        translationLanguageButton = languageButton

        let header = NSStackView(views: [title, flexSpacer(), languageButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let status = makeLabel(L10n.ocrRecognizing, size: 11, weight: .medium, alpha: 0.52)
        status.lineBreakMode = .byWordWrapping
        status.usesSingleLineMode = false
        translationPlaceholderLabel = status
        inner.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let resultsStack = NSStackView()
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 12
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        translationResultsStack = resultsStack
        inner.addArrangedSubview(resultsStack)
        resultsStack.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        addStackRow(card)
    }

    private func makeNoProviderCard() -> NSView {
        let card = makeCard()
        let inner = makeCardStack()
        card.addSubview(inner)
        pin(inner, to: card, inset: 12)

        let title = makeLabel(L10n.ocrNoProviderTitle, size: 12, weight: .semibold, alpha: 0.9)
        let hint = makeLabel(L10n.ocrNoProviderHint, size: 11, weight: .regular, alpha: 0.55)
        hint.lineBreakMode = .byWordWrapping
        hint.usesSingleLineMode = false
        hint.preferredMaxLayoutWidth = panelWidth - padding * 2 - 24
        let button = makeSmallButton(L10n.ocrOpenSettings, action: #selector(openSettingsTapped))
        button.target = self

        inner.addArrangedSubview(title)
        inner.addArrangedSubview(hint)
        inner.addArrangedSubview(button)
        return card
    }

    // MARK: OCR / Translation

    private func runOCR() {
        Task { @MainActor in
            let lines = await OCRService.recognizeLines(image: screenshot)
            self.previewView.lines = lines
            self.recognizedText = lines.map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.ocrReady = true

            switch self.mode {
            case .textRecognition:
                self.finishTextRecognition()
            case .screenshotTranslation:
                self.finishOCRAndStartTranslation()
            }
            self.refreshHeight()
        }
    }

    private func finishTextRecognition() {
        guard let textView = ocrTextView, let copyButton = ocrCopyButton else { return }
        if recognizedText.isEmpty {
            textView.string = L10n.ocrNoText
            textView.textColor = NSColor.white.withAlphaComponent(0.4)
            copyButton.isEnabled = false
        } else {
            textView.string = recognizedText
            textView.textColor = NSColor.white.withAlphaComponent(0.9)
            copyButton.isEnabled = true
        }
    }

    private func finishOCRAndStartTranslation() {
        guard !recognizedText.isEmpty else {
            cancelTranslationTasks()
            clearTranslationResults()
            setTranslationPlaceholder(L10n.ocrNoText)
            return
        }
        runTranslation(target: selectedTarget)
    }

    private func runTranslation(target: TranslationLanguage) {
        cancelTranslationTasks()
        clearTranslationResults()
        translationRunID = UUID()

        let kinds = TranslationConfigStore.usableKinds()
        guard !kinds.isEmpty else {
            setTranslationPlaceholder("\(L10n.ocrNoProviderTitle)\n\(L10n.ocrNoProviderHint)")
            refreshHeight()
            return
        }

        translationPlaceholderLabel?.isHidden = true
        let text = recognizedText

        for kind in kinds {
            let resultView = TranslationResultView(
                kind: kind,
                onRetry: { [weak self] in self?.retryTranslation(kind: kind) },
                onLayoutChange: { [weak self] in self?.refreshHeight() }
            )
            translationResultViews[kind] = resultView
            translationResultsStack?.addArrangedSubview(resultView)
            if let stack = translationResultsStack {
                resultView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            startTranslation(kind: kind, target: target, text: text)
        }
        refreshHeight()
    }

    private func startTranslation(kind: TranslationProviderKind, target: TranslationLanguage, text: String) {
        translationTasks[kind]?.cancel()
        translationResultViews[kind]?.reset()

        let config = TranslationConfigStore.load(kind)
        let runID = translationRunID
        let attemptID = UUID()
        translationAttemptIDs[kind] = attemptID
        translationTasks[kind] = Task { @MainActor [weak self] in
            do {
                let stream = TranslationService.stream(
                    text: text, target: target, kind: kind, config: config
                )
                for try await delta in stream {
                    guard let self, self.isCurrentTranslation(kind: kind, runID: runID, attemptID: attemptID) else {
                        return
                    }
                    self.translationResultViews[kind]?.append(delta)
                }
                guard let self, self.isCurrentTranslation(kind: kind, runID: runID, attemptID: attemptID) else {
                    return
                }
                self.translationResultViews[kind]?.markSuccess()
                self.refreshHeight()
            } catch is CancellationError {
                // Panel closed, retried, or target language changed.
            } catch {
                guard let self, self.isCurrentTranslation(kind: kind, runID: runID, attemptID: attemptID) else {
                    return
                }
                self.translationResultViews[kind]?.markFailure(error)
                self.refreshHeight()
            }
        }
    }

    private func isCurrentTranslation(
        kind: TranslationProviderKind,
        runID: UUID,
        attemptID: UUID
    ) -> Bool {
        translationRunID == runID && translationAttemptIDs[kind] == attemptID
    }

    private func retryTranslation(kind: TranslationProviderKind) {
        guard !recognizedText.isEmpty else { return }
        startTranslation(kind: kind, target: selectedTarget, text: recognizedText)
    }

    private func cancelTranslationTasks() {
        for task in translationTasks.values { task.cancel() }
        translationTasks.removeAll()
        translationAttemptIDs.removeAll()
    }

    private func clearTranslationResults() {
        translationResultViews.removeAll()
        guard let stack = translationResultsStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func setTranslationPlaceholder(_ text: String) {
        translationPlaceholderLabel?.stringValue = text
        translationPlaceholderLabel?.textColor = NSColor.white.withAlphaComponent(0.52)
        translationPlaceholderLabel?.isHidden = false
    }

    // MARK: Sizing

    /// Resizes the panel to fit its content while keeping it centered near the
    /// top of the target screen.
    private func refreshHeight() {
        contentView?.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        let desired = contentHeight + padding * 2
        let visible = anchorScreen.visibleFrame
        let maxHeight = min(700, visible.height - Self.topMargin - 16)
        let height = max(180, min(desired, maxHeight))

        setFrame(Self.topCenteredFrame(width: panelWidth, height: height, on: anchorScreen),
                 display: true, animate: false)
    }

    private static func topCenteredFrame(width: CGFloat, height: CGFloat, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let originX = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        let originY = visible.maxY - topMargin - height
        return NSRect(x: originX, y: max(originY, visible.minY), width: width, height: height)
    }

    // MARK: Actions

    @objc private func pinTapped() {
        isPinned.toggle()
    }

    @objc private func openSettingsTapped() {
        SettingsWindowController.shared.showAsSettings()
        dismiss()
    }

    @objc private func copyOCRTapped() {
        guard ocrReady, !recognizedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedText, forType: .string)
        if let button = ocrCopyButton {
            flashButton(button, to: L10n.ocrCopied, restore: L10n.ocrCopy)
        }
    }

    @objc private func languageTapped() {
        languagePopover?.performClose(nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = LanguagePickerView(selected: selectedTarget) { [weak self, weak popover] language in
            popover?.performClose(nil)
            self?.selectTargetLanguage(language)
        }
        popover.contentViewController = controller
        languagePopover = popover

        if let button = translationLanguageButton {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    private func selectTargetLanguage(_ language: TranslationLanguage) {
        guard selectedTarget != language else { return }
        selectedTarget = language
        translationLanguageButton?.title = languageButtonTitle()
        if !recognizedText.isEmpty {
            runTranslation(target: language)
        }
    }

    private func languageButtonTitle() -> String {
        L10n.screenshotTranslationLanguageButton(selectedTarget.displayName)
    }

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            if event.keyCode == 53 { // Escape
                self.dismiss()
                return nil
            }
            return event
        }

        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            self?.dismissForOutsideClickIfNeeded(event)
            return event
        }
        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            self?.dismissForOutsideClickIfNeeded(event)
        }
    }

    private func dismissForOutsideClickIfNeeded(_ event: NSEvent) {
        guard !isPinned, isVisible, !eventBelongsToPanel(event) else { return }
        dismiss()
    }

    private func eventBelongsToPanel(_ event: NSEvent) -> Bool {
        if event.window === self || event.windowNumber == windowNumber {
            return true
        }
        if let popoverWindow = languagePopover?.contentViewController?.view.window,
           (event.window === popoverWindow || event.windowNumber == popoverWindow.windowNumber) {
            return true
        }
        return false
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let outsideClickLocalMonitor {
            NSEvent.removeMonitor(outsideClickLocalMonitor)
            self.outsideClickLocalMonitor = nil
        }
        if let outsideClickGlobalMonitor {
            NSEvent.removeMonitor(outsideClickGlobalMonitor)
            self.outsideClickGlobalMonitor = nil
        }
        cancelTranslationTasks()
        languagePopover?.performClose(nil)
        orderOut(nil)
        if OCRTranslatePanel.current === self { OCRTranslatePanel.current = nil }
    }

    // MARK: Shared builders

    fileprivate static func styleCard(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        view.layer?.borderWidth = 1
    }

    private func makeCard() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        Self.styleCard(v)
        return v
    }

    private func makeCardStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
}

private final class LanguagePickerView: NSView {
    private var sleeves: [ClosureSleeve] = []

    init(selected: TranslationLanguage, onSelect: @escaping (TranslationLanguage) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 1))
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for language in TranslationLanguage.allCases {
            let title = language == selected ? "✓ \(language.displayName)" : language.displayName
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.font = NSFont.systemFont(ofSize: 12, weight: language == selected ? .semibold : .regular)
            button.contentTintColor = NSColor.white.withAlphaComponent(language == selected ? 0.95 : 0.78)
            button.translatesAutoresizingMaskIntoConstraints = false
            let sleeve = ClosureSleeve { onSelect(language) }
            sleeves.append(sleeve)
            button.target = sleeve
            button.action = #selector(ClosureSleeve.invoke)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(equalToConstant: 220),
        ])

        let height = CGFloat(TranslationLanguage.allCases.count) * 26 + 16
        frame.size = NSSize(width: 220, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ClosureSleeve: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    @objc func invoke() { closure() }
}

// MARK: - Free-standing builders

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = NSColor.white.withAlphaComponent(alpha)
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func flexSpacer() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return v
}

func makeSmallButton(_ title: String, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: nil, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .small
    b.font = NSFont.systemFont(ofSize: 11)
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
}

func configureIconButton(_ button: NSButton, symbolName: String, label: String) {
    button.title = ""
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.controlSize = .small
    button.contentTintColor = NSColor.white.withAlphaComponent(0.78)
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 24).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
}

func pin(_ child: NSView, to parent: NSView, inset: CGFloat) {
    NSLayoutConstraint.activate([
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
}

func configureExpandingTextView(_ textView: PanelTextView) {
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: 12)
    textView.textColor = NSColor.white.withAlphaComponent(0.9)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
}

/// A bordered scroll view wrapping a `PanelTextView` of fixed height.
func makeTextScroll(editable: Bool, height: CGFloat) -> (NSScrollView, PanelTextView) {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = NSColor.black.withAlphaComponent(0.22)
    scroll.borderType = .noBorder
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 6
    scroll.layer?.cornerCurve = .continuous
    scroll.layer?.masksToBounds = true
    scroll.heightAnchor.constraint(equalToConstant: height).isActive = true

    let textView = PanelTextView()
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: 12)
    textView.textColor = NSColor.white.withAlphaComponent(0.9)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = textView
    return (scroll, textView)
}

/// Flips a button title to a confirmation string for a moment.
func flashButton(_ button: NSButton, to confirm: String, restore: String) {
    button.title = confirm
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in
        button?.title = restore
    }
}

func flashIconButton(_ button: NSButton, symbolName: String, restoreSymbolName: String) {
    button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: L10n.ocrCopied)
    button.contentTintColor = NSColor.systemGreen
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in
        button?.image = NSImage(systemSymbolName: restoreSymbolName, accessibilityDescription: L10n.ocrCopy)
        button?.contentTintColor = NSColor.white.withAlphaComponent(0.78)
    }
}
