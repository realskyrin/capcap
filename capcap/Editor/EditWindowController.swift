import AppKit

class EditWindowController {
    private var toolbarPanel: NSPanel?
    private var subToolbarPanel: NSPanel?
    private var canvasWindow: NSWindow?
    private var canvasView: EditCanvasView?
    private var toolbarView: ToolbarView?
    private var captureRect: CGRect
    private var screen: NSScreen
    private var selectionRect: NSRect
    private let onComplete: (NSImage?) -> Void
    private var activeTool: EditTool = .none

    // Drawing properties
    private var currentColor: NSColor = .red
    private var currentLineWidth: CGFloat = 3.0
    private var currentMosaicBlockSize: CGFloat = 12.0

    init(captureRect: CGRect, screen: NSScreen, selectionRect: NSRect, onComplete: @escaping (NSImage?) -> Void) {
        self.captureRect = captureRect
        self.screen = screen
        self.selectionRect = selectionRect
        self.onComplete = onComplete
    }

    func show() {
        // Create canvas window overlaying the selection
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: selectionRect.size))
        canvas.captureRect = captureRect
        canvas.captureScreen = screen
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

        showToolbar()
    }

    private func showToolbar() {
        let toolbarHeight: CGFloat = 44
        let toolbarWidth: CGFloat = 480
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
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = .none

        let tv = ToolbarView(frame: NSRect(origin: .zero, size: toolbarRect.size))
        tv.onToolSelected = { [weak self] tool in self?.selectTool(tool) }
        tv.onUndo = { [weak self] in self?.canvasView?.undo() }
        tv.onSave = { [weak self] in self?.save() }
        tv.onPin = { [weak self] in self?.pin() }
        tv.onClose = { [weak self] in self?.close() }
        tv.onConfirm = { [weak self] in self?.confirm() }
        panel.contentView = tv
        self.toolbarView = tv

        panel.orderFrontRegardless()
        self.toolbarPanel = panel
    }

    func updateLayout(selectionRect: NSRect, captureRect: CGRect) {
        self.selectionRect = selectionRect
        self.captureRect = captureRect

        // Update canvas
        canvasWindow?.setFrame(selectionRect, display: true)
        canvasView?.frame = NSRect(origin: .zero, size: selectionRect.size)
        canvasView?.captureRect = captureRect
        canvasView?.needsDisplay = true

        // Update toolbar position
        let toolbarHeight: CGFloat = 44
        let toolbarWidth: CGFloat = toolbarPanel?.frame.width ?? 480
        let toolbarX = selectionRect.midX - toolbarWidth / 2
        let toolbarY = selectionRect.origin.y - toolbarHeight - 8
        toolbarPanel?.setFrameOrigin(NSPoint(x: toolbarX, y: toolbarY))

        // Update sub-toolbar position
        updateSubToolbarPosition()
    }

    private func selectTool(_ tool: EditTool) {
        activeTool = tool
        canvasView?.activeTool = tool
        canvasView?.currentColor = currentColor
        canvasView?.currentLineWidth = currentLineWidth
        canvasView?.currentMosaicBlockSize = currentMosaicBlockSize
        toolbarView?.updateSelection(tool: tool)

        showSubToolbar(for: tool)

        // Make canvas key again after toolbar interaction
        canvasWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSubToolbar(for tool: EditTool) {
        subToolbarPanel?.orderOut(nil)
        subToolbarPanel = nil

        switch tool {
        case .pen, .rectangle, .ellipse, .arrow:
            showColorSizeSubToolbar()
        case .mosaic:
            showMosaicSubToolbar()
        default:
            break
        }
    }

    private func showColorSizeSubToolbar() {
        let subHeight: CGFloat = 36
        let subWidth: CGFloat = 300
        guard let toolbarFrame = toolbarPanel?.frame else { return }
        let subX = toolbarFrame.midX - subWidth / 2
        let subY = toolbarFrame.origin.y - subHeight - 4

        let subRect = NSRect(x: subX, y: subY, width: subWidth, height: subHeight)
        let panel = createSubPanel(frame: subRect)

        let view = ColorSizeSubToolbar(frame: NSRect(origin: .zero, size: subRect.size))
        view.currentColor = currentColor
        view.currentLineWidth = currentLineWidth
        view.onColorChanged = { [weak self] color in
            self?.currentColor = color
            self?.canvasView?.currentColor = color
        }
        view.onSizeChanged = { [weak self] size in
            self?.currentLineWidth = size
            self?.canvasView?.currentLineWidth = size
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        subToolbarPanel = panel
    }

    private func showMosaicSubToolbar() {
        let subHeight: CGFloat = 36
        let subWidth: CGFloat = 220
        guard let toolbarFrame = toolbarPanel?.frame else { return }
        let subX = toolbarFrame.midX - subWidth / 2
        let subY = toolbarFrame.origin.y - subHeight - 4

        let subRect = NSRect(x: subX, y: subY, width: subWidth, height: subHeight)
        let panel = createSubPanel(frame: subRect)

        let view = MosaicSubToolbar(frame: NSRect(origin: .zero, size: subRect.size))
        view.currentBlockSize = currentMosaicBlockSize
        view.onSizeChanged = { [weak self] size in
            self?.currentMosaicBlockSize = size
            self?.canvasView?.currentMosaicBlockSize = size
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        subToolbarPanel = panel
    }

    private func createSubPanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        return panel
    }

    private func updateSubToolbarPosition() {
        guard let subPanel = subToolbarPanel, let toolbarFrame = toolbarPanel?.frame else { return }
        let subWidth = subPanel.frame.width
        let subX = toolbarFrame.midX - subWidth / 2
        let subY = toolbarFrame.origin.y - subPanel.frame.height - 4
        subPanel.setFrameOrigin(NSPoint(x: subX, y: subY))
    }

    private func save() {
        guard let baseImage = ScreenCapturer.capture(rect: captureRect, screen: screen) else { return }
        guard let finalImage = canvasView?.compositeImage(baseImage: baseImage) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "screenshot.png"
        savePanel.level = .screenSaver + 3

        if savePanel.runModal() == .OK, let url = savePanel.url {
            if let tiffData = finalImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiffData),
               let pngData = rep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }

    private func pin() {
        // Pin screenshot to screen as floating window
        guard let baseImage = ScreenCapturer.capture(rect: captureRect, screen: screen) else { return }
        guard let finalImage = canvasView?.compositeImage(baseImage: baseImage) else { return }

        let pinWindow = NSWindow(
            contentRect: selectionRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        pinWindow.level = .floating
        pinWindow.isOpaque = false
        pinWindow.backgroundColor = .clear
        pinWindow.isMovableByWindowBackground = true
        pinWindow.hasShadow = true

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: selectionRect.size))
        imageView.image = finalImage
        imageView.imageScaling = .scaleAxesIndependently
        pinWindow.contentView = imageView
        pinWindow.makeKeyAndOrderFront(nil)

        tearDown()
        onComplete(nil) // Don't copy to clipboard for pin
    }

    private func close() {
        tearDown()
        onComplete(nil)
    }

    private func confirm() {
        guard let baseImage = ScreenCapturer.capture(rect: captureRect, screen: screen) else {
            tearDown()
            onComplete(nil)
            return
        }
        let finalImage = canvasView?.compositeImage(baseImage: baseImage)
        tearDown()
        onComplete(finalImage)
    }

    func tearDown() {
        canvasWindow?.orderOut(nil)
        canvasWindow = nil
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        subToolbarPanel?.orderOut(nil)
        subToolbarPanel = nil
    }
}

