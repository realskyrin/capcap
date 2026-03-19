import AppKit

class EditCanvasView: NSView {
    var baseImage: NSImage?
    var activeTool: EditTool = .none

    private var penStrokes: [PenStroke] = []
    private var currentPenPath: NSBezierPath?
    private var mosaicRegions: [MosaicRegion] = []
    private var currentMosaicPoints: [NSPoint] = []

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard activeTool != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch activeTool {
        case .none:
            return
        case .pen:
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: point)
            currentPenPath = path

        case .mosaic:
            currentMosaicPoints = [point]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch activeTool {
        case .none:
            return
        case .pen:
            currentPenPath?.line(to: point)
            needsDisplay = true

        case .mosaic:
            currentMosaicPoints.append(point)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool != .none else { return }
        switch activeTool {
        case .none:
            return
        case .pen:
            if let path = currentPenPath {
                penStrokes.append(PenStroke(
                    path: path,
                    color: NSColor.red,
                    lineWidth: CGFloat(Defaults.penWidth)
                ))
                currentPenPath = nil
            }

        case .mosaic:
            if !currentMosaicPoints.isEmpty, let baseImage = baseImage {
                let region = MosaicTool.createMosaicRegion(
                    points: currentMosaicPoints,
                    brushRadius: 15,
                    imageSize: bounds.size,
                    baseImage: baseImage
                )
                if let region = region {
                    mosaicRegions.append(region)
                }
                currentMosaicPoints = []
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw base image
        if let image = baseImage {
            image.draw(in: bounds)
        }

        // Draw white selection border
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2.0)
        context.stroke(bounds.insetBy(dx: 1, dy: 1))

        // Draw mosaic regions
        for region in mosaicRegions {
            region.pixelatedImage.draw(in: region.rect)
        }

        // Draw completed pen strokes
        for stroke in penStrokes {
            stroke.color.setStroke()
            stroke.path.lineWidth = stroke.lineWidth
            stroke.path.stroke()
        }

        // Draw current pen stroke in progress
        if let path = currentPenPath {
            NSColor.red.setStroke()
            path.lineWidth = CGFloat(Defaults.penWidth)
            path.stroke()
        }

        // Draw mosaic preview (points being brushed)
        if !currentMosaicPoints.isEmpty {
            context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            for point in currentMosaicPoints {
                context.fillEllipse(in: NSRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30))
            }
        }
    }

    func compositeImage() -> NSImage? {
        guard let baseImage = baseImage else { return nil }

        let size = bounds.size
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw base
        baseImage.draw(in: NSRect(origin: .zero, size: size))

        // Draw mosaic regions
        for region in mosaicRegions {
            region.pixelatedImage.draw(in: region.rect)
        }

        // Draw pen strokes
        for stroke in penStrokes {
            stroke.color.setStroke()
            stroke.path.lineWidth = stroke.lineWidth
            stroke.path.stroke()
        }

        image.unlockFocus()
        return image
    }
}
