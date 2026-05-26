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

    /// Axis-aligned bounding box used for selection handles and rotation
    /// pivots. Computed in canvas coordinates.
    var boundingRect: NSRect { get }

    /// Current rotation angle in radians, applied around `boundingRect` mid.
    var rotation: CGFloat { get }

    /// Whether rotating this annotation has a visible effect. Pen / marker /
    /// mosaic strokes opt out — their geometry already encodes their shape.
    var supportsRotation: Bool { get }

    /// Returns a copy with the given rotation. Default impl is a no-op for
    /// types that don't support rotation.
    func withRotation(_ rotation: CGFloat) -> Annotation

    /// Adjust-mode mutators — return a copy with the given property replaced.
    /// Annotation types that don't carry the property fall back to the
    /// default no-op implementation, so callers can apply changes uniformly
    /// without type-switching.
    func withColor(_ color: NSColor) -> Annotation
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation
    func withFontSize(_ fontSize: CGFloat) -> Annotation
    func withFill(_ filled: Bool) -> Annotation
}

extension Annotation {
    var rotation: CGFloat { 0 }
    var supportsRotation: Bool { false }
    func withRotation(_ rotation: CGFloat) -> Annotation { self }
    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }
    func withFontSize(_ fontSize: CGFloat) -> Annotation { self }
    func withFill(_ filled: Bool) -> Annotation { self }

    /// Wraps `draw` with the rotation transform if the annotation has any.
    /// All draw methods are written in unrotated coordinates; this helper is
    /// the single place rotation is applied.
    func drawApplyingTransforms(in context: CGContext, bounds: NSRect) {
        guard rotation != 0, supportsRotation else {
            draw(in: context, bounds: bounds)
            return
        }
        let center = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: rotation)
        context.translateBy(x: -center.x, y: -center.y)
        draw(in: context, bounds: bounds)
        context.restoreGState()
    }

    /// Map a canvas-space point back into the annotation's unrotated frame
    /// so existing hit tests can ignore rotation entirely.
    func unrotate(_ point: NSPoint) -> NSPoint {
        guard rotation != 0, supportsRotation else { return point }
        let c = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
        let dx = point.x - c.x
        let dy = point.y - c.y
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        return NSPoint(
            x: c.x + dx * cosR - dy * sinR,
            y: c.y + dx * sinR + dy * cosR
        )
    }
}

private let strokeHitTolerance: CGFloat = 8

private func strokedPathContains(_ path: CGPath, point: NSPoint, lineWidth: CGFloat) -> Bool {
    let width = max(strokeHitTolerance, lineWidth + 4)
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return stroked.contains(point)
}

// MARK: - Path smoothing

extension NSBezierPath {
    /// Append a quadratic bezier as an equivalent cubic. NSBezierPath has no
    /// native quadratic primitive, but Q(P0,C,P2) maps cleanly to
    /// C(P0, P0+2/3·(C-P0), P2+2/3·(C-P2), P2).
    fileprivate func addQuadCurveAsCubic(to endPoint: NSPoint, controlPoint c: NSPoint) {
        let start = currentPoint
        let cp1 = NSPoint(
            x: start.x + (c.x - start.x) * 2.0 / 3.0,
            y: start.y + (c.y - start.y) * 2.0 / 3.0
        )
        let cp2 = NSPoint(
            x: endPoint.x + (c.x - endPoint.x) * 2.0 / 3.0,
            y: endPoint.y + (c.y - endPoint.y) * 2.0 / 3.0
        )
        curve(to: endPoint, controlPoint1: cp1, controlPoint2: cp2)
    }

    /// Build a smooth path through `points` using midpoint quadratic
    /// smoothing — each raw point becomes a quadratic control, anchors are
    /// the midpoints between consecutive raw points, and the curve flows
    /// through them without hard corners. Tangents stay continuous at the
    /// joints because each midpoint lies on the line between its neighbouring
    /// raw points, so the quadratic and the adjacent line share a tangent.
    static func smoothed(through points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { return path }
        if points.count == 2 {
            path.line(to: points[1])
            return path
        }
        let firstMid = NSPoint(
            x: (points[0].x + points[1].x) / 2,
            y: (points[0].y + points[1].y) / 2
        )
        path.line(to: firstMid)
        for i in 1..<points.count - 1 {
            let mid = NSPoint(
                x: (points[i].x + points[i + 1].x) / 2,
                y: (points[i].y + points[i + 1].y) / 2
            )
            path.addQuadCurveAsCubic(to: mid, controlPoint: points[i])
        }
        path.line(to: points[points.count - 1])
        return path
    }
}

// MARK: - Pen Annotation