// MARK: - Main Toolbar View

private let accentGreen = NSColor(red: 0, green: 212.0/255.0, blue: 106.0/255.0, alpha: 1.0)

class ToolbarView: NSView {
    var onToolSelected: ((EditTool) -> Void)?
    var onUndo: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var toolButtons: [(EditTool, ToolButton)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateSelection(tool: EditTool) {
        for (btnTool, btn) in toolButtons {
            btn.isSelected = (btnTool == tool)
        }
    }

    private func setupButtons() {
        let buttonSize: CGFloat = 32
        let spacing: CGFloat = 6
        // 12 buttons: rect, ellipse, arrow, pen, mosaic, text, numbered, undo | save, pin, cancel, confirm
        let totalButtons = 12
        let separatorWidth: CGFloat = 8
        let totalWidth = CGFloat(totalButtons) * buttonSize + CGFloat(totalButtons - 1) * spacing + separatorWidth
        var x = (bounds.width - totalWidth) / 2
        let y = (bounds.height - buttonSize) / 2

        // Tool buttons (toggleable annotation tools)
        let tools: [(EditTool, String)] = [
            (.rectangle, "rectangle"),
            (.ellipse, "circle"),
            (.arrow, "arrow.up.right"),
            (.pen, "pencil.tip"),
            (.mosaic, "square.grid.3x3"),
            (.text, "textformat"),
            (.numbered, "1.circle"),
        ]

        for (tool, symbol) in tools {
            let btn = ToolButton(
                frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
                symbolName: symbol,
                normalColor: .white,
                selectedColor: accentGreen
            )
            btn.target = self
            btn.action = #selector(toolTapped(_:))
            btn.tag = toolButtons.count
            addSubview(btn)
            toolButtons.append((tool, btn))
            x += buttonSize + spacing
        }

        // Undo button
        let undoBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "arrow.uturn.backward",
            normalColor: .white,
            selectedColor: .white
        )
        undoBtn.target = self
        undoBtn.action = #selector(undoTapped)
        addSubview(undoBtn)
        x += buttonSize + spacing + separatorWidth

        // Save button
        let saveBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "square.and.arrow.down",
            normalColor: .white,
            selectedColor: .white
        )
        saveBtn.target = self
        saveBtn.action = #selector(saveTapped)
        addSubview(saveBtn)
        x += buttonSize + spacing

