import AppKit

/// Which toolbar a grid section maps to in `ToolbarLayout`.
enum ToolbarSection {
    case primary
    case side
    case hidden
}

/// Settings tab for customizing the editor toolbars. Shows a live preview of
/// the editor with the current layout, plus three drag-and-drop grids for
/// assigning tools to the main toolbar, the side toolbar, or hiding them.
final class ToolbarSettingsPane: NSView {
    /// Layout currently shown in the grids and preview. Drag edits persist
    /// immediately, so the settings page has no separate apply step.
    private var workingLayout: ToolbarLayout = Defaults.toolbarLayout.normalized()

    private let preview = ToolbarLayoutPreviewView()
    private var previewHeightConstraint: NSLayoutConstraint!
    private var primaryGrid: ToolbarSlotGridView!
    private var sideGrid: ToolbarSlotGridView!
    private var hiddenGrid: ToolbarSlotGridView!

    private let primaryTitle = ToolbarSettingsPane.sectionTitleLabel()
    private let primaryHint = ToolbarSettingsPane.hintLabel()
    private let sideTitle = ToolbarSettingsPane.sectionTitleLabel()
    private let sideHint = ToolbarSettingsPane.hintLabel()
    private let hiddenTitle = ToolbarSettingsPane.sectionTitleLabel()
    private let hiddenHint = ToolbarSettingsPane.hintLabel()
    private let footnote = ToolbarSettingsPane.hintLabel()
    private let resetButton = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        syncFromWorkingLayout()
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

    // MARK: - Build

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Preview card.
        let previewCard = Self.makeCard()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.setContentCompressionResistancePriority(.required, for: .vertical)
        preview.setContentHuggingPriority(.required, for: .vertical)
        previewCard.addSubview(preview)
        previewHeightConstraint = preview.heightAnchor.constraint(equalToConstant: preview.preferredHeight)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 14),
            preview.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 14),
            preview.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -14),
            preview.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -14),
            previewHeightConstraint,
        ])
        stack.addArrangedSubview(previewCard)
        previewCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Sections card — the three drag grids.
        primaryGrid = ToolbarSlotGridView(section: .primary)
        sideGrid = ToolbarSlotGridView(section: .side)
        hiddenGrid = ToolbarSlotGridView(section: .hidden)
        for grid in [primaryGrid, sideGrid, hiddenGrid] {
            grid?.onLayoutChanged = { [weak self] in self?.collectWorkingLayout() }
            grid?.gridProvider = { [weak self] in
                [self?.primaryGrid, self?.sideGrid, self?.hiddenGrid].compactMap { $0 }
            }
        }

        let sectionsCard = Self.makeCard()
        let sectionsStack = NSStackView()
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 8
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false
        sectionsCard.addSubview(sectionsStack)
        NSLayoutConstraint.activate([
            sectionsStack.topAnchor.constraint(equalTo: sectionsCard.topAnchor, constant: 16),
            sectionsStack.leadingAnchor.constraint(equalTo: sectionsCard.leadingAnchor, constant: 16),
            sectionsStack.trailingAnchor.constraint(equalTo: sectionsCard.trailingAnchor, constant: -16),
            sectionsStack.bottomAnchor.constraint(equalTo: sectionsCard.bottomAnchor, constant: -16),
        ])

        addSection(to: sectionsStack, title: primaryTitle, hint: primaryHint, grid: primaryGrid)
        addSection(to: sectionsStack, title: sideTitle, hint: sideHint, grid: sideGrid)
        addSection(to: sectionsStack, title: hiddenTitle, hint: hiddenHint, grid: hiddenGrid)

        footnote.lineBreakMode = .byWordWrapping
        footnote.maximumNumberOfLines = 2
        sectionsStack.setCustomSpacing(14, after: hiddenGrid)
        sectionsStack.addArrangedSubview(footnote)
        footnote.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true

        stack.addArrangedSubview(sectionsCard)
        sectionsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Footer: reset lives at the lower-right. Drag changes apply instantly.
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        Self.styleButton(resetButton, title: "", prominent: false)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(resetButton)

        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])

        applyLocalizedStrings()
    }

    private func addSection(
        to stack: NSStackView,
        title: NSTextField,
        hint: NSTextField,
        grid: ToolbarSlotGridView
    ) {
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(10, after: hint)
        stack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if grid !== hiddenGrid {
            stack.setCustomSpacing(16, after: grid)
        }
    }

    // MARK: - Layout sync

    /// Pushes `workingLayout` into every grid and the preview.
    private func syncFromWorkingLayout() {
        primaryGrid.setItems(workingLayout.primary)
        sideGrid.setItems(workingLayout.side)
        hiddenGrid.setItems(workingLayout.hidden)
        preview.layout = workingLayout
        updatePreviewHeight()
    }

    /// Pulls the current grid contents back into `workingLayout` and refreshes
    /// the preview. Called after every drag-and-drop edit.
    private func collectWorkingLayout() {
        workingLayout = ToolbarLayout(
            primary: primaryGrid.items,
            side: sideGrid.items,
            hidden: hiddenGrid.items
        ).normalized()
        preview.layout = workingLayout
        updatePreviewHeight()
        Defaults.toolbarLayout = workingLayout
    }

    private func updatePreviewHeight() {
        previewHeightConstraint.constant = preview.preferredHeight
    }

    // MARK: - Actions

    @objc private func resetTapped() {
        workingLayout = .default
        syncFromWorkingLayout()
        Defaults.toolbarLayout = workingLayout
    }

    @objc private func onLanguageChanged() {
        applyLocalizedStrings()
    }

    private func applyLocalizedStrings() {
        primaryTitle.stringValue = L10n.toolbarSettingsPrimaryTitle
        primaryHint.stringValue = L10n.toolbarSettingsPrimaryHint
        sideTitle.stringValue = L10n.toolbarSettingsSideTitle
        sideHint.stringValue = L10n.toolbarSettingsSideHint
        hiddenTitle.stringValue = L10n.toolbarSettingsHiddenTitle
        hiddenHint.stringValue = L10n.toolbarSettingsHiddenHint
        footnote.stringValue = L10n.toolbarSettingsFootnote
        resetButton.title = L10n.toolbarSettingsReset
        primaryGrid.refreshTooltips()
        sideGrid.refreshTooltips()
        hiddenGrid.refreshTooltips()
    }

    // MARK: - Shared builders

    private static func makeCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private static func sectionTitleLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func hintLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.45)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func styleButton(_ button: NSButton, title: String, prominent: Bool) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        if prominent {
            button.bezelColor = NSColor.controlAccentColor
        }
    }
}
