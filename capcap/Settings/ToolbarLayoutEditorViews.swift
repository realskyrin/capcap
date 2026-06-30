import AppKit

/// Renders an SF Symbol flat-tinted to a single color.
func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return nil
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    guard let symbol = base.withSymbolConfiguration(config) else { return nil }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    return tinted
}

// MARK: - Tool tile

/// A single draggable tool icon in a `ToolbarSlotGridView`. Pressing it
/// starts a drag handled by the owning grid.
final class ToolbarItemTile: NSView {
    let itemID: ToolbarItemID
    weak var grid: ToolbarSlotGridView?
    private var hoverTip: String?
    private var hoverTrackingArea: NSTrackingArea?

    init(itemID: ToolbarItemID) {
        self.itemID = itemID
        super.init(frame: .zero)
        wantsLayer = true
        refreshTooltip()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func refreshTooltip() {
        hoverTip = itemID.tooltip
    }

    func clearTooltip() {
        hoverTip = nil
        ToolTipWindow.hide()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let tip = hoverTip, let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        ToolTipWindow.show(text: tip, anchor: frameOnScreen)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        ToolTipWindow.hide()
    }

    override func mouseDown(with event: NSEvent) {
        ToolTipWindow.hide()
        grid?.beginDrag(from: self, startEvent: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ToolTipWindow.hide() }
    }

    private var iconColor: NSColor {
        switch itemID {
        case .close:   return toolbarDangerRed
        case .confirm: return accentGreen
        default:       return NSColor.white.withAlphaComponent(0.85)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.08).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        body.lineWidth = 1
        body.stroke()

        if let icon = tintedSymbol(itemID.symbolName, pointSize: 15, color: iconColor) {
            let size = icon.size
            icon.draw(in: NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
    }
}

// MARK: - Slot grid

/// A wrapping grid of tool tiles for one toolbar section, with drag-and-drop
/// reordering both within the grid and across sibling grids.
final class ToolbarSlotGridView: NSView {
    static let tile: CGFloat = 34
    static let gap: CGFloat = 8

    let section: ToolbarSection
    private(set) var items: [ToolbarItemID] = []

    /// Fired after a drag-and-drop edit changes any grid's contents.
    var onLayoutChanged: (() -> Void)?
    /// Supplies all sibling grids so a drag can move tiles across sections.
    var gridProvider: (() -> [ToolbarSlotGridView])?

    /// Insertion point shown during a drag (`nil` when not a drop target).
    var dropIndicator: Int? {
        didSet { if oldValue != dropIndicator { needsLayout = true; needsDisplay = true } }
    }

    private var tiles: [ToolbarItemTile] = []
    private var heightConstraint: NSLayoutConstraint!
    private(set) var columns: Int = 10
    private var animateNextLayout = false

    init(section: ToolbarSection) {
        self.section = section
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightConstraint = heightAnchor.constraint(equalToConstant: rowHeight(rows: 2))
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: Contents

    func setItems(
        _ newItems: [ToolbarItemID],
        animated: Bool = false,
        initialFrames: [ToolbarItemID: NSRect] = [:]
    ) {
        items = newItems
        // Reuse existing tiles by id so layout changes can animate.
        var cache = Dictionary(tiles.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        var reordered: [ToolbarItemTile] = []
        var created = Set<ToolbarItemID>()
        for id in newItems {
            if let existing = cache.removeValue(forKey: id) {
                reordered.append(existing)
            } else {
                let tile = ToolbarItemTile(itemID: id)
                tile.grid = self
                if let frame = initialFrames[id] {
                    tile.frame = frame
                } else if bounds.width > 0 {
                    columns = currentColumns()
                    tile.frame = slotFrame(at: reordered.count)
                }
                addSubview(tile)
                reordered.append(tile)
                created.insert(id)
            }
        }
        for (_, leftover) in cache { leftover.removeFromSuperview() }
        tiles = reordered
        refreshTooltips()
        // Newly created tiles without an explicit drag-start frame get their
        // final frame immediately so they don't animate in from the origin.
        if bounds.width > 0 {
            columns = currentColumns()
            for (index, tile) in tiles.enumerated()
            where created.contains(tile.itemID)
                && initialFrames[tile.itemID] == nil
                && tile.frame == .zero {
                tile.frame = slotFrame(at: index)
            }
        }
        animateNextLayout = animated
        needsLayout = true
        needsDisplay = true
    }

    func refreshTooltips() {
        for tile in tiles {
            tile.refreshTooltip()
        }
    }

    // MARK: Geometry

    private func currentColumns() -> Int {
        max(1, Int((bounds.width + Self.gap) / (Self.tile + Self.gap)))
    }

    private func rowHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * Self.tile + CGFloat(max(0, rows - 1)) * Self.gap
    }

    /// Rows to display — at least 2, and always enough to show the drop bar.
    private var displayRows: Int {
        let slots = max(items.count, dropIndicator.map { $0 + 1 } ?? 0)
        return max(2, Int(ceil(Double(slots) / Double(max(1, columns)))))
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        columns = currentColumns()
        let animated = animateNextLayout
        animateNextLayout = false
        for (index, tile) in tiles.enumerated() {
            let frame = slotFrame(at: index)
            if animated {
                tile.animator().frame = frame
            } else {
                tile.frame = frame
            }
        }
        let height = rowHeight(rows: displayRows)
        if abs(heightConstraint.constant - height) > 0.5 {
            heightConstraint.constant = height
        }
    }

    /// Frame of the slot at a flow index (flipped: row 0 sits at the top).
    func slotFrame(at index: Int) -> NSRect {
        let cols = max(1, columns)
        let col = index % cols
        let row = index / cols
        return NSRect(
            x: CGFloat(col) * (Self.tile + Self.gap),
            y: CGFloat(row) * (Self.tile + Self.gap),
            width: Self.tile,
            height: Self.tile
        )
    }

    /// Insertion index nearest a point in this grid's coordinate space.
    func insertionIndex(at point: NSPoint) -> Int {
        let cell = Self.tile + Self.gap
        let col = Int((point.x + Self.tile / 2) / cell)
        let row = max(0, Int(point.y / cell))
        let index = row * columns + min(max(0, col), columns)
        return min(max(0, index), items.count)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Empty placeholder slots out to the displayed row count.
        let total = displayRows * columns
        if items.count < total {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            for index in items.count..<total {
                let rect = slotFrame(at: index).insetBy(dx: 1, dy: 1)
                let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                path.lineWidth = 1
                path.setLineDash([3, 3], count: 2, phase: 0)
                path.stroke()
            }
        }

        // Drop insertion bar.
        if let indicator = dropIndicator {
            let slot = slotFrame(at: indicator)
            let bar = NSRect(
                x: slot.minX - Self.gap / 2 - 1.5,
                y: slot.minY,
                width: 3,
                height: Self.tile
            )
            accentGreen.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    // MARK: Drag & drop

    /// Runs a modal drag-tracking loop for `tile` until the mouse is released.
    func beginDrag(from tile: ToolbarItemTile, startEvent: NSEvent) {
        guard
            let window,
            let contentView = window.contentView
        else { return }

        let grids = gridProvider?() ?? [self]
        let draggedID = tile.itemID
        let sourceGrid = self
        let sourceIndex = items.firstIndex(of: draggedID) ?? 0

        var ghost: NSView?
        var dragging = false
        var targetGrid: ToolbarSlotGridView?
        var targetIndex = 0

        func startDrag() {
            dragging = true
            // Lift the tile out of its grid so every grid reflows around the gap.
            var src = sourceGrid.items
            if let idx = src.firstIndex(of: draggedID) {
                src.remove(at: idx)
                sourceGrid.setItems(src, animated: true)
            }
            let view = Self.makeGhost(for: draggedID)
            contentView.addSubview(view)
            ghost = view
            NSCursor.closedHand.set()
        }

        func positionGhost(_ event: NSEvent) {
            guard let ghost else { return }
            let point = event.locationInWindow
            ghost.setFrameOrigin(NSPoint(
                x: point.x - ghost.frame.width / 2,
                y: point.y - ghost.frame.height / 2
            ))
        }

        trackingLoop: while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
            else { break }

            switch event.type {
            case .leftMouseDragged:
                if !dragging { startDrag() }
                positionGhost(event)
                let hit = Self.dropTarget(windowPoint: event.locationInWindow, grids: grids)
                targetGrid = hit.grid
                targetIndex = hit.index
                for grid in grids {
                    grid.dropIndicator = (grid === targetGrid) ? targetIndex : nil
                }
            case .leftMouseUp:
                break trackingLoop
            default:
                break
            }
        }

        let ghostFrameInContent = ghost?.frame
        ghost?.removeFromSuperview()
        for grid in grids { grid.dropIndicator = nil }
        NSCursor.arrow.set()

        guard dragging else { return }  // a plain click — nothing moved

        let destGrid = targetGrid ?? sourceGrid
        var destItems = destGrid.items
        // No target grid means the drop landed outside — restore the tile.
        let insertAt = targetGrid == nil
            ? min(sourceIndex, destItems.count)
            : min(max(0, targetIndex), destItems.count)
        destItems.insert(draggedID, at: insertAt)
        let initialFrame = ghostFrameInContent.map { destGrid.convert($0, from: contentView) }
        destGrid.setItems(
            destItems,
            animated: true,
            initialFrames: initialFrame.map { [draggedID: $0] } ?? [:]
        )
        onLayoutChanged?()
    }

    /// Finds the grid (and insertion index) under a window-space point.
    private static func dropTarget(
        windowPoint: NSPoint,
        grids: [ToolbarSlotGridView]
    ) -> (grid: ToolbarSlotGridView?, index: Int) {
        for grid in grids {
            let local = grid.convert(windowPoint, from: nil)
            if grid.bounds.insetBy(dx: -10, dy: -10).contains(local) {
                return (grid, grid.insertionIndex(at: local))
            }
        }
        return (nil, 0)
    }

    /// A lifted copy of a tile that follows the cursor during a drag.
    private static func makeGhost(for id: ToolbarItemID) -> NSView {
        let ghost = ToolbarItemTile(itemID: id)
        ghost.clearTooltip()
        ghost.frame = NSRect(x: 0, y: 0, width: tile, height: tile)
        ghost.alphaValue = 0.95
        ghost.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
        return ghost
    }
}

// MARK: - Layout preview

/// A non-interactive miniature of the editor showing where the current
/// layout places the primary and side toolbars around a selection.
final class ToolbarLayoutPreviewView: NSView {
    var layout: ToolbarLayout = .default {
        didSet {
            invalidateIntrinsicContentSize()
            updateToolbarPreviews()
            needsDisplay = true
        }
    }

    private let primaryScrollView = ToolbarPreviewScrollView(orientation: .horizontal)
    private let primaryStripView = ToolbarPreviewStripView(orientation: .horizontal)
    private let sideScrollView = ToolbarPreviewScrollView(orientation: .vertical)
    private let sideStripView = ToolbarPreviewStripView(orientation: .vertical)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 8
        primaryScrollView.documentView = primaryStripView
        sideScrollView.documentView = sideStripView
        addSubview(primaryScrollView)
        addSubview(sideScrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let miniButton: CGFloat = 15
    private let miniGap: CGFloat = 3
    private let miniPad: CGFloat = 6
    private let minimumHeight: CGFloat = 188
    private let minimumSelectionHeight: CGFloat = 116
    private let maximumSidePreviewItems = ToolbarLayout.default.side.count
    private let topInset: CGFloat = 22
    private let previewMargin: CGFloat = 14
    private let emptyPrimaryBottomInset: CGFloat = 20

    var preferredHeight: CGFloat {
        let sideRun = layout.side.isEmpty ? 0 : capsuleRun(layout.side.count)
        let sideCap = capsuleRun(maximumSidePreviewItems)
        let contentHeight = max(minimumSelectionHeight, min(sideRun, sideCap))
        return max(minimumHeight, bottomInset + topInset + contentHeight)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    /// Length of a toolbar capsule holding `count` mini buttons.
    private func capsuleRun(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * miniButton
            + CGFloat(count - 1) * miniGap
            + miniPad * 2
    }

    private var capsuleThickness: CGFloat { miniButton + miniPad * 2 }
    private var bottomInset: CGFloat {
        layout.primary.isEmpty ? emptyPrimaryBottomInset : capsuleThickness + 16
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolbarPreviews()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateToolbarPreviews()
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // Backdrop — a soft lake-ish gradient standing in for a screenshot.
        if let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.17, green: 0.33, blue: 0.50, alpha: 1),
            NSColor(srgbRed: 0.13, green: 0.42, blue: 0.45, alpha: 1),
        ]) {
            gradient.draw(in: b, angle: -90)
        }

        let selection = selectionRect(in: b)
        guard selection.width > 20, selection.height > 20 else { return }

        let dashed = NSBezierPath(rect: selection)
        dashed.lineWidth = 1.5
        dashed.setLineDash([5, 3], count: 2, phase: 0)
        accentGreen.setStroke()
        dashed.stroke()
        drawHandles(around: selection)
    }

    /// Selection rect leaves room below for the primary toolbar and to the
    /// right for the side toolbar.
    private func selectionRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + 44,
            y: bounds.minY + bottomInset,
            width: bounds.width - 44 - 70,
            height: bounds.height - bottomInset - topInset
        )
    }

    private func updateToolbarPreviews() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let selection = selectionRect(in: bounds)

        updatePrimaryPreview(selection: selection)
        updateSidePreview(selection: selection)
    }

    private func updatePrimaryPreview(selection: NSRect) {
        primaryScrollView.isHidden = layout.primary.isEmpty
        primaryStripView.items = layout.primary
        guard !layout.primary.isEmpty else { return }

        let run = capsuleRun(layout.primary.count)
        let maxWidth = max(capsuleThickness, bounds.width - previewMargin * 2)
        let width = min(run, maxWidth)
        let proposedX = selection.midX - width / 2
        let x = max(previewMargin, min(bounds.maxX - previewMargin - width, proposedX))
        primaryScrollView.frame = NSRect(
            x: x,
            y: selection.minY - 10 - capsuleThickness,
            width: width,
            height: capsuleThickness
        )
        primaryStripView.setFrameSize(NSSize(width: run, height: capsuleThickness))
        primaryScrollView.clampScrollOffset()
    }

    private func updateSidePreview(selection: NSRect) {
        sideScrollView.isHidden = layout.side.isEmpty
        sideStripView.items = layout.side
        guard !layout.side.isEmpty else { return }

        let run = capsuleRun(layout.side.count)
        let height = min(run, max(capsuleThickness, selection.height))
        sideScrollView.frame = NSRect(
            x: selection.maxX + 10,
            y: selection.midY - height / 2,
            width: capsuleThickness,
            height: height
        )
        sideStripView.setFrameSize(NSSize(width: capsuleThickness, height: run))
        sideScrollView.clampScrollOffset()
    }

    private func drawHandles(around rect: NSRect) {
        let points = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.minX, y: rect.midY),
            NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.midX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        accentGreen.setFill()
        for point in points {
            let dot = NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}

private final class ToolbarPreviewScrollView: NSScrollView {
    private let orientation: ToolbarView.Orientation

    init(orientation: ToolbarView.Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasHorizontalScroller = orientation.isHorizontal
        hasVerticalScroller = orientation.isVertical
        horizontalScrollElasticity = orientation.isHorizontal ? .allowed : .none
        verticalScrollElasticity = orientation.isVertical ? .allowed : .none
        usesPredominantAxisScrolling = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clampScrollOffset() {
        guard let documentView else { return }
        let maxX = max(0, documentView.frame.width - contentView.bounds.width)
        let maxY = max(0, documentView.frame.height - contentView.bounds.height)
        var origin = contentView.bounds.origin
        origin.x = max(0, min(maxX, origin.x))
        origin.y = max(0, min(maxY, origin.y))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

private final class ToolbarPreviewStripView: NSView {
    let orientation: ToolbarView.Orientation
    var items: [ToolbarItemID] = [] {
        didSet { needsDisplay = true }
    }

    private let miniButton: CGFloat = 15
    private let miniGap: CGFloat = 3
    private let miniPad: CGFloat = 6

    init(orientation: ToolbarView.Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor(white: 0.12, alpha: 0.95).setFill()
        body.fill()

        for (index, id) in items.enumerated() {
            let slot: NSRect
            switch orientation {
            case .horizontal:
                slot = NSRect(
                    x: miniPad + CGFloat(index) * (miniButton + miniGap),
                    y: miniPad,
                    width: miniButton, height: miniButton
                )
            case .vertical:
                slot = NSRect(
                    x: miniPad,
                    y: miniPad + CGFloat(index) * (miniButton + miniGap),
                    width: miniButton, height: miniButton
                )
            }
            let color: NSColor
            switch id {
            case .close:   color = toolbarDangerRed
            case .confirm: color = accentGreen
            default:       color = .white
            }
            if let icon = tintedSymbol(id.symbolName, pointSize: 9, color: color) {
                let size = icon.size
                icon.draw(in: NSRect(
                    x: slot.midX - size.width / 2,
                    y: slot.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
        }
    }
}

private extension ToolbarView.Orientation {
    var isHorizontal: Bool {
        if case .horizontal = self { return true }
        return false
    }

    var isVertical: Bool { !isHorizontal }
}
