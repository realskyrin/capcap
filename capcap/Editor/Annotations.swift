import AppKit

// MARK: - Annotation Protocol

protocol Annotation {
    func draw(in context: CGContext, bounds: NSRect)
}

// MARK: - Pen Annotation

struct PenAnnotation: Annotation {
    let path: NSBezierPath
    let color: NSColor
    let lineWidth: CGFloat

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        color.setStroke()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Mosaic Annotation

struct MosaicAnnotation: Annotation {
    let rect: NSRect
    let pixelatedImage: NSImage

    func draw(in context: CGContext, bounds: NSRect) {
        pixelatedImage.draw(in: rect)
    }
}

// MARK: - Rectangle Annotation

struct RectAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }
}

// MARK: - Ellipse Annotation

struct EllipseAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
    }
}

// MARK: - Arrow Annotation

struct ArrowAnnotation: Annotation {
    let startPoint: NSPoint
    let endPoint: NSPoint
    let color: NSColor
    let lineWidth: CGFloat

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        // Draw line
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.strokePath()

        // Draw arrowhead
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return }

        let headLength: CGFloat = max(12, lineWidth * 4)
        let headWidth: CGFloat = max(8, lineWidth * 3)

        let unitX = dx / length
        let unitY = dy / length

        let baseX = endPoint.x - unitX * headLength
        let baseY = endPoint.y - unitY * headLength

        let leftX = baseX - unitY * headWidth / 2
        let leftY = baseY + unitX * headWidth / 2
        let rightX = baseX + unitY * headWidth / 2
        let rightY = baseY - unitX * headWidth / 2

        context.move(to: endPoint)
        context.addLine(to: CGPoint(x: leftX, y: leftY))
        context.addLine(to: CGPoint(x: rightX, y: rightY))
        context.closePath()
        context.fillPath()
    }
}

// MARK: - Number Annotation

struct NumberAnnotation: Annotation {
    let center: NSPoint
    let number: Int
    let color: NSColor

    func draw(in context: CGContext, bounds: NSRect) {
        let radius: CGFloat = 14
        let circleRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        // Draw filled circle
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circleRect)

        // Draw number text
        let text = "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .bold)
        ]
        let size = text.size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        text.draw(at: textOrigin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