struct PenAnnotation: Annotation {
    let path: NSBezierPath
    let color: NSColor
    let lineWidth: CGFloat
    var rotation: CGFloat = 0

    var boundingRect: NSRect {
        path.bounds.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }
    var supportsRotation: Bool { true }

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
        let p = unrotate(point)
        return strokedPathContains(path.cgPath, point: p, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        let copy = path.copy() as! NSBezierPath
        var transform = AffineTransform.identity
        transform.translate(x: delta.x, y: delta.y)
        copy.transform(using: transform)
        return PenAnnotation(path: copy, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        PenAnnotation(path: path, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        PenAnnotation(path: path, color: color, lineWidth: lineWidth, rotation: rotation)
    }
}

// MARK: - Marker (Highlighter) Annotation

/// Highlighter — a pen stroke painted with a semi-transparent fat brush so it
/// reads as if drawn over text with a real marker. Unlike the pen, the brush
/// width scales as `lineWidth × 6` and self-overlapping segments are drawn
/// inside a transparency layer so the alpha doesn't compound at junctions.
struct MarkerAnnotation: Annotation {
    let path: NSBezierPath
    /// User-picked color; alpha is applied at draw time.
    let color: NSColor
    /// Base width — multiplied by `MarkerAnnotation.brushScale` when drawn.
    let lineWidth: CGFloat
    var rotation: CGFloat = 0

    static let brushScale: CGFloat = 6
    static let markerAlpha: CGFloat = 0.35

    var boundingRect: NSRect {
        let inset = -lineWidth * MarkerAnnotation.brushScale / 2
        return path.bounds.insetBy(dx: inset, dy: inset)
    }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let stroke = color.withAlphaComponent(1.0)
        stroke.setStroke()
        path.lineWidth = lineWidth * MarkerAnnotation.brushScale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // Paint into a transparency layer at full alpha then flatten the
        // entire layer at marker alpha so overlapping passes don't darken.
        context.setAlpha(MarkerAnnotation.markerAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        path.stroke()
        context.endTransparencyLayer()
        context.setAlpha(1.0)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let effectiveWidth = lineWidth * MarkerAnnotation.brushScale
        return strokedPathContains(path.cgPath, point: p, lineWidth: effectiveWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        let copy = path.copy() as! NSBezierPath
        var transform = AffineTransform.identity
        transform.translate(x: delta.x, y: delta.y)
        copy.transform(using: transform)
        return MarkerAnnotation(path: copy, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        MarkerAnnotation(path: path, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        MarkerAnnotation(path: path, color: color, lineWidth: lineWidth, rotation: rotation)
    }
}

// MARK: - Mosaic Annotation

struct MosaicAnnotation: Annotation {
    let rect: NSRect
    let pixelatedImage: NSImage

    var boundingRect: NSRect { rect }

    func draw(in context: CGContext, bounds: NSRect) {
        pixelatedImage.draw(in: rect)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        rect.contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        MosaicAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            pixelatedImage: pixelatedImage
        )
    }
}

// MARK: - Magnifier Annotation

/// A circular magnifying-glass lens placed over the screenshot. The lens
/// samples the base image directly beneath itself and redraws that region
/// enlarged `zoom`× inside a glossy ring. It holds a reference to the source
/// image and re-samples it on every draw, so moving or resizing the lens
/// always shows whatever is currently underneath it (like a real loupe laid
/// on a photo).
struct MagnifierAnnotation: Annotation {
    let center: NSPoint
    let radius: CGFloat
    /// Magnification factor — the lens shows a `2·radius / zoom` wide region
    /// blown up to fill the `2·radius` circle.
    let zoom: CGFloat
    /// Base screenshot this lens magnifies. Sampled fresh on every draw.
    let sourceImage: NSImage

    static let defaultZoom: CGFloat = 2.0
    /// Smallest radius the lens may be created or resized to.
    static let minRadius: CGFloat = 16

    var boundingRect: NSRect {
        NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    // Cached chrome — the drop shadow, inner shadow and ring gradient are the
    // same for every lens, so build them once.
    private static let outerShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.4)
        s.shadowOffset = NSSize(width: 0, height: -6)
        s.shadowBlurRadius = 14
        return s
    }()
    private static let innerShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.5)
        s.shadowOffset = NSSize(width: 0, height: -3)
        s.shadowBlurRadius = 6
        return s
    }()
    private static let ringGradient: CGGradient? = {
        let colors = [
            NSColor.white.withAlphaComponent(0.95).cgColor,
            NSColor(white: 0.7, alpha: 0.85).cgColor,
        ] as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])
    }()

    func draw(in context: CGContext, bounds: NSRect) {
        guard radius > 6, let nsContext = NSGraphicsContext.current else { return }

        let squareRect = boundingRect
        let circle = NSBezierPath(ovalIn: squareRect)

        // 1. Outer drop shadow — a white disc carries the shadow; passes 2-4
        // paint over the disc, leaving only the shadow that spills outside.
        NSGraphicsContext.saveGraphicsState()
        Self.outerShadow.set()
        NSColor.white.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 2. Magnified content, clipped to the circle. The source region is
        // `2·radius / zoom` wide in canvas coords, centered on the lens; map
        // it into the source image's coordinate space and blow it up to fill.
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let imgSize = sourceImage.size
        let scaleX = bounds.width > 0 ? imgSize.width / bounds.width : 1
        let scaleY = bounds.height > 0 ? imgSize.height / bounds.height : 1
        let srcSize = (radius * 2) / max(zoom, 1)
        let fromRect = NSRect(
            x: (center.x - srcSize / 2) * scaleX,
            y: (center.y - srcSize / 2) * scaleY,
            width: srcSize * scaleX,
            height: srcSize * scaleY
        )
        nsContext.imageInterpolation = .high
        sourceImage.draw(in: squareRect, from: fromRect, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // 3. Glossy gradient ring border — a donut path (outer circle minus
        // an inset inner circle) filled with a top-to-bottom gradient.
        let borderWidth = max(3.5, radius * 0.07)
        let innerCircle = NSBezierPath(ovalIn: squareRect.insetBy(dx: borderWidth, dy: borderWidth))
        let ring = NSBezierPath()
        ring.append(circle)
        ring.append(innerCircle.reversed)
        context.saveGState()
        ring.addClip()
        if let gradient = Self.ringGradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: squareRect.midX, y: squareRect.maxY),
                end: CGPoint(x: squareRect.midX, y: squareRect.minY),
                options: []
            )
        }
        context.restoreGState()

        // 4. Inner shadow — darkens the rim inside the glass for depth. A
        // hollow rectangle with a circular hole, filled under a shadow while
        // clipped to the circle, casts the shadow inward from the edge.
        NSGraphicsContext.saveGraphicsState()
        Self.innerShadow.set()
        let innerHole = NSBezierPath(rect: squareRect.insetBy(dx: -30, dy: -30))
        innerHole.append(NSBezierPath(ovalIn: squareRect).reversed)
        circle.addClip()
        NSColor.black.withAlphaComponent(0.8).setFill()
        innerHole.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius
    }

    func translated(by delta: NSPoint) -> Annotation {
        MagnifierAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            radius: radius,
            zoom: zoom,
            sourceImage: sourceImage
        )
    }
}

