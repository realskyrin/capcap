import AppKit

class SettingsView: NSView {
    private var modeSelector: NSSegmentedControl!

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        // Title label
        let titleLabel = NSTextField(labelWithString: "Capture Mode")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 24, y: 140, width: 200, height: 20)
        addSubview(titleLabel)

        // Mode selector
        modeSelector = NSSegmentedControl(labels: ["Direct (Clipboard)", "Edit First"], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeSelector.frame = NSRect(x: 24, y: 105, width: 310, height: 28)
        modeSelector.selectedSegment = Defaults.captureMode == .direct ? 0 : 1
        addSubview(modeSelector)

        // Description
        let descLabel = NSTextField(wrappingLabelWithString: "Direct: screenshot is copied to clipboard immediately.\nEdit: annotate with pen/mosaic before copying.")
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: 24, y: 55, width: 310, height: 40)
        addSubview(descLabel)

        // Shortcut info
        let shortcutLabel = NSTextField(labelWithString: "Trigger: Double-tap ⌘ Command")
        shortcutLabel.font = NSFont.systemFont(ofSize: 12)
        shortcutLabel.textColor = .labelColor
        shortcutLabel.frame = NSRect(x: 24, y: 20, width: 310, height: 20)
        addSubview(shortcutLabel)
    }

    @objc private func modeChanged() {
        Defaults.captureMode = modeSelector.selectedSegment == 0 ? .direct : .edit
    }
}
