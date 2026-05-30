import AppKit
import UniformTypeIdentifiers

final class ImageMergeWindowController: NSWindowController, NSWindowDelegate {
    private let mergeDocument: ImageMergeDocument
    private let onContinueEditing: (NSImage) -> Void
    private let onClose: () -> Void

    private let canvasView = ImageMergeCanvasView(frame: .zero)
    private let thumbnailListView = ImageMergeThumbnailListView(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
    private var templateButtons: [ImageMergeTemplateChipButton] = []
    private let spacingSlider = NSSlider(value: 12, minValue: 0, maxValue: 80, target: nil, action: nil)
    private let marginSlider = NSSlider(value: 24, minValue: 0, maxValue: 120, target: nil, action: nil)
    private let cornerSlider = NSSlider(value: 0, minValue: 0, maxValue: 80, target: nil, action: nil)
    private let spacingValueLabel = NSTextField(labelWithString: "12")
    private let marginValueLabel = NSTextField(labelWithString: "24")
    private let cornerValueLabel = NSTextField(labelWithString: "0")
    private let backgroundMode = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let colorWell = NSColorWell(frame: .zero)
    private let copyButton = NSButton(title: L10n.imageMergeCopy, target: nil, action: nil)
    private let saveButton = NSButton(title: L10n.imageMergeSave, target: nil, action: nil)
    private let continueButton = NSButton(title: L10n.imageMergeContinueEditing, target: nil, action: nil)
    private weak var controlsScrollView: NSScrollView?

    init(
        document: ImageMergeDocument,
        onContinueEditing: @escaping (NSImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.mergeDocument = document
        self.onContinueEditing = onContinueEditing
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.imageMergeWindowTitle
        window.minSize = NSSize(width: 860, height: 560)
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = buildContentView()
        configureControls()
        refreshAll()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollControlsToTop()
    }

    func appendImages(from urls: [URL]) {
        let result = ImageMergeDocument.loadItems(from: urls)
        mergeDocument.append(result.items)
        mergeDocument.removeInvalidSelectionIfNeeded()
        refreshAll()
        if result.failedCount > 0 {
            ToastWindow.show(message: L10n.imageMergeSomeImagesSkipped)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func buildContentView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.document = mergeDocument
        canvasView.onImportURLs = { [weak self] urls in
            self?.appendImages(from: urls)
        }
        canvasView.onDocumentChanged = { [weak self] in
            self?.refreshAll()
        }
        split.addArrangedSubview(canvasView)

        let controls = buildControlsView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(controls)
        controls.widthAnchor.constraint(greaterThanOrEqualToConstant: 336).isActive = true
        controls.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        return root
    }

    private func buildControlsView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        controlsScrollView = scrollView
        container.addSubview(scrollView)

        let stack = ImageMergeSidebarStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        let imageControls = NSStackView()
        imageControls.orientation = .vertical
        imageControls.spacing = 10
        imageControls.alignment = .leading

        let sourceButtons = NSStackView()
        sourceButtons.orientation = .horizontal
        sourceButtons.spacing = 8
        sourceButtons.alignment = .centerY
        let addFiles = NSButton(title: L10n.imageMergeAddFiles, target: self, action: #selector(addFilesClicked))
        let addClipboard = NSButton(title: L10n.imageMergeAddFromClipboard, target: self, action: #selector(addClipboardClicked))
        addFiles.bezelStyle = .rounded
        addClipboard.bezelStyle = .rounded
        sourceButtons.addArrangedSubview(addFiles)
        sourceButtons.addArrangedSubview(addClipboard)
        imageControls.addArrangedSubview(sourceButtons)

        thumbnailListView.document = mergeDocument
        thumbnailListView.onSelect = { [weak self] in self?.refreshAll() }
        thumbnailListView.onReorder = { [weak self] in self?.refreshAll() }
        let thumbScroll = NSScrollView()
        thumbScroll.hasVerticalScroller = true
        thumbScroll.borderType = .noBorder
        thumbScroll.drawsBackground = false
        thumbScroll.documentView = thumbnailListView
        thumbScroll.translatesAutoresizingMaskIntoConstraints = false
        thumbScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        thumbScroll.widthAnchor.constraint(equalToConstant: 268).isActive = true
        imageControls.addArrangedSubview(thumbScroll)
        stack.addArrangedSubview(section(title: L10n.imageMergeImageList, content: imageControls))

        stack.addArrangedSubview(section(title: L10n.imageMergeTemplate, content: templateChipGrid()))

        stack.addArrangedSubview(section(title: L10n.imageMergeLayout, content: layoutControls()))
        stack.addArrangedSubview(section(title: L10n.imageMergeBackground, content: backgroundControls()))

        let footer = outputControls()
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            footer.widthAnchor.constraint(equalToConstant: 292),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        DispatchQueue.main.async { [weak self] in
            self?.scrollControlsToTop()
        }
        return container
    }

    private func configureControls() {
        for slider in [spacingSlider, marginSlider, cornerSlider] {
            slider.target = self
            slider.action = #selector(layoutSliderChanged)
            slider.controlSize = .small
        }

        backgroundMode.segmentCount = 2
        backgroundMode.setLabel(L10n.imageMergeTransparent, forSegment: 0)
        backgroundMode.setLabel(L10n.imageMergeSolid, forSegment: 1)
        backgroundMode.target = self
        backgroundMode.action = #selector(backgroundModeChanged)

        colorWell.target = self
        colorWell.action = #selector(backgroundColorChanged)
        colorWell.color = .white

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        continueButton.target = self
        continueButton.action = #selector(continueEditingClicked)
        [continueButton, copyButton, saveButton].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .large
        }
        saveButton.bezelColor = .controlAccentColor
    }

    private func layoutControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(sliderRow(title: L10n.imageMergeSpacing, slider: spacingSlider, valueLabel: spacingValueLabel))
        stack.addArrangedSubview(sliderRow(title: L10n.imageMergeMargin, slider: marginSlider, valueLabel: marginValueLabel))
        stack.addArrangedSubview(sliderRow(title: L10n.imageMergeCornerRadius, slider: cornerSlider, valueLabel: cornerValueLabel))
        return stack
    }

    private func templateChipGrid() -> NSView {
        templateButtons.removeAll()

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8

        let rows = [
            Array(ImageMergeTemplate.allCases.prefix(2)),
            Array(ImageMergeTemplate.allCases.dropFirst(2).prefix(2))
        ]

        for templates in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            for template in templates {
                let button = ImageMergeTemplateChipButton(template: template)
                button.target = self
                button.action = #selector(templateChipClicked(_:))
                templateButtons.append(button)
                row.addArrangedSubview(button)
            }

            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 268).isActive = true
        }

        return grid
    }

