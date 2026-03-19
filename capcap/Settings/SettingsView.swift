import AppKit

class SettingsView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        // Title label
        let titleLabel = NSTextField(labelWithString: "Screenshot Tool")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 24, y: 120, width: 200, height: 20)
        addSubview(titleLabel)

        // Description
        let descLabel = NSTextField(wrappingLabelWithString: "Take a screenshot by double-tapping ⌘ Command.\nDraw a selection, annotate with tools, then confirm to copy to clipboard.")
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: 24, y: 60, width: 310, height: 50)
        addSubview(descLabel)

        // Shortcut info
        let shortcutLabel = NSTextField(labelWithString: "Trigger: Double-tap ⌘ Command")
        shortcutLabel.font = NSFont.systemFont(ofSize: 12)
        shortcutLabel.textColor = .labelColor
        shortcutLabel.frame = NSRect(x: 24, y: 20, width: 310, height: 20)
        addSubview(shortcutLabel)
    }
}
