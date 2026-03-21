import AppKit

enum EditTool {
    case none
    case pen
    case mosaic
    case rectangle
    case ellipse
    case arrow
    case numbered
    case scrollCapture
}

class EditCanvasView: NSView {
    var captureRect: CGRect?
    var captureScreen: NSScreen?
    var activeTool: EditTool = .none
    private(set) var previewImage: NSImage?

    // Current drawing properties (set by toolbar)
    var currentColor: NSColor = .red
    var currentLineWidth: CGFloat = 3.0
    var currentMosaicBlockSize: CGFloat = 12.0

    // Annotations stack (supports undo)
    private var annotations: [Annotation] = []

    // In-progress drawing state
    private var currentPenPath: NSBezierPath?
    private var currentMosaicPoints: [NSPoint] = []
    private var mosaicBaseImage: NSImage?
    private var shapeStart: NSPoint?
    private var shapeCurrent: NSPoint?
    private var numberCounter: Int = 1
    
    var hasPreviewImage: Bool { previewImage != nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While previewing a merged long screenshot, keep the canvas interactive
        // so scroll-wheel gestures stay inside the preview viewport.
        guard activeTool != .none || hasPreviewImage else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Undo

    func undo() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        // If it was a number annotation, decrement counter
        if removed is NumberAnnotation {
            numberCounter = max(1, numberCounter - 1)
        }
        needsDisplay = true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        guard activeTool != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch activeTool {
        case .none, .scrollCapture:
            return

        case .pen:
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: point)
            currentPenPath = path

        case .mosaic:
            mosaicBaseImage = resolveBaseImageForEditing()
            currentMosaicPoints = [point]

        case .rectangle, .ellipse, .arrow:
            shapeStart = point
            shapeCurrent = point

        case .numbered:
            let annotation = NumberAnnotation(
                center: point,
                number: numberCounter,
                color: currentColor
            )
            annotations.append(annotation)
            numberCounter += 1
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != .none else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch activeTool {
        case .none, .numbered, .scrollCapture:
            return

        case .pen:
            currentPenPath?.line(to: point)
            needsDisplay = true

        case .mosaic:
            currentMosaicPoints.append(point)
            needsDisplay = true

        case .rectangle, .ellipse, .arrow:
            shapeCurrent = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .numbered, .scrollCapture:
            return

        case .pen:
            if let path = currentPenPath {
                annotations.append(PenAnnotation(
                    path: path,
                    color: currentColor,
                    lineWidth: currentLineWidth
                ))
                currentPenPath = nil
            }

        case .mosaic:
            if !currentMosaicPoints.isEmpty, let baseImage = mosaicBaseImage {
                let brushRadius = currentMosaicBlockSize * 1.5
                if let region = MosaicTool.createMosaicRegion(
                    points: currentMosaicPoints,
                    brushRadius: brushRadius,
                    imageSize: bounds.size,
                    baseImage: baseImage,
                    blockSize: currentMosaicBlockSize
                ) {
                    annotations.append(MosaicAnnotation(
                        rect: region.rect,
                        pixelatedImage: region.pixelatedImage
                    ))
                }
                currentMosaicPoints = []
            }

        case .rectangle:
            if let start = shapeStart, let end = shapeCurrent {
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    annotations.append(RectAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .ellipse:
            if let start = shapeStart, let end = shapeCurrent {
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    annotations.append(EllipseAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .arrow:
            if let start = shapeStart, let end = shapeCurrent {
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 5 {
                    annotations.append(ArrowAnnotation(
                        startPoint: start,
                        endPoint: end,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil
        }

        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let previewImage {
            previewImage.draw(in: NSRect(origin: .zero, size: bounds.size))
        }

        // Draw all committed annotations
        for annotation in annotations {
            annotation.draw(in: context, bounds: bounds)
        }

        // Draw in-progress pen stroke
        if let path = currentPenPath {
            currentColor.setStroke()
            path.lineWidth = currentLineWidth
            path.stroke()
        }

        // Draw in-progress shape preview
        if let start = shapeStart, let current = shapeCurrent {
            context.setStrokeColor(currentColor.cgColor)
            context.setLineWidth(currentLineWidth)

            switch activeTool {
            case .rectangle:
                let rect = rectFromTwoPoints(start, current)
                context.stroke(rect)
            case .ellipse:
                let rect = rectFromTwoPoints(start, current)
                context.strokeEllipse(in: rect)
            case .arrow:
                // Draw line preview
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: current)
                context.strokePath()
                // Draw arrowhead preview
                let dx = current.x - start.x
                let dy = current.y - start.y
                let length = sqrt(dx * dx + dy * dy)
                if length > 0 {
                    let headLength: CGFloat = max(12, currentLineWidth * 4)
                    let headWidth: CGFloat = max(8, currentLineWidth * 3)
                    let unitX = dx / length
                    let unitY = dy / length
                    let baseX = current.x - unitX * headLength
                    let baseY = current.y - unitY * headLength
                    context.setFillColor(currentColor.cgColor)
                    context.move(to: current)
                    context.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
                    context.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
                    context.closePath()
                    context.fillPath()
                }
            default:
                break
            }
        }

        // Draw mosaic preview (points being brushed)
        if !currentMosaicPoints.isEmpty {
            let brushRadius = currentMosaicBlockSize * 1.5
            context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            for point in currentMosaicPoints {
                context.fillEllipse(in: NSRect(
                    x: point.x - brushRadius,
                    y: point.y - brushRadius,
                    width: brushRadius * 2,
                    height: brushRadius * 2
                ))
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasPreviewImage else {
            super.scrollWheel(with: event)
            return
        }

        enclosingScrollView?.scrollWheel(with: event)
    }

    // MARK: - Composite

    func compositeImage(fallbackBaseImage: NSImage?) -> NSImage? {
        guard let baseImage = previewImage ?? fallbackBaseImage else { return nil }
        guard !annotations.isEmpty else { return baseImage }

        guard
            let compositeRep = baseImage.bitmapImageRepPreservingBacking(),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: compositeRep)
        else {
            return baseImage
        }

        let imageBounds = NSRect(origin: .zero, size: baseImage.size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high

        let context = graphicsContext.cgContext
        for annotation in annotations {
            annotation.draw(in: context, bounds: imageBounds)
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: baseImage.size)
        image.addRepresentation(compositeRep)
        return image
    }

    func loadPreviewImage(_ image: NSImage) {
        cancelInFlightInteraction()
        previewImage = image
        mosaicBaseImage = nil
        frame = NSRect(origin: .zero, size: image.size)
        needsDisplay = true
    }

    func updateViewportSize(_ size: NSSize) {
        guard !hasPreviewImage else { return }
        frame = NSRect(origin: .zero, size: size)
        needsDisplay = true
    }

    // MARK: - Helpers

    private func resolveBaseImageForEditing() -> NSImage? {
        if let previewImage {
            return previewImage
        }

        guard let rect = captureRect, let screen = captureScreen else { return nil }
        return ScreenCapturer.capture(rect: rect, screen: screen)
    }

    private func cancelInFlightInteraction() {
        currentPenPath = nil
        currentMosaicPoints = []
        mosaicBaseImage = nil
        shapeStart = nil
        shapeCurrent = nil
    }

    private func rectFromTwoPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