    private func backgroundControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.addArrangedSubview(backgroundMode)
        stack.addArrangedSubview(colorWell)
        backgroundMode.widthAnchor.constraint(equalToConstant: 206).isActive = true
        return stack
    }

    private func outputControls() -> NSView {
        let footer = ImageMergeSidebarCardView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stack)

        stack.addArrangedSubview(continueButton)
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -12),
            continueButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            copyButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            saveButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return footer
    }

    private func sliderRow(title: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(label)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(valueLabel)
        header.widthAnchor.constraint(equalToConstant: 268).isActive = true

        slider.widthAnchor.constraint(equalToConstant: 268).isActive = true
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(slider)
        return stack
    }

    private func section(title: String, content: NSView) -> NSView {
        let card = ImageMergeSidebarCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(content)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 292),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    private func scrollControlsToTop() {
        guard let scrollView = controlsScrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func refreshAll() {
        canvasView.document = mergeDocument
        thumbnailListView.document = mergeDocument
        thumbnailListView.needsDisplay = true

        for button in templateButtons {
            button.setSelected(button.template == mergeDocument.template)
        }
        spacingSlider.doubleValue = Double(mergeDocument.spacing)
        marginSlider.doubleValue = Double(mergeDocument.margin)
        cornerSlider.doubleValue = Double(mergeDocument.cornerRadius)
        spacingValueLabel.stringValue = String(Int(round(mergeDocument.spacing)))
        marginValueLabel.stringValue = String(Int(round(mergeDocument.margin)))
        cornerValueLabel.stringValue = String(Int(round(mergeDocument.cornerRadius)))

        switch mergeDocument.background {
        case .transparent:
            backgroundMode.selectedSegment = 0
            colorWell.isEnabled = false
        case .solid(let color):
            backgroundMode.selectedSegment = 1
            colorWell.isEnabled = true
            colorWell.color = color
        }

        let canOutput = mergeDocument.canOutput
        copyButton.isEnabled = canOutput
        saveButton.isEnabled = canOutput
        continueButton.isEnabled = canOutput
        canvasView.needsDisplay = true
    }

    @objc private func addFilesClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            self?.appendImages(from: panel.urls)
        }
    }

    @objc private func addClipboardClicked() {
        let urls = ClipboardImageSource.currentImageFileURLs()
        if !urls.isEmpty {
            let result = ImageMergeDocument.loadItems(from: urls)
            guard !result.items.isEmpty else {
                ToastWindow.show(message: L10n.imageMergeNoClipboardImage)
                return
            }
            mergeDocument.append(result.items)
            refreshAll()
            if result.failedCount > 0 {
                ToastWindow.show(message: L10n.imageMergeSomeImagesSkipped)
            }
            return
        }

        guard let image = ClipboardImageSource.currentImage(),
              let item = ImageMergeDocument.item(fromClipboardImage: image)
        else {
            ToastWindow.show(message: L10n.imageMergeNoClipboardImage)
            return
        }
        mergeDocument.append([item])
        refreshAll()
    }

    @objc private func templateChipClicked(_ sender: ImageMergeTemplateChipButton) {
        mergeDocument.template = sender.template
        refreshAll()
    }

    @objc private func layoutSliderChanged() {
        mergeDocument.spacing = CGFloat(spacingSlider.doubleValue.rounded())
        mergeDocument.margin = CGFloat(marginSlider.doubleValue.rounded())
        mergeDocument.cornerRadius = CGFloat(cornerSlider.doubleValue.rounded())
        refreshAll()
    }

    @objc private func backgroundModeChanged() {
        if backgroundMode.selectedSegment == 1 {
            mergeDocument.background = .solid(colorWell.color)
        } else {
            mergeDocument.background = .transparent
        }
        refreshAll()
    }

    @objc private func backgroundColorChanged() {
        if backgroundMode.selectedSegment == 1 {
            mergeDocument.background = .solid(colorWell.color)
        }
        refreshAll()
    }

    @objc private func copyClicked() {
        guard let image = renderOrToast() else { return }
        ClipboardManager.copyToClipboard(image: image)
        HistoryManager.shared.add(image: image)
        ToastWindow.show()
    }

    @objc private func saveClicked() {
        guard let image = renderOrToast() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFilename()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = image.pngDataPreservingBacking() else {
                ToastWindow.show(message: L10n.imageMergeFailed)
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                ToastWindow.show(message: L10n.imageMergeSaved)
            } catch {
                ToastWindow.show(message: L10n.imageMergeFailed)
            }
        }
    }

    @objc private func continueEditingClicked() {
        guard let image = renderOrToast() else { return }
        close()
        onContinueEditing(image)
    }

    private func renderOrToast() -> NSImage? {
        guard mergeDocument.canOutput,
              let image = ImageMergeRenderer.render(document: mergeDocument)
        else {
            ToastWindow.show(message: L10n.imageMergeFailed)
            return nil
        }
        return image
    }

    private func defaultFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "capcap-merge-\(formatter.string(from: date)).png"
    }
}

private final class ImageMergeSidebarStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class ImageMergeTemplateChipButton: NSButton {
    let template: ImageMergeTemplate

    init(template: ImageMergeTemplate) {
        self.template = template
        super.init(frame: .zero)
        title = template.title
        commonInit()
        setSelected(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        updateAppearance()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .rounded
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 13, weight: .semibold)
        alignment = .center
        lineBreakMode = .byTruncatingTail
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    private func updateAppearance() {
        let selected = state == .on
        let textColor = selected
            ? NSColor.white
            : NSColor.labelColor.withAlphaComponent(0.92)
        layer?.backgroundColor = (selected
            ? NSColor.controlAccentColor
            : NSColor.labelColor.withAlphaComponent(0.10)
        ).cgColor
        attributedTitle = NSAttributedString(
            string: template.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: textColor
            ]
        )
    }
}

private final class ImageMergeSidebarCardView: NSView {
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
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 0
    }
}
