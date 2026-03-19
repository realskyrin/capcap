import AppKit

enum EditTool {
    case none
    case pen
    case mosaic
}

class EditWindowController {
    private var toolbarPanel: NSPanel?
    private var canvasWindow: NSWindow?
    private var canvasView: EditCanvasView?
    private var toolbarView: ToolbarView?
    private let image: NSImage
    private let selectionRect: NSRect
    private let onComplete: (NSImage?) -> Void
    private var activeTool: EditTool = .none

    init(image: NSImage, selectionRect: NSRect, onComplete: @escaping (NSImage?) -> Void) {
        self.image = image
        self.selectionRect = selectionRect
        self.onComplete = onComplete
    }

    func show() {
        // Create canvas window overlaying the selection
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: selectionRect.size))
        canvas.baseImage = image
        self.canvasView = canvas

        let canvasWin = NSWindow(
            contentRect: selectionRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        canvasWin.level = .screenSaver + 1
        canvasWin.isOpaque = false
        canvasWin.backgroundColor = .clear
        canvasWin.contentView = canvas
        canvasWin.sharingType = .none
        canvasWin.makeKeyAndOrderFront(nil)
        self.canvasWindow = canvasWin

        // Create toolbar panel below selection
        let toolbarHeight: CGFloat = 44
        let toolbarWidth: CGFloat = 200
        let toolbarX = selectionRect.midX - toolbarWidth / 2
        let toolbarY = selectionRect.origin.y - toolbarHeight - 8

        let toolbarRect = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)

        let panel = NSPanel(
            contentRect: toolbarRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true

        let tv = ToolbarView(frame: NSRect(origin: .zero, size: toolbarRect.size))
        tv.onPen = { [weak self] in self?.selectTool(.pen) }
        tv.onMosaic = { [weak self] in self?.selectTool(.mosaic) }
        tv.onClose = { [weak self] in self?.close() }
        tv.onConfirm = { [weak self] in self?.confirm() }
        panel.contentView = tv
        self.toolbarView = tv

        panel.orderFrontRegardless()
        self.toolbarPanel = panel
    }

    private func selectTool(_ tool: EditTool) {
        activeTool = tool
        canvasView?.activeTool = tool
        toolbarView?.updateSelection(tool: tool)
    }

    private func close() {
        tearDown()
        onComplete(nil)
    }

    private func confirm() {
        let finalImage = canvasView?.compositeImage()
        tearDown()
        onComplete(finalImage)
    }

    private func tearDown() {
        canvasWindow?.orderOut(nil)
        canvasWindow = nil
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
    }
}

// MARK: - Toolbar View

private class ToolbarView: NSView {
    var onPen: (() -> Void)?
    var onMosaic: (() -> Void)?
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var penBtn: ToolButton!
    private var mosaicBtn: ToolButton!

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateSelection(tool: EditTool) {
        penBtn.isSelected = (tool == .pen)
        mosaicBtn.isSelected = (tool == .mosaic)
    }

    private func setupButtons() {
        let buttonSize: CGFloat = 32
        let spacing: CGFloat = 12
        let totalWidth = buttonSize * 4 + spacing * 3
        var x = (bounds.width - totalWidth) / 2
        let y = (bounds.height - buttonSize) / 2

        // Pen button (toggleable)
        penBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "pencil.tip",
            normalColor: .white,
            selectedBgColor: NSColor.white.withAlphaComponent(0.25)
        )
        penBtn.target = self
        penBtn.action = #selector(penTapped)
        addSubview(penBtn)
        x += buttonSize + spacing

        // Mosaic button (toggleable)
        mosaicBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "square.grid.3x3",
            normalColor: .white,
            selectedBgColor: NSColor.white.withAlphaComponent(0.25)
        )
        mosaicBtn.target = self
        mosaicBtn.action = #selector(mosaicTapped)
        addSubview(mosaicBtn)
        x += buttonSize + spacing

        // Close button (red)
        let closeBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "xmark",
            normalColor: NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0),
            selectedBgColor: .clear
        )
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        addSubview(closeBtn)
        x += buttonSize + spacing

        // Confirm button (green)
        let confirmBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "checkmark",
            normalColor: NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0),
            selectedBgColor: .clear
        )
        confirmBtn.target = self
        confirmBtn.action = #selector(confirmTapped)
        addSubview(confirmBtn)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        NSColor(white: 0.15, alpha: 0.9).setFill()
        path.fill()
    }

    @objc private func penTapped() { onPen?() }
    @objc private func mosaicTapped() { onMosaic?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func confirmTapped() { onConfirm?() }
}

// MARK: - Tool Button with selected state

private class ToolButton: NSButton {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private let normalColor: NSColor
    private let selectedBgColor: NSColor

    init(frame: NSRect, symbolName: String, normalColor: NSColor, selectedBgColor: NSColor) {
        self.normalColor = normalColor
        self.selectedBgColor = selectedBgColor
        super.init(frame: frame)

        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            image = img.withSymbolConfiguration(config)
        }

        contentTintColor = normalColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            // Draw selected background circle
            let bgPath = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            selectedBgColor.setFill()
            bgPath.fill()
        }

        // Draw the icon
        super.draw(dirtyRect)
    }
}
