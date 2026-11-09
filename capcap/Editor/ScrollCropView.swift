import AppKit

/// Crop overlay shown after a long-screenshot scroll capture. The whole
/// stitched image is scaled to fit on screen so the user sees all of it at
/// once; only the top and bottom edges move — the width is fixed.
///
/// At fit scale a long screenshot shrinks to a thin sliver, so dragging an
/// edge pops a full-width preview at the cut line, letting the user place it
/// exactly without losing horizontal context.
final class ScrollCropView: NSView {
    private let image: NSImage
    private let cgImage: CGImage?

    private enum Edge { case top, bottom }

    // Geometry, recomputed on layout. `imageFrame` is the on-screen rect the
    // scaled image occupies; `cropTop`/`cropBottom` are the cut lines, all in
    // this view's flipped (top-left origin) coordinates.
    private var imageFrame: NSRect = .zero
    private var cropTop: CGFloat = 0
    private var cropBottom: CGFloat = 0
    private var scaledImage: NSImage?
    private var lastLaidOutSize: NSSize = .zero

    private var activeEdge: Edge?

    private let accent = NSColor(red: 0, green: 212.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)
    private let outerMargin: CGFloat = 80
    private let minimumImageInset: CGFloat = 24
    private let minimumCropHeight: CGFloat = 12
    private let edgeHitInset: CGFloat = 16
    private let edgePreviewGap: CGFloat = 44
    private let edgePreviewInset: CGFloat = 16
    private let edgePreviewHeight: CGFloat = 190
    private let edgePreviewMaxWidth: CGFloat = 720
    private let edgePreviewMaxWidthFraction: CGFloat = 0.54

    init(frame frameRect: NSRect, image: NSImage) {
        self.image = image
        self.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: frameRect)
        recomputeLayout(resetCrop: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeLayout(resetCrop: false)
    }

    // MARK: - Result

    /// Kept band in the original image's unflipped, point-based coordinates.
    /// Round in backing pixels first so annotations and bitmap share one cut.
    var croppedImageRect: NSRect {
        guard imageFrame.height > 0, let cg = cgImage else {
            return NSRect(origin: .zero, size: image.size)
        }
        let topFraction = max(0, min(1, (cropTop - imageFrame.minY) / imageFrame.height))
        let bottomFraction = max(topFraction, min(1, (cropBottom - imageFrame.minY) / imageFrame.height))
        let height = CGFloat(cg.height)
        let pxTop = min(height - 1, (topFraction * height).rounded())
        let pxBottom = min(height, max(pxTop + 1, (bottomFraction * height).rounded()))
        let scaleY = height / max(image.size.height, 1)
        return NSRect(
            x: 0, y: (height - pxBottom) / scaleY,
            width: image.size.width, height: (pxBottom - pxTop) / scaleY
        )
    }

