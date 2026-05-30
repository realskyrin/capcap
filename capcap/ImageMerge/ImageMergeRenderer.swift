import AppKit

struct ImageMergeItemLayout {
    let id: UUID
    let slotRect: NSRect
    let imageRect: NSRect
    let image: NSImage
}

struct ImageMergeLayout {
    let canvasSize: NSSize
    let itemLayouts: [ImageMergeItemLayout]
}

enum ImageMergeRenderer {
    static func layout(for document: ImageMergeDocument) -> ImageMergeLayout {
        guard !document.items.isEmpty else {
            return ImageMergeLayout(canvasSize: NSSize(width: 720, height: 420), itemLayouts: [])
        }

        let baseSlots = makeBaseSlots(for: document)
        var unionRect: NSRect?
        let rawLayouts: [ImageMergeItemLayout] = zip(document.items, baseSlots).map { item, slot in
            let scale = min(max(item.scale, 0.2), 4.0)
            let drawSize = NSSize(width: slot.baseSize.width * scale, height: slot.baseSize.height * scale)
            let imageRect = NSRect(
                x: slot.rect.midX - drawSize.width / 2 + item.offset.x,
                y: slot.rect.midY - drawSize.height / 2 + item.offset.y,
                width: drawSize.width,
                height: drawSize.height
            )
            unionRect = (unionRect ?? slot.rect).union(slot.rect).union(imageRect)
            return ImageMergeItemLayout(id: item.id, slotRect: slot.rect, imageRect: imageRect, image: item.image)
        }

        let content = unionRect ?? .zero
        let margin = max(0, document.margin)
        let shift = NSPoint(x: margin - content.minX, y: margin - content.minY)
        let layouts = rawLayouts.map { layout in
            ImageMergeItemLayout(
                id: layout.id,
                slotRect: layout.slotRect.offsetBy(dx: shift.x, dy: shift.y),
                imageRect: layout.imageRect.offsetBy(dx: shift.x, dy: shift.y),
                image: layout.image
            )
        }
        let size = NSSize(
            width: ceil(content.width + margin * 2),
            height: ceil(content.height + margin * 2)
        )
        return ImageMergeLayout(canvasSize: size, itemLayouts: layouts)
    }