        // Pin button
        let pinBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "pin",
            normalColor: .white,
            selectedColor: .white
        )
        pinBtn.target = self
        pinBtn.action = #selector(pinTapped)
        addSubview(pinBtn)
        x += buttonSize + spacing

        // Cancel button (red)
        let closeBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "xmark",
            normalColor: NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0),
            selectedColor: NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
        )
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        addSubview(closeBtn)
        x += buttonSize + spacing

        // Confirm button (green)
        let confirmBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "checkmark",
            normalColor: accentGreen,
            selectedColor: accentGreen
        )
        confirmBtn.target = self
        confirmBtn.action = #selector(confirmTapped)
        addSubview(confirmBtn)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }

    @objc private func toolTapped(_ sender: ToolButton) {
        let index = sender.tag
        guard index < toolButtons.count else { return }
        let (tool, _) = toolButtons[index]
        onToolSelected?(tool)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func pinTapped() { onPin?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func confirmTapped() { onConfirm?() }
}

// MARK: - Tool Button

class ToolButton: NSButton {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    private let normalColor: NSColor
    private let selectedColor: NSColor

    init(frame: NSRect, symbolName: String, normalColor: NSColor, selectedColor: NSColor) {
        self.normalColor = normalColor
        self.selectedColor = selectedColor
        super.init(frame: frame)

        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
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
            contentTintColor = selectedColor
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.15).setFill()
            bgPath.fill()
        } else {
            contentTintColor = normalColor
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Color + Size Sub-toolbar

private class ColorSizeSubToolbar: NSView {
    var currentColor: NSColor = .red
    var currentLineWidth: CGFloat = 3.0
    var onColorChanged: ((NSColor) -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?

    private var sizeButtons: [NSView] = []
    private var colorButtons: [NSView] = []

    private let sizes: [CGFloat] = [2, 4, 6]
    private let colors: [NSColor] = [
        NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),   // Red
        NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),    // Blue
        NSColor(red: 0.0, green: 0.83, blue: 0.42, alpha: 1.0),   // Green
        NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),     // Yellow
        .white,
        NSColor(white: 0.5, alpha: 1.0),                           // Gray
        .black,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x: CGFloat = 12
        let midY = bounds.midY

        // Size dots
        for (i, size) in sizes.enumerated() {
            let dotSize = 6 + CGFloat(i) * 4  // 6, 10, 14
            let dot = SizeDotView(
                frame: NSRect(x: x - dotSize/2 + 8, y: midY - dotSize/2, width: dotSize, height: dotSize),
                isSelected: abs(currentLineWidth - size) < 0.5
            )
            dot.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(sizeTapped(_:)))
            dot.addGestureRecognizer(click)
            addSubview(dot)
            sizeButtons.append(dot)
            x += dotSize + 10
        }

        x += 8

        // Separator
        let sep = NSView(frame: NSRect(x: x, y: 6, width: 1, height: bounds.height - 12))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        addSubview(sep)
        x += 9

        // Color swatches
        let swatchSize: CGFloat = 18
        for (i, color) in colors.enumerated() {
            let swatch = ColorSwatchView(
                frame: NSRect(x: x, y: midY - swatchSize/2, width: swatchSize, height: swatchSize),
                color: color,
                isSelected: colorsMatch(color, currentColor)
            )
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(colorTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            colorButtons.append(swatch)
            x += swatchSize + 5
        }
    }

    @objc private func sizeTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? SizeDotView else { return }
        let index = view.itemIndex
        guard index < sizes.count else { return }
        currentLineWidth = sizes[index]
        onSizeChanged?(currentLineWidth)
        updateSizeSelection()
    }

    @objc private func colorTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? ColorSwatchView else { return }
        let index = view.itemIndex
        guard index < colors.count else { return }
        currentColor = colors[index]
        onColorChanged?(currentColor)
        updateColorSelection()
    }

    private func updateSizeSelection() {
        for (i, view) in sizeButtons.enumerated() {
            (view as? SizeDotView)?.isSelected = abs(currentLineWidth - sizes[i]) < 0.5
        }
    }

    private func updateColorSelection() {
        for (i, view) in colorButtons.enumerated() {
            (view as? ColorSwatchView)?.isSelected = colorsMatch(colors[i], currentColor)
        }
    }

    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.deviceRGB), let bc = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(ac.redComponent - bc.redComponent) < 0.01 &&
               abs(ac.greenComponent - bc.greenComponent) < 0.01 &&
               abs(ac.blueComponent - bc.blueComponent) < 0.01
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }
}

