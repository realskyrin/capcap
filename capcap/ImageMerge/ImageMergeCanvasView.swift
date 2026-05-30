import AppKit

final class ImageMergeCanvasView: NSView {
    var document: ImageMergeDocument? {
        didSet {
            needsDisplay = true
        }
    }
    var onImportURLs: (([URL]) -> Void)?
    var onDocumentChanged: (() -> Void)?

    private enum DragMode {
        case move(id: UUID, startPoint: NSPoint, startOffset: NSPoint)
        case resize(id: UUID, startPoint: NSPoint, startScale: CGFloat, center: NSPoint)
    }

    private var dragMode: DragMode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let document else { return }
        if document.items.isEmpty {
            drawEmptyState()
            return
        }

        let insetRect = bounds.insetBy(dx: 28, dy: 28)
        ImageMergeRenderer.drawPreview(
            document: document,
            in: insetRect,
            selectedItemID: document.selectedItemID
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let document,
              !document.items.isEmpty,
              let geometry = currentGeometry()
        else { return }

        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let layoutPoint = ImageMergeRenderer.layoutPoint(
            from: viewPoint,
            outputRect: geometry.outputRect,
            scale: geometry.scale,
            canvasHeight: geometry.layout.canvasSize.height
        )

        for itemLayout in geometry.layout.itemLayouts.reversed() {
            let previewRect = ImageMergeRenderer.previewRect(
                for: itemLayout.imageRect,
                outputRect: geometry.outputRect,
                scale: geometry.scale,
                canvasHeight: geometry.layout.canvasSize.height
            )
            if resizeHandle(for: previewRect).contains(viewPoint),
               let item = document.items.first(where: { $0.id == itemLayout.id }) {
                document.select(itemLayout.id)
                let center = NSPoint(x: itemLayout.imageRect.midX, y: itemLayout.imageRect.midY)
                dragMode = .resize(
                    id: itemLayout.id,
                    startPoint: layoutPoint,
                    startScale: item.scale,
                    center: center
                )
                onDocumentChanged?()
                return
            }
            if itemLayout.imageRect.contains(layoutPoint),
               let item = document.items.first(where: { $0.id == itemLayout.id }) {
                document.select(itemLayout.id)
                dragMode = .move(id: itemLayout.id, startPoint: layoutPoint, startOffset: item.offset)
                onDocumentChanged?()
                return
            }
        }

        document.select(nil)
        dragMode = nil
        onDocumentChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document,
              let geometry = currentGeometry(),
              let dragMode
        else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let layoutPoint = ImageMergeRenderer.layoutPoint(
            from: viewPoint,
            outputRect: geometry.outputRect,
            scale: geometry.scale,
            canvasHeight: geometry.layout.canvasSize.height
        )

        switch dragMode {
        case .move(let id, let startPoint, let startOffset):
            let delta = NSPoint(x: layoutPoint.x - startPoint.x, y: layoutPoint.y - startPoint.y)
            document.updateAdjustment(
                for: id,
                offset: NSPoint(x: startOffset.x + delta.x, y: startOffset.y + delta.y)
            )
        case .resize(let id, let startPoint, let startScale, let center):
            let startDistance = max(12, hypot(startPoint.x - center.x, startPoint.y - center.y))
            let currentDistance = max(12, hypot(layoutPoint.x - center.x, layoutPoint.y - center.y))
            document.updateAdjustment(for: id, scale: startScale * currentDistance / startDistance)
        }

        onDocumentChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggedFileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onImportURLs?(urls)
        return true
    }

    private func currentGeometry() -> (layout: ImageMergeLayout, outputRect: NSRect, scale: CGFloat)? {
        guard let document else { return nil }
        return ImageMergeRenderer.previewGeometry(for: document, in: bounds.insetBy(dx: 28, dy: 28))
    }

    private func resizeHandle(for imageRect: NSRect) -> NSRect {
        NSRect(x: imageRect.maxX - 10, y: imageRect.minY - 10, width: 20, height: 20)
    }

    private func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls
    }

    private func drawEmptyState() {
        let title = L10n.imageMergeEmptyTitle
        let body = L10n.imageMergeEmptyBody
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let titleSize = title.size(withAttributes: titleAttrs)
        let bodySize = body.size(withAttributes: bodyAttrs)
        let centerY = bounds.midY + 18

        title.draw(
            at: NSPoint(x: bounds.midX - titleSize.width / 2, y: centerY),
            withAttributes: titleAttrs
        )
        body.draw(
            at: NSPoint(x: bounds.midX - bodySize.width / 2, y: centerY - 30),
            withAttributes: bodyAttrs
        )
    }
}

final class ImageMergeThumbnailListView: NSView {
    var document: ImageMergeDocument? {
        didSet { rebuildHeight() }
    }
    var onReorder: (() -> Void)?
    var onSelect: (() -> Void)?

    private var rowRects: [UUID: NSRect] = [:]
    private var dragSourceIndex: Int?
    private let rowHeight: CGFloat = 58

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        rowRects.removeAll()

        guard let document else { return }
        for (index, item) in document.items.enumerated() {
            let y = bounds.height - CGFloat(index + 1) * rowHeight
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight - 6)
            rowRects[item.id] = rect
            drawRow(item: item, index: index, in: rect, selected: item.id == document.selectedItemID)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        for (index, item) in document.items.enumerated() {
            if rowRects[item.id]?.contains(point) == true {
                document.select(item.id)
                dragSourceIndex = index
                needsDisplay = true
                onSelect?()
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let sourceIndex = dragSourceIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        for (targetIndex, item) in document.items.enumerated() {
            if rowRects[item.id]?.contains(point) == true, targetIndex != sourceIndex {
                document.reorderItem(from: sourceIndex, to: targetIndex)
                dragSourceIndex = targetIndex
                onReorder?()
                needsDisplay = true
                return
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragSourceIndex = nil
    }

    private func rebuildHeight() {
        let count = max(2, document?.items.count ?? 0)
        setFrameSize(NSSize(width: frame.width, height: CGFloat(count) * rowHeight))
        needsDisplay = true
    }

    private func drawRow(item: ImageMergeItem, index: Int, in rect: NSRect, selected: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()

        let thumbRect = NSRect(x: rect.minX + 8, y: rect.minY + 7, width: 44, height: 44)
        NSColor(calibratedWhite: 0.15, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 5, yRadius: 5).fill()
        drawThumbnail(item.image, in: thumbRect.insetBy(dx: 3, dy: 3))

        let title = "\(index + 1). \(item.displayName)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let titleRect = NSRect(x: thumbRect.maxX + 8, y: rect.midY - 8, width: rect.width - thumbRect.maxX - 20, height: 18)
        title.draw(in: titleRect, withAttributes: attrs)
    }

    private func drawThumbnail(_ image: NSImage, in rect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
