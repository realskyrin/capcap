import AppKit

// MARK: - Annotation Protocol

protocol Annotation {
    func draw(in context: CGContext, bounds: NSRect)

    /// True when the point is on (or close enough to) this annotation that
    /// the user can grab it for moving. For stroke-based shapes this is the
    /// stroke band only — the interior is intentionally transparent so the
    /// user can click through to whatever is behind.
    func containsPoint(_ point: NSPoint) -> Bool

    /// Returns a copy of this annotation translated by `delta`. Used while
    /// the user drags an existing annotation.
    func translated(by delta: NSPoint) -> Annotation
}

private let strokeHitTolerance: CGFloat = 8

private func strokedPathContains(_ path: CGPath, point: NSPoint, lineWidth: CGFloat) -> Bool {
    let width = max(strokeHitTolerance, lineWidth + 4)
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return stroked.contains(point)
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

    func containsPoint(_ point: NSPoint) -> Bool {
        strokedPathContains(path.cgPath, point: point, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        let copy = path.copy() as! NSBezierPath
        var transform = AffineTransform.identity
        transform.translate(x: delta.x, y: delta.y)
        copy.transform(using: transform)
        return PenAnnotation(path: copy, color: color, lineWidth: lineWidth)
    }
}

// MARK: - Mosaic Annotation

struct MosaicAnnotation: Annotation {
    let rect: NSRect
    let pixelatedImage: NSImage

    func draw(in context: CGContext, bounds: NSRect) {
        pixelatedImage.draw(in: rect)
    }

    // Mosaic is treated as "pasted on" — once placed it can't be dragged.
    func containsPoint(_ point: NSPoint) -> Bool { false }
    func translated(by delta: NSPoint) -> Annotation { self }
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

    func containsPoint(_ point: NSPoint) -> Bool {
        let path = CGPath(rect: rect, transform: nil)
        return strokedPathContains(path, point: point, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        RectAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            color: color,
            lineWidth: lineWidth
        )
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

    func containsPoint(_ point: NSPoint) -> Bool {
        let path = CGPath(ellipseIn: rect, transform: nil)
        return strokedPathContains(path, point: point, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EllipseAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            color: color,
            lineWidth: lineWidth
        )
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

    func containsPoint(_ point: NSPoint) -> Bool {
        let line = CGMutablePath()
        line.move(to: startPoint)
        line.addLine(to: endPoint)
        if strokedPathContains(line, point: point, lineWidth: lineWidth) {
            return true
        }

        // Also count clicks inside the filled arrowhead triangle.
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return false }

        let headLength: CGFloat = max(12, lineWidth * 4)
        let headWidth: CGFloat = max(8, lineWidth * 3)
        let unitX = dx / length
        let unitY = dy / length
        let baseX = endPoint.x - unitX * headLength
        let baseY = endPoint.y - unitY * headLength

        let head = CGMutablePath()
        head.move(to: endPoint)
        head.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
        head.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
        head.closeSubpath()
        return head.contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        ArrowAnnotation(
            startPoint: NSPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y),
            endPoint: NSPoint(x: endPoint.x + delta.x, y: endPoint.y + delta.y),
            color: color,
            lineWidth: lineWidth
        )
    }
}

// MARK: - Text Annotation

struct TextAnnotation: Annotation {
    let text: String
    /// Bottom-left of the editing/drawing frame, in canvas coordinates.
    let origin: NSPoint
    let color: NSColor
    let fontSize: CGFloat

    static let trailingCaretPadding: CGFloat = 12
    static let minimumEditorWidth: CGFloat = 32

    static func font(forSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .bold)
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func editorSize(for text: String, font: NSFont) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textToMeasure = text.isEmpty ? "M" : text
        let measured = (textToMeasure as NSString).size(withAttributes: attrs)
        return NSSize(
            width: max(ceil(measured.width) + trailingCaretPadding, minimumEditorWidth),
            height: lineHeight(for: font)
        )
    }

    /// Editing-frame bounds of the rendered text, used for hit-testing.
    ///
    /// This intentionally mirrors `EditableTextField.sizeToFitText()` instead
    /// of using only the bare glyph size, so a committed text mark can be
    /// double-clicked anywhere in the same region the user just edited.
    var textBounds: NSRect {
        let size = TextAnnotation.editorSize(for: text, font: TextAnnotation.font(forSize: fontSize))
        return NSRect(origin: origin, size: size)
    }

    var hitBounds: NSRect {
        textBounds.insetBy(dx: -10, dy: -max(10, fontSize * 0.75))
    }

    func draw(in context: CGContext, bounds: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: TextAnnotation.font(forSize: fontSize)
        ]
        NSGraphicsContext.saveGraphicsState()
        text.draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        hitBounds.contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        TextAnnotation(
            text: text,
            origin: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize
        )
    }
}

// MARK: - Number Annotation

struct NumberAnnotation: Annotation {
    let center: NSPoint
    let number: Int
    let color: NSColor

    static let radius: CGFloat = 14

    func draw(in context: CGContext, bounds: NSRect) {
        let radius = NumberAnnotation.radius
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

    func containsPoint(_ point: NSPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = NumberAnnotation.radius
        return dx * dx + dy * dy <= r * r
    }

    func translated(by delta: NSPoint) -> Annotation {
        NumberAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            number: number,
            color: color
        )
    }
}