    static func render(document: ImageMergeDocument) -> NSImage? {
        let layout = layout(for: document)
        let width = max(1, Int(ceil(layout.canvasSize.width)))
        let height = max(1, Int(ceil(layout.canvasSize.height)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))

        if case .solid(let color) = document.background {
            color.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
        }

        drawItems(
            layout.itemLayouts,
            canvasHeight: CGFloat(height),
            cornerRadius: document.cornerRadius
        )

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func drawPreview(
        document: ImageMergeDocument,
        in canvasRect: NSRect,
        selectedItemID: UUID?
    ) {
        let layout = layout(for: document)
        guard layout.canvasSize.width > 0, layout.canvasSize.height > 0 else { return }
        let scale = min(canvasRect.width / layout.canvasSize.width, canvasRect.height / layout.canvasSize.height)
        let outputRect = NSRect(
            x: canvasRect.midX - layout.canvasSize.width * scale / 2,
            y: canvasRect.midY - layout.canvasSize.height * scale / 2,
            width: layout.canvasSize.width * scale,
            height: layout.canvasSize.height * scale
        )

        drawPreviewBackground(for: document, in: outputRect)

        for itemLayout in layout.itemLayouts {
            let rect = previewRect(for: itemLayout.imageRect, outputRect: outputRect, scale: scale, canvasHeight: layout.canvasSize.height)
            drawImage(itemLayout.image, in: rect, cornerRadius: document.cornerRadius * scale)
            if itemLayout.id == selectedItemID {
                drawSelection(in: rect)
            }
        }
    }

    static func previewGeometry(for document: ImageMergeDocument, in canvasRect: NSRect) -> (layout: ImageMergeLayout, outputRect: NSRect, scale: CGFloat)? {
        let layout = layout(for: document)
        guard layout.canvasSize.width > 0, layout.canvasSize.height > 0 else { return nil }
        let scale = min(canvasRect.width / layout.canvasSize.width, canvasRect.height / layout.canvasSize.height)
        let outputRect = NSRect(
            x: canvasRect.midX - layout.canvasSize.width * scale / 2,
            y: canvasRect.midY - layout.canvasSize.height * scale / 2,
            width: layout.canvasSize.width * scale,
            height: layout.canvasSize.height * scale
        )
        return (layout, outputRect, scale)
    }

    static func previewRect(for layoutRect: NSRect, outputRect: NSRect, scale: CGFloat, canvasHeight: CGFloat) -> NSRect {
        NSRect(
            x: outputRect.minX + layoutRect.minX * scale,
            y: outputRect.maxY - layoutRect.maxY * scale,
            width: layoutRect.width * scale,
            height: layoutRect.height * scale
        )
    }

    static func layoutPoint(from viewPoint: NSPoint, outputRect: NSRect, scale: CGFloat, canvasHeight: CGFloat) -> NSPoint {
        NSPoint(
            x: (viewPoint.x - outputRect.minX) / scale,
            y: (outputRect.maxY - viewPoint.y) / scale
        )
    }

    private struct BaseSlot {
        let rect: NSRect
        let baseSize: NSSize
    }

    private static func makeBaseSlots(for document: ImageMergeDocument) -> [BaseSlot] {
        switch document.template {
        case .horizontal:
            var x: CGFloat = 0
            return document.items.map { item in
                let size = item.originalSize
                let rect = NSRect(origin: NSPoint(x: x, y: 0), size: size)
                x += size.width + document.spacing
                return BaseSlot(rect: rect, baseSize: size)
            }
        case .vertical:
            var y: CGFloat = 0
            return document.items.map { item in
                let size = item.originalSize
                let rect = NSRect(origin: NSPoint(x: 0, y: y), size: size)
                y += size.height + document.spacing
                return BaseSlot(rect: rect, baseSize: size)
            }
        case .grid:
            return makeGridSlots(for: document)
        case .longStitch:
            return makeLongStitchSlots(for: document)
        }
    }

    private static func makeGridSlots(for document: ImageMergeDocument) -> [BaseSlot] {
        let count = document.items.count
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let commonWidth = max(1, document.items.map(\.originalSize.width).max() ?? 1)
        let baseSizes = document.items.map { item -> NSSize in
            let aspect = max(0.0001, item.originalSize.height / item.originalSize.width)
            return NSSize(width: commonWidth, height: commonWidth * aspect)
        }
        let rowCount = Int(ceil(Double(count) / Double(columns)))
        var rowHeights = Array(repeating: CGFloat(0), count: rowCount)
        for (index, size) in baseSizes.enumerated() {
            rowHeights[index / columns] = max(rowHeights[index / columns], size.height)
        }

        var slots: [BaseSlot] = []
        var y: CGFloat = 0
        for row in 0..<rowCount {
            let rowHeight = rowHeights[row]
            for column in 0..<columns {
                let index = row * columns + column
                guard index < count else { continue }
                let x = CGFloat(column) * (commonWidth + document.spacing)
                let slotRect = NSRect(x: x, y: y, width: commonWidth, height: rowHeight)
                slots.append(BaseSlot(rect: slotRect, baseSize: baseSizes[index]))
            }
            y += rowHeight + document.spacing
        }
        return slots
    }

    private static func makeLongStitchSlots(for document: ImageMergeDocument) -> [BaseSlot] {
        let commonWidth = max(1, document.items.map(\.originalSize.width).max() ?? 1)
        var y: CGFloat = 0
        return document.items.map { item in
            let aspect = max(0.0001, item.originalSize.height / item.originalSize.width)
            let size = NSSize(width: commonWidth, height: commonWidth * aspect)
            let rect = NSRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + document.spacing
            return BaseSlot(rect: rect, baseSize: size)
        }
    }

    private static func drawItems(_ itemLayouts: [ImageMergeItemLayout], canvasHeight: CGFloat, cornerRadius: CGFloat) {
        for layout in itemLayouts {
            let flippedRect = NSRect(
                x: layout.imageRect.minX,
                y: canvasHeight - layout.imageRect.maxY,
                width: layout.imageRect.width,
                height: layout.imageRect.height
            )
            drawImage(layout.image, in: flippedRect, cornerRadius: cornerRadius)
        }
    }

    private static func drawImage(_ image: NSImage, in rect: NSRect, cornerRadius: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        let radius = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
        if radius > 0 {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawPreviewBackground(for document: ImageMergeDocument, in rect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -8), xRadius: 12, yRadius: 12).fill()

        switch document.background {
        case .transparent:
            drawCheckerboard(in: rect)
        case .solid(let color):
            color.setFill()
            rect.fill()
        }
    }

    private static func drawCheckerboard(in rect: NSRect) {
        let square: CGFloat = 14
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX
            var column = 0
            while x < rect.maxX {
                let isLight = (row + column).isMultiple(of: 2)
                (isLight ? NSColor(calibratedWhite: 0.88, alpha: 1) : NSColor(calibratedWhite: 0.72, alpha: 1)).setFill()
                NSRect(x: x, y: y, width: min(square, rect.maxX - x), height: min(square, rect.maxY - y)).fill()
                x += square
                column += 1
            }
            y += square
            row += 1
        }
    }

    private static func drawSelection(in rect: NSRect) {
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()

        let handle = NSRect(x: rect.maxX - 8, y: rect.minY - 8, width: 16, height: 16)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        NSBezierPath(roundedRect: handle.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).stroke()
    }
}