// MARK: - Rectangle Annotation

struct RectAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    let filled: Bool
    var rotation: CGFloat = 0

    init(
        rect: NSRect,
        color: NSColor,
        lineWidth: CGFloat,
        filled: Bool = false,
        rotation: CGFloat = 0
    ) {
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.filled = filled
        self.rotation = rotation
    }

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        if filled {
            context.fill(rect)
        }
        context.stroke(rect)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = CGPath(rect: rect, transform: nil)
        if filled, path.contains(p) {
            return true
        }
        return strokedPathContains(path, point: p, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        RectAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            color: color,
            lineWidth: lineWidth,
            filled: filled,
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, rotation: rotation)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, rotation: rotation)
    }

    func withFill(_ filled: Bool) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, rotation: rotation)
    }
}

// MARK: - Ellipse Annotation

struct EllipseAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    let filled: Bool
    var rotation: CGFloat = 0

    init(
        rect: NSRect,
        color: NSColor,
        lineWidth: CGFloat,
        filled: Bool = false,
        rotation: CGFloat = 0
    ) {
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.filled = filled
        self.rotation = rotation
    }

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        if filled {
            context.fillEllipse(in: rect)
        }
        context.strokeEllipse(in: rect)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = CGPath(ellipseIn: rect, transform: nil)
        if filled, path.contains(p) {
            return true
        }
        return strokedPathContains(path, point: p, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EllipseAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            color: color,
            lineWidth: lineWidth,
            filled: filled,
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, rotation: rotation)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, rotation: rotation)
    }

    func withFill(_ filled: Bool) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, rotation: rotation)
    }
}

// MARK: - Arrow Annotation

struct ArrowAnnotation: Annotation {
    let startPoint: NSPoint
    let endPoint: NSPoint
    let color: NSColor
    let lineWidth: CGFloat
    /// Optional curve handle. When set, the shaft is drawn as a quadratic
    /// bezier through `controlPoint` and the arrowhead orientation follows
    /// the tangent at the end of the curve. nil = straight arrow.
    var controlPoint: NSPoint? = nil