    /// The stitched image cropped to the current top/bottom selection.
    func croppedImage() -> NSImage {
        guard let cg = cgImage else { return image }
        let rect = croppedImageRect
        let scaleY = CGFloat(cg.height) / max(image.size.height, 1)
        // CGImage crops from the top; editor annotations use a bottom origin.
        let band = CGRect(
            x: 0, y: ((image.size.height - rect.maxY) * scaleY).rounded(),
            width: CGFloat(cg.width), height: (rect.height * scaleY).rounded()
        )
        guard let cropped = cg.cropping(to: band) else { return image }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    // MARK: - Layout

    private func recomputeLayout(resetCrop: Bool) {
        guard resetCrop || bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size

        let fractions = resetCrop ? nil : currentCropFractions()

        let preferredEdgePreviewSize = edgePreviewSize()
        let fullAvailableW = max(1, bounds.width - outerMargin * 2)
        let reservedPreviewAvailableW = bounds.width
            - minimumImageInset
            - edgePreviewInset
            - edgePreviewGap
            - preferredEdgePreviewSize.width
        let availableW = max(1, reservedPreviewAvailableW > 0
            ? min(fullAvailableW, reservedPreviewAvailableW)
            : fullAvailableW)
        let availableH = max(1, bounds.height - outerMargin * 2)
        let imgW = max(1, image.size.width)
        let imgH = max(1, image.size.height)
        // Fit the whole image; never upscale past 1:1.
        let scale = min(availableW / imgW, availableH / imgH, 1)
        let drawSize = NSSize(width: imgW * scale, height: imgH * scale)

        let centeredX = ((bounds.width - drawSize.width) / 2).rounded()
        let maxXForRightPreview = (
            bounds.maxX
            - edgePreviewInset
            - edgePreviewGap
            - preferredEdgePreviewSize.width
            - drawSize.width
        ).rounded()
        let imageX = max(bounds.minX + minimumImageInset, min(centeredX, maxXForRightPreview))

        imageFrame = NSRect(
            x: imageX,
            y: ((bounds.height - drawSize.height) / 2).rounded(),
            width: drawSize.width,
            height: drawSize.height
        )

        if let fractions {
            cropTop = imageFrame.minY + fractions.lowerBound * imageFrame.height
            cropBottom = imageFrame.minY + fractions.upperBound * imageFrame.height
        } else {
            cropTop = imageFrame.minY
            cropBottom = imageFrame.maxY
        }

        scaledImage = makeScaledImage(targetSize: imageFrame.size)
        needsDisplay = true
    }

    private func currentCropFractions() -> ClosedRange<CGFloat>? {
        guard imageFrame.height > 0 else { return nil }
        let lo = (cropTop - imageFrame.minY) / imageFrame.height
        let hi = (cropBottom - imageFrame.minY) / imageFrame.height
        return Swift.min(lo, hi)...Swift.max(lo, hi)
    }

    /// Pre-renders the heavily down-scaled image once so per-frame redraws
    /// (especially during a drag) just blit a small bitmap.
    private func makeScaledImage(targetSize: NSSize) -> NSImage? {
        guard targetSize.width >= 1, targetSize.height >= 1 else { return nil }
        let scaled = NSImage(size: targetSize)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()

        guard imageFrame.width > 0 else { return }

        // `respectFlipped: true` is required — the plain draw(in:from:...)
        // ignores the view's flipped state and renders the image upside down.
        scaledImage?.draw(
            in: imageFrame,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        // Dim the trimmed-away strips.
        NSColor(white: 0, alpha: 0.62).setFill()
        NSRect(
            x: imageFrame.minX, y: imageFrame.minY,
            width: imageFrame.width, height: cropTop - imageFrame.minY
        ).fill()
        NSRect(
            x: imageFrame.minX, y: cropBottom,
            width: imageFrame.width, height: imageFrame.maxY - cropBottom
        ).fill()

        // Kept-region border.
        accent.setStroke()
        let border = NSBezierPath(rect: NSRect(
            x: imageFrame.minX, y: cropTop,
            width: imageFrame.width, height: cropBottom - cropTop
        ))
        border.lineWidth = 2
        border.stroke()

        drawHandle(atY: cropTop)
        drawHandle(atY: cropBottom)

        if let activeEdge {
            drawEdgePreview(forEdge: activeEdge)
        }
    }

    private func drawHandle(atY y: CGFloat) {
        accent.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 2
        line.move(to: NSPoint(x: imageFrame.minX, y: y))
        line.line(to: NSPoint(x: imageFrame.maxX, y: y))
        line.stroke()

        let tab = NSRect(x: imageFrame.midX - 24, y: y - 7, width: 48, height: 14)
        accent.setFill()
        NSBezierPath(roundedRect: tab, xRadius: 7, yRadius: 7).fill()
        NSColor.white.setFill()
        for dx in [-7.0, 0.0, 7.0] {
            NSBezierPath(ovalIn: NSRect(
                x: tab.midX + dx - 1.5, y: tab.midY - 1.5, width: 3, height: 3
            )).fill()
        }
    }

    /// Draws a full-width preview of the image at the cut line so the user can
    /// crop precisely despite the tiny fit-scaled overview.
    private func drawEdgePreview(forEdge edge: Edge) {
        guard let cg = cgImage else { return }
        let lineY = (edge == .top) ? cropTop : cropBottom
        let fraction = clamp((lineY - imageFrame.minY) / max(imageFrame.height, 1), 0, 1)

        let previewRect = edgePreviewFrame(forLineY: lineY)
        let previewScale = previewRect.width / max(image.size.width, 1)
        let pixelScaleY = CGFloat(cg.height) / max(image.size.height, 1)
        let bandH = min((previewRect.height / max(previewScale, 0.01)) * pixelScaleY, CGFloat(cg.height))
        let centerPx = fraction * CGFloat(cg.height)
        let bandY = clamp(centerPx - bandH / 2, 0, max(0, CGFloat(cg.height) - bandH))
        let band = CGRect(x: 0, y: bandY, width: CGFloat(cg.width), height: bandH)

        NSColor(white: 0.1, alpha: 0.96).setFill()
        NSBezierPath(
            roundedRect: previewRect.insetBy(dx: -10, dy: -10),
            xRadius: 12, yRadius: 12
        ).fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: previewRect).addClip()
        NSColor.black.setFill()
        previewRect.fill()
        if let cropped = cg.cropping(to: band) {
            NSImage(cgImage: cropped, size: previewRect.size).draw(
                in: previewRect,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        // Cut-line marker — tracks the real cut position even when the band
        // was clamped against the top or bottom of the image.
        let markerFraction = bandH > 0 ? (centerPx - bandY) / bandH : 0.5
        let markerY = previewRect.minY + markerFraction * previewRect.height
        NSColor.systemRed.setStroke()
        let marker = NSBezierPath()
        marker.lineWidth = 2
        marker.move(to: NSPoint(x: previewRect.minX, y: markerY))
        marker.line(to: NSPoint(x: previewRect.maxX, y: markerY))
        marker.stroke()

        accent.setStroke()
        let frame = NSBezierPath(rect: previewRect)
        frame.lineWidth = 1.5
        frame.stroke()
    }

    private func edgePreviewFrame(forLineY lineY: CGFloat) -> NSRect {
        let rightMaxWidth = bounds.maxX - edgePreviewInset - (imageFrame.maxX + edgePreviewGap)
        var size = rightMaxWidth >= 1 ? edgePreviewSize(constrainedTo: rightMaxWidth) : .zero
        var x = imageFrame.maxX + edgePreviewGap

        if size.width < 1 {
            let leftMaxWidth = imageFrame.minX - edgePreviewGap - edgePreviewInset
            size = leftMaxWidth >= 1 ? edgePreviewSize(constrainedTo: leftMaxWidth) : .zero
            x = imageFrame.minX - edgePreviewGap - size.width
        }

        guard size.width >= 1 else {
            return NSRect(x: bounds.maxX, y: lineY, width: 0, height: edgePreviewHeight)
        }

        var y = lineY - size.height / 2
        y = clamp(y, bounds.minY + edgePreviewInset, bounds.maxY - edgePreviewInset - size.height)

        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func edgePreviewSize(constrainedTo maxWidth: CGFloat? = nil) -> NSSize {
        let viewCappedWidth = min(edgePreviewMaxWidth, max(1, bounds.width * edgePreviewMaxWidthFraction))
        let constraint = maxWidth ?? viewCappedWidth
        guard constraint >= 1 else { return .zero }

        let rawWidth = min(max(1, image.size.width), viewCappedWidth, constraint)
        let width = max(1, rawWidth.rounded(.down))
        return NSSize(width: width, height: edgePreviewHeight)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeEdge = edge(at: point)
        if activeEdge != nil {
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeEdge else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch activeEdge {
        case .top:
            cropTop = clamp(point.y, imageFrame.minY, cropBottom - minimumCropHeight)
        case .bottom:
            cropBottom = clamp(point.y, cropTop + minimumCropHeight, imageFrame.maxY)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activeEdge = nil
        needsDisplay = true
    }

    private func edge(at point: NSPoint) -> Edge? {
        guard point.x >= imageFrame.minX - 36, point.x <= imageFrame.maxX + 36 else {
            return nil
        }
        let nearTop = abs(point.y - cropTop)
        let nearBottom = abs(point.y - cropBottom)
        if nearTop <= edgeHitInset && nearTop <= nearBottom { return .top }
        if nearBottom <= edgeHitInset { return .bottom }
        return nil
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (edge(at: point) != nil ? NSCursor.resizeUpDown : NSCursor.arrow).set()
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.max(lower, Swift.min(upper, value))
    }
}