// MARK: - Mosaic Sub-toolbar

private class MosaicSubToolbar: NSView {
    var currentBlockSize: CGFloat = 12.0
    var onSizeChanged: ((CGFloat) -> Void)?

    private var sizeButtons: [NSView] = []
    private let sizes: [CGFloat] = [8, 12, 18]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        var x: CGFloat = 12
        let midY = bounds.midY

        // Size dots
        for (i, size) in sizes.enumerated() {
            let dotSize = 6 + CGFloat(i) * 4
            let dot = SizeDotView(
                frame: NSRect(x: x - dotSize/2 + 8, y: midY - dotSize/2, width: dotSize, height: dotSize),
                isSelected: abs(currentBlockSize - size) < 0.5
            )
            dot.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(sizeTapped(_:)))
            dot.addGestureRecognizer(click)
            addSubview(dot)
            sizeButtons.append(dot)
            x += dotSize + 10
        }
    }

    @objc private func sizeTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? SizeDotView else { return }
        let index = view.itemIndex
        guard index < sizes.count else { return }
        currentBlockSize = sizes[index]
        onSizeChanged?(currentBlockSize)
        for (i, v) in sizeButtons.enumerated() {
            (v as? SizeDotView)?.isSelected = (i == index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }
}

// MARK: - Size Dot View

private class SizeDotView: NSView {
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0

    init(frame: NSRect, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = isSelected ? accentGreen : NSColor.white.withAlphaComponent(0.6)
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Color Swatch View

private class ColorSwatchView: NSView {
    let color: NSColor
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0

    init(frame: NSRect, color: NSColor, isSelected: Bool) {
        self.color = color
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Draw color circle
        let inset: CGFloat = isSelected ? 1 : 2
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        color.setFill()
        path.fill()

        if isSelected {
            // Draw green selection ring
            let ring = NSBezierPath(ovalIn: bounds)
            accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }

        // Draw border for white/light colors
        if color == .white || color == NSColor(white: 0.5, alpha: 1.0) {
            let border = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.gray.withAlphaComponent(0.3).setStroke()
            border.lineWidth = 0.5
            border.stroke()
        }
    }
}