    var boundingRect: NSRect {
        var minX = min(startPoint.x, endPoint.x)
        var minY = min(startPoint.y, endPoint.y)
        var maxX = max(startPoint.x, endPoint.x)
        var maxY = max(startPoint.y, endPoint.y)
        if let cp = controlPoint {
            minX = min(minX, cp.x); maxX = max(maxX, cp.x)
            minY = min(minY, cp.y); maxY = max(maxY, cp.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Default visual midpoint when no controlPoint is set — the geometric
    /// mid of start/end. Used to anchor the curve handle in adjust mode.
    var defaultCurveMid: NSPoint {
        NSPoint(
            x: (startPoint.x + endPoint.x) / 2,
            y: (startPoint.y + endPoint.y) / 2
        )
    }

    /// Position where the curve handle is rendered: the controlPoint when
    /// set, otherwise the geometric midpoint.
    var curveHandlePoint: NSPoint {
        controlPoint ?? defaultCurveMid
    }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setFillColor(color.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        // Tangent at the endpoint — drives the arrowhead orientation.
        let endTangent: (dx: CGFloat, dy: CGFloat)
        if let cp = controlPoint {
            endTangent = (endPoint.x - cp.x, endPoint.y - cp.y)
        } else {
            endTangent = (endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        }
        let length = sqrt(endTangent.dx * endTangent.dx + endTangent.dy * endTangent.dy)
        guard length > 0 else { return }

        // Wide, swept arrowhead with a concave base — gives the "big head,
        // thin tail" silhouette. Shaft tapers from a thin tail into the head.
        let headLength: CGFloat = max(22, lineWidth * 6.5)
        let headWidth: CGFloat = max(22, lineWidth * 7.5)
        let neckHalf: CGFloat = max(3, lineWidth * 1.4)
        let tailHalf: CGFloat = max(0.5, lineWidth * 0.25)
        // How far the concave base pulls forward toward the tip. Tuned so
        // the outer "ear" corner sits around 40° — bigger value gives a
        // sharper, more barb-like ear.
        let neckIndent: CGFloat = headLength * 0.14

        let unitX = endTangent.dx / length
        let unitY = endTangent.dy / length
        // Perpendicular (left side of the arrow when looking toward tip).
        let perpX = -unitY
        let perpY = unitX

        // Head base center and the concave neck point (closer to the tip).
        let baseX = endPoint.x - unitX * headLength
        let baseY = endPoint.y - unitY * headLength
        let neckX = endPoint.x - unitX * (headLength - neckIndent)
        let neckY = endPoint.y - unitY * (headLength - neckIndent)

        // Outer corners of the arrowhead.
        let headLX = baseX + perpX * headWidth / 2
        let headLY = baseY + perpY * headWidth / 2
        let headRX = baseX - perpX * headWidth / 2
        let headRY = baseY - perpY * headWidth / 2

        // Where the shaft meets the head (concave base).
        let neckLX = neckX + perpX * neckHalf
        let neckLY = neckY + perpY * neckHalf
        let neckRX = neckX - perpX * neckHalf
        let neckRY = neckY - perpY * neckHalf

        if let cp = controlPoint {
            // Curved arrow: draw the tapered shaft as a filled region bounded
            // by two parallel offset quadratic beziers, then drop the swept
            // head on top.
            //
            // Offsetting a quadratic bezier exactly is non-trivial, but for
            // the small widths involved here we can approximate by offsetting
            // each of the three control points by the local perpendicular at
            // that point.
            let startDX = cp.x - startPoint.x
            let startDY = cp.y - startPoint.y
            let startLen = max(hypot(startDX, startDY), 0.0001)
            let startPerpX = -startDY / startLen
            let startPerpY = startDX / startLen

            // Perpendicular at the control point — average of in/out tangents.
            let cpInX = cp.x - startPoint.x
            let cpInY = cp.y - startPoint.y
            let cpOutX = endPoint.x - cp.x
            let cpOutY = endPoint.y - cp.y
            let cpTangentX = cpInX + cpOutX
            let cpTangentY = cpInY + cpOutY
            let cpTangentLen = max(hypot(cpTangentX, cpTangentY), 0.0001)
            let cpPerpX = -cpTangentY / cpTangentLen
            let cpPerpY = cpTangentX / cpTangentLen

            // Width at the control point — linearly between tail and neck.
            let midHalf = (tailHalf + neckHalf) * 0.5

            let tailLX = startPoint.x + startPerpX * tailHalf
            let tailLY = startPoint.y + startPerpY * tailHalf
            let tailRX = startPoint.x - startPerpX * tailHalf
            let tailRY = startPoint.y - startPerpY * tailHalf
            let cpLX = cp.x + cpPerpX * midHalf
            let cpLY = cp.y + cpPerpY * midHalf
            let cpRX = cp.x - cpPerpX * midHalf
            let cpRY = cp.y - cpPerpY * midHalf

            context.beginPath()
            context.move(to: CGPoint(x: tailLX, y: tailLY))
            context.addQuadCurve(to: CGPoint(x: neckLX, y: neckLY), control: CGPoint(x: cpLX, y: cpLY))
            context.addLine(to: CGPoint(x: neckRX, y: neckRY))
            context.addQuadCurve(to: CGPoint(x: tailRX, y: tailRY), control: CGPoint(x: cpRX, y: cpRY))
            context.closePath()
            context.fillPath()

            // Arrowhead on top.
            context.beginPath()
            context.move(to: endPoint)
            context.addLine(to: CGPoint(x: headLX, y: headLY))
            context.addLine(to: CGPoint(x: neckLX, y: neckLY))
            context.addLine(to: CGPoint(x: neckRX, y: neckRY))
            context.addLine(to: CGPoint(x: headRX, y: headRY))
            context.closePath()
            context.fillPath()
        } else {
            // Straight arrow — a single tapered teardrop polygon. Tail is
            // thin, the body widens toward the concave neck, then the head
            // flares out to the wide tip.
            let tailLX = startPoint.x + perpX * tailHalf
            let tailLY = startPoint.y + perpY * tailHalf
            let tailRX = startPoint.x - perpX * tailHalf
            let tailRY = startPoint.y - perpY * tailHalf

            context.beginPath()
            context.move(to: endPoint)
            context.addLine(to: CGPoint(x: headLX, y: headLY))
            context.addLine(to: CGPoint(x: neckLX, y: neckLY))
            context.addLine(to: CGPoint(x: tailLX, y: tailLY))
            context.addLine(to: CGPoint(x: tailRX, y: tailRY))
            context.addLine(to: CGPoint(x: neckRX, y: neckRY))
            context.addLine(to: CGPoint(x: headRX, y: headRY))
            context.closePath()
            context.fillPath()
        }
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        // Shaft hit — use a generous stroke around the spine so the thin
        // tapered tail is still grabbable.
        let line = CGMutablePath()
        if let cp = controlPoint {
            line.move(to: startPoint)
            line.addQuadCurve(to: endPoint, control: cp)
        } else {
            line.move(to: startPoint)
            line.addLine(to: endPoint)
        }
        let hitWidth = max(lineWidth + 4, 8)
        if strokedPathContains(line, point: point, lineWidth: hitWidth) {
            return true
        }

        // Filled arrowhead — direction follows tangent at endPoint. Matches
        // the swept head drawn in `draw(in:bounds:)`.
        let endTangent: (dx: CGFloat, dy: CGFloat)
        if let cp = controlPoint {
            endTangent = (endPoint.x - cp.x, endPoint.y - cp.y)
        } else {
            endTangent = (endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        }
        let length = sqrt(endTangent.dx * endTangent.dx + endTangent.dy * endTangent.dy)
        guard length > 0 else { return false }

        let headLength: CGFloat = max(22, lineWidth * 6.5)
        let headWidth: CGFloat = max(22, lineWidth * 7.5)
        let unitX = endTangent.dx / length
        let unitY = endTangent.dy / length
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
        let translatedCP: NSPoint? = controlPoint.map {
            NSPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
        return ArrowAnnotation(
            startPoint: NSPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y),
            endPoint: NSPoint(x: endPoint.x + delta.x, y: endPoint.y + delta.y),
            color: color,
            lineWidth: lineWidth,
            controlPoint: translatedCP
        )
    }

    /// Adjust-mode helper: replace (or clear) the curve control point.
    func withControlPoint(_ cp: NSPoint?) -> ArrowAnnotation {
        var copy = self
        copy.controlPoint = cp
        return copy
    }

    /// Adjust-mode helper: replace the start (tail) endpoint while keeping
    /// the tip and any curve control point fixed in canvas space.
    func withStartPoint(_ p: NSPoint) -> ArrowAnnotation {
        ArrowAnnotation(
            startPoint: p,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            controlPoint: controlPoint
        )
    }

    /// Adjust-mode helper: replace the tip (arrowhead) endpoint while
    /// keeping the start and any curve control point fixed in canvas space.
    func withEndPoint(_ p: NSPoint) -> ArrowAnnotation {
        ArrowAnnotation(
            startPoint: startPoint,
            endPoint: p,
            color: color,
            lineWidth: lineWidth,
            controlPoint: controlPoint
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        ArrowAnnotation(
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            controlPoint: controlPoint
        )
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        ArrowAnnotation(
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            controlPoint: controlPoint
        )
    }
}

// MARK: - Line Annotation

/// A straight line segment. Like the arrow but with no arrowhead. The two
/// endpoints carry draggable handles in adjust mode so the user can change
/// the line's length and angle; a rotation handle spins the whole segment
/// around its midpoint.
struct LineAnnotation: Annotation {
    let startPoint: NSPoint
    let endPoint: NSPoint
    let color: NSColor
    let lineWidth: CGFloat

    var boundingRect: NSRect {
        NSRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    /// The rotation handle is supported, but rather than storing an angle the
    /// segment "bakes" rotation into its endpoints (see `withRotation`). That
    /// keeps `rotation` permanently 0 so the endpoint handles always sit on
    /// the real geometry and no unrotate bookkeeping is needed.
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.strokePath()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let line = CGMutablePath()
        line.move(to: startPoint)
        line.addLine(to: endPoint)
        return strokedPathContains(line, point: point, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        LineAnnotation(
            startPoint: NSPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y),
            endPoint: NSPoint(x: endPoint.x + delta.x, y: endPoint.y + delta.y),
            color: color,
            lineWidth: lineWidth
        )
    }

    /// Rotate both endpoints by `rotation` radians around the segment's
    /// midpoint. The stored `rotation` stays 0 — the change is baked into
    /// `startPoint` / `endPoint` so the endpoint handles stay truthful.
    func withRotation(_ rotation: CGFloat) -> Annotation {
        guard rotation != 0 else { return self }
        let center = NSPoint(
            x: (startPoint.x + endPoint.x) / 2,
            y: (startPoint.y + endPoint.y) / 2
        )
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        func rotate(_ p: NSPoint) -> NSPoint {
            let dx = p.x - center.x
            let dy = p.y - center.y
            return NSPoint(
                x: center.x + dx * cosR - dy * sinR,
                y: center.y + dx * sinR + dy * cosR
            )
        }
        return LineAnnotation(
            startPoint: rotate(startPoint),
            endPoint: rotate(endPoint),
            color: color,
            lineWidth: lineWidth
        )
    }

    /// Adjust-mode helper: re-anchor the start endpoint.
    func withStartPoint(_ p: NSPoint) -> LineAnnotation {
        LineAnnotation(startPoint: p, endPoint: endPoint, color: color, lineWidth: lineWidth)
    }

    /// Adjust-mode helper: re-anchor the end endpoint.
    func withEndPoint(_ p: NSPoint) -> LineAnnotation {
        LineAnnotation(startPoint: startPoint, endPoint: p, color: color, lineWidth: lineWidth)
    }

    func withColor(_ color: NSColor) -> Annotation {
        LineAnnotation(startPoint: startPoint, endPoint: endPoint, color: color, lineWidth: lineWidth)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        LineAnnotation(startPoint: startPoint, endPoint: endPoint, color: color, lineWidth: lineWidth)
    }
}

// MARK: - Text Annotation

struct TextAnnotation: Annotation {
    let text: String
    /// Bottom-left of the editing/drawing frame, in canvas coordinates.
    let origin: NSPoint
    let color: NSColor
    let fontSize: CGFloat
    var rotation: CGFloat = 0
    /// When true the glyphs get a black-or-white outline picked for maximum
    /// contrast against `color`, so the text reads against any background.
    var hasStroke: Bool = false

    static let trailingCaretPadding: CGFloat = 12
    static let minimumEditorWidth: CGFloat = 32

    /// Outline pen width for the silhouette pass, as the percentage-of-font
    /// unit `NSAttributedString.Key.strokeWidth` expects. The fill pass on top
    /// covers the inner half, so the visible outline is roughly half of this.
    static let strokeWidthPercent: CGFloat = 6.0

    static func font(forSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .bold)
    }

    /// Light fills (white / yellow / green) get a black outline; every other
    /// fill color gets a white one.
    static func strokeColor(for fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .white }
        func matches(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
            abs(rgb.redComponent - r) < 0.04
                && abs(rgb.greenComponent - g) < 0.04
                && abs(rgb.blueComponent - b) < 0.04
        }
        let blackStroke = matches(1.0, 1.0, 1.0)   // White
            || matches(1.0, 0.8, 0.0)              // Yellow
            || matches(0.0, 0.83, 0.42)            // Green
        return blackStroke ? .black : .white
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

    /// Tight ink-bounds rect for the rendered glyphs, in canvas coordinates.
    ///
    /// Used for the dashed selection frame and as the rotation pivot, so the
    /// chrome hugs what's actually painted instead of the editor frame's
    /// trailing-caret padding + line leading (which made the box look skewed
    /// toward bottom-left of the text).
    var textBounds: NSRect {
        let font = TextAnnotation.font(forSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textToMeasure = text.isEmpty ? "M" : text
        let attr = NSAttributedString(string: textToMeasure, attributes: attrs)
        let ink = attr.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesDeviceMetrics]
        )
        // `.usesDeviceMetrics` returns the ink rect with origin relative to
        // the typographic baseline. Convert to coordinates relative to the
        // draw origin (which is the typographic frame's bottom): the baseline
        // sits |descender| above that bottom.
        return NSRect(
            x: origin.x + ink.origin.x,
            y: origin.y + ink.origin.y - font.descender,
            width: ink.width,
            height: ink.height
        )
    }

    var hitBounds: NSRect {
        textBounds.insetBy(dx: -10, dy: -max(10, fontSize * 0.75))
    }

    var boundingRect: NSRect { textBounds }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        let font = TextAnnotation.font(forSize: fontSize)
        NSGraphicsContext.saveGraphicsState()
        if hasStroke {
            // Outline pass: a solid silhouette in the stroke color, drawn
            // first and fattened by the stroke pen. The fill pass below then
            // covers the inner half, leaving a clean outline on the outside
            // that never eats into the glyph (a single centered stroke would).
            let stroke = TextAnnotation.strokeColor(for: color)
            text.draw(at: origin, withAttributes: [
                .foregroundColor: stroke,
                .strokeColor: stroke,
                .strokeWidth: -TextAnnotation.strokeWidthPercent,
                .font: font
            ])
        }
        text.draw(at: origin, withAttributes: [
            .foregroundColor: color,
            .font: font
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return hitBounds.contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        TextAnnotation(
            text: text,
            origin: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        TextAnnotation(
            text: text,
            origin: origin,
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke
        )
    }

    /// Returns a copy with the outline toggled on or off.
    func withStroke(_ hasStroke: Bool) -> TextAnnotation {
        var copy = self
        copy.hasStroke = hasStroke
        return copy
    }

    /// Resize the text in place. The visual top-left stays anchored — fonts
    /// grow downward in canvas coords (which use a flipped origin), so the
    /// origin shifts by the line-height delta to keep the cap line steady.
    func withFontSize(_ fontSize: CGFloat) -> Annotation {
        let oldFont = TextAnnotation.font(forSize: self.fontSize)
        let newFont = TextAnnotation.font(forSize: fontSize)
        let oldHeight = TextAnnotation.lineHeight(for: oldFont)
        let newHeight = TextAnnotation.lineHeight(for: newFont)
        let newOrigin = NSPoint(x: origin.x, y: origin.y + (oldHeight - newHeight))
        return TextAnnotation(
            text: text,
            origin: newOrigin,
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke
        )
    }
}

// MARK: - Number Annotation

struct NumberAnnotation: Annotation {
    let center: NSPoint
    /// Optional arrow tip pointing away from the badge. `nil` (or a tip
    /// inside the badge) draws the badge alone. Otherwise an arrow is drawn
    /// from the badge's edge out to `tip`. Set during creation by drag, and
    /// adjustable later via the tip handle in adjust mode.
    var tip: NSPoint?
    /// Optional curve handle. When set together with `tip`, the shaft is
    /// drawn as a quadratic bezier through `controlPoint` and the
    /// arrowhead orientation follows the tangent at the tip. nil = straight
    /// shaft.
    var controlPoint: NSPoint? = nil
    let number: Int
    let color: NSColor

    static let radius: CGFloat = 14
    /// Below this distance from `center` we treat the tip as "no arrow" so
    /// the head won't sit on top of the badge glyph.
    static let arrowMinDistance: CGFloat = NumberAnnotation.radius + 6

    /// Black on light badges, white on dark — perceived-luminance threshold.
    static func contrastingTextColor(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var hasArrow: Bool {
        guard let tip else { return false }
        return hypot(tip.x - center.x, tip.y - center.y) >= NumberAnnotation.arrowMinDistance
    }

    var circleRect: NSRect {
        NSRect(
            x: center.x - NumberAnnotation.radius,
            y: center.y - NumberAnnotation.radius,
            width: NumberAnnotation.radius * 2,
            height: NumberAnnotation.radius * 2
        )
    }

    var boundingRect: NSRect {
        guard hasArrow, let tip else { return circleRect }
        var rect = circleRect.union(NSRect(x: tip.x, y: tip.y, width: 0, height: 0))
        if let cp = controlPoint {
            rect = rect.union(NSRect(x: cp.x, y: cp.y, width: 0, height: 0))
        }
        return rect
    }

    /// Default curve handle position when no `controlPoint` is set — the
    /// midpoint of the shaft (badge center to tip) so a fresh straight
    /// arrow still surfaces a grabbable bend point.
    var defaultCurveMid: NSPoint? {
        guard hasArrow, let tip else { return nil }
        return NSPoint(
            x: (center.x + tip.x) / 2,
            y: (center.y + tip.y) / 2
        )
    }

    /// Position where the curve handle is rendered: the controlPoint when
    /// set, otherwise the visual midpoint. nil when there's no arrow.
    var curveHandlePoint: NSPoint? {
        controlPoint ?? defaultCurveMid
    }

    func draw(in context: CGContext, bounds: NSRect) {
        // Arrow shaft + head from badge center to tip (drawn first so the
        // badge sits on top and hides the part of the shaft inside the
        // circle — visually the arrow emerges from the badge's edge while
        // geometrically the bezier starts from the center).
        if hasArrow, let tip {
            let shaftWidth: CGFloat = 3
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(shaftWidth)
            context.setLineCap(.round)

            // Tangent at the tip — drives the arrowhead orientation.
            let endTangent: (dx: CGFloat, dy: CGFloat)
            if let cp = controlPoint {
                endTangent = (tip.x - cp.x, tip.y - cp.y)
            } else {
                endTangent = (tip.x - center.x, tip.y - center.y)
            }

            // Arrowhead — direction follows the local tangent at the tip.
            let tlen = hypot(endTangent.dx, endTangent.dy)
            if tlen > 0 {
                let unitX = endTangent.dx / tlen
                let unitY = endTangent.dy / tlen
                let headLength: CGFloat = max(10, shaftWidth * 4)
                let headWidth: CGFloat = max(7, shaftWidth * 3)
                let baseX = tip.x - unitX * headLength
                let baseY = tip.y - unitY * headLength

                // Shaft — stop at the arrowhead base so the round line cap
                // stays hidden inside the filled triangle and the tip stays
                // a crisp point.
                if let cp = controlPoint {
                    let t = max(0, min(1, 1 - headLength / (2 * tlen)))
                    let a = NSPoint(x: center.x + (cp.x - center.x) * t,
                                    y: center.y + (cp.y - center.y) * t)
                    let b = NSPoint(x: cp.x + (tip.x - cp.x) * t,
                                    y: cp.y + (tip.y - cp.y) * t)
                    let shaftEnd = NSPoint(x: a.x + (b.x - a.x) * t,
                                           y: a.y + (b.y - a.y) * t)
                    context.move(to: center)
                    context.addQuadCurve(to: shaftEnd, control: a)
                    context.strokePath()
                } else {
                    context.move(to: center)
                    context.addLine(to: CGPoint(x: baseX, y: baseY))
                    context.strokePath()
                }

                context.move(to: tip)
                context.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
                context.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
                context.closePath()
                // Round join so the tip is very slightly blunt.
                context.setLineJoin(.round)
                context.setLineWidth(1.5)
                context.drawPath(using: .fillStroke)
            }
        }

        // Filled badge circle
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circleRect)

        // Badge number — always drawn upright (no rotation). Pick a digit
        // color that contrasts with the badge fill so a white badge doesn't
        // render an invisible white "1".
        let text = "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NumberAnnotation.contrastingTextColor(for: color),
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
        // Badge hit
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = NumberAnnotation.radius
        if dx * dx + dy * dy <= r * r {
            return true
        }
        // Arrow shaft hit (only when an arrow is actually drawn).
        if hasArrow, let tip {
            let line = CGMutablePath()
            line.move(to: center)
            if let cp = controlPoint {
                line.addQuadCurve(to: tip, control: cp)
            } else {
                line.addLine(to: tip)
            }
            return strokedPathContains(line, point: point, lineWidth: 4)
        }
        return false
    }

    func translated(by delta: NSPoint) -> Annotation {
        NumberAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            tip: tip.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            controlPoint: controlPoint.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            number: number,
            color: color
        )
    }

    /// Adjust-mode helper: replace (or clear) the arrow tip. Clearing the
    /// tip also drops the curve control point — there's no shaft for it
    /// to bend.
    func withTip(_ tip: NSPoint?) -> NumberAnnotation {
        var copy = self
        copy.tip = tip
        if tip == nil {
            copy.controlPoint = nil
        }
        return copy
    }

    /// Adjust-mode helper: replace (or clear) the curve control point.
    func withControlPoint(_ cp: NSPoint?) -> NumberAnnotation {
        var copy = self
        copy.controlPoint = cp
        return copy
    }

    /// Adjust-mode helper: replace the displayed badge number. Driven by
    /// the +/- stepper buttons on the selection chrome.
    func withNumber(_ number: Int) -> NumberAnnotation {
        NumberAnnotation(
            center: center,
            tip: tip,
            controlPoint: controlPoint,
            number: number,
            color: color
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        NumberAnnotation(center: center, tip: tip, controlPoint: controlPoint, number: number, color: color)
    }
}
