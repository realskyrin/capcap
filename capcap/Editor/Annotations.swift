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
    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation
    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation
}

extension Annotation {
    var rotation: CGFloat { 0 }
    var supportsRotation: Bool { false }
    func withRotation(_ rotation: CGFloat) -> Annotation { self }
    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }
    func withFontSize(_ fontSize: CGFloat) -> Annotation { self }
    func withFill(_ filled: Bool) -> Annotation { self }
    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation { self }
    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation { self }

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

enum ShapeFillMode: String, CaseIterable {
    case none
    case opaque
    case translucent

    var isFilled: Bool { self != .none }

    var alpha: CGFloat {
        switch self {
        case .none: return 0
        case .opaque: return 1
        case .translucent: return 0.42
        }
    }
}

enum ShapeStrokeStyle: String, CaseIterable {
    case standard
    case rounded
    case handDrawn
}

struct RoughShapeStyle: Equatable {
    let seed: UInt64
    let roughness: CGFloat
    let passes: Int

    init(seed: UInt64 = RoughShapeStyle.randomSeed(), roughness: CGFloat, passes: Int = 1) {
        self.seed = seed == 0 ? Self.fallbackSeed : seed
        self.roughness = min(max(roughness, 0), 4)
        self.passes = max(1, min(passes, 3))
    }

    static func make(seed: UInt64 = RoughShapeStyle.randomSeed(), rect: NSRect, lineWidth: CGFloat) -> RoughShapeStyle {
        RoughShapeStyle(seed: seed, roughness: defaultRoughness(for: rect, lineWidth: lineWidth), passes: 1)
    }

    func tuned(for rect: NSRect, lineWidth: CGFloat) -> RoughShapeStyle {
        RoughShapeStyle(seed: seed, roughness: Self.defaultRoughness(for: rect, lineWidth: lineWidth), passes: passes)
    }

    static func randomSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64.max)
    }

    private static let fallbackSeed: UInt64 = 0x9E3779B97F4A7C15

    private static func defaultRoughness(for rect: NSRect, lineWidth: CGFloat) -> CGFloat {
        let sizeDriven = min(rect.width, rect.height) * 0.001
        let widthDriven = lineWidth * 0.04
        return max(0.15, min(0.55, max(sizeDriven, widthDriven)))
    }
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x123456789ABCDEF : seed
    }

    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }

    mutating func range(_ min: CGFloat, _ max: CGFloat) -> CGFloat {
        min + (max - min) * next()
    }
}

private func strokedPathContains(_ path: CGPath, point: NSPoint, lineWidth: CGFloat) -> Bool {
    let width = max(strokeHitTolerance, lineWidth + 4)
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return stroked.contains(point)
}

private func distanceFrom(_ point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else {
        return hypot(point.x - start.x, point.y - start.y)
    }

    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    let closest = NSPoint(x: start.x + t * dx, y: start.y + t * dy)
    return hypot(point.x - closest.x, point.y - closest.y)
}

private enum ShapeDrawing {
    static func fillRect(_ rect: NSRect, color: NSColor, lineWidth: CGFloat, fillMode: ShapeFillMode, strokeStyle: ShapeStrokeStyle, roughStyle: RoughShapeStyle, in context: CGContext) {
        guard fillMode.isFilled else { return }
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(fillMode.alpha).cgColor)
        switch strokeStyle {
        case .standard:
            context.fill(rect)
        case .rounded:
            context.addPath(roundedRectPath(rect, lineWidth: lineWidth))
            context.fillPath()
        case .handDrawn:
            context.addPath(roughRoundedRectPath(rect, lineWidth: lineWidth, style: roughStyle, pass: 0))
            context.fillPath()
        }
        context.restoreGState()
    }

    static func fillEllipse(_ rect: NSRect, color: NSColor, lineWidth: CGFloat, fillMode: ShapeFillMode, strokeStyle: ShapeStrokeStyle, roughStyle: RoughShapeStyle, in context: CGContext) {
        guard fillMode.isFilled else { return }
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(fillMode.alpha).cgColor)
        switch strokeStyle {
        case .standard, .rounded:
            context.fillEllipse(in: rect)
        case .handDrawn:
            context.addPath(roughEllipsePath(rect, style: roughStyle, pass: 0))
            context.fillPath()
        }
        context.restoreGState()
    }

    static func strokeRect(_ rect: NSRect, color: NSColor, lineWidth: CGFloat, strokeStyle: ShapeStrokeStyle, roughStyle: RoughShapeStyle, in context: CGContext) {
        switch strokeStyle {
        case .standard:
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.stroke(rect)
            context.restoreGState()
        case .rounded:
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineJoin(.round)
            context.addPath(roundedRectPath(rect, lineWidth: lineWidth))
            context.strokePath()
            context.restoreGState()
        case .handDrawn:
            let drawingRect = rect.insetBy(dx: strokeInset(for: rect, lineWidth: lineWidth), dy: strokeInset(for: rect, lineWidth: lineWidth))
            drawRoughStroke(
                color: color,
                style: roughStyle,
                in: context
            ) { pass in
                roughRoundedRectStrokeSamples(drawingRect, lineWidth: lineWidth, style: roughStyle, pass: pass)
            }
        }
    }

    static func strokeEllipse(_ rect: NSRect, color: NSColor, lineWidth: CGFloat, strokeStyle: ShapeStrokeStyle, roughStyle: RoughShapeStyle, in context: CGContext) {
        switch strokeStyle {
        case .standard, .rounded:
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: rect)
            context.restoreGState()
        case .handDrawn:
            let drawingRect = rect.insetBy(dx: strokeInset(for: rect, lineWidth: lineWidth), dy: strokeInset(for: rect, lineWidth: lineWidth))
            drawRoughStroke(
                color: color,
                style: roughStyle,
                in: context
            ) { pass in
                roughEllipseStrokeSamples(drawingRect, lineWidth: lineWidth, style: roughStyle, pass: pass)
            }
        }
    }

    private static func roundedRectRadius(for rect: NSRect, lineWidth: CGFloat) -> CGFloat {
        let shortest = max(1, min(rect.width, rect.height))
        return min(shortest * 0.2, max(12, lineWidth * 3.2))
    }

    private static func roundedRectPath(_ rect: NSRect, lineWidth: CGFloat) -> CGPath {
        let radius = roundedRectRadius(for: rect, lineWidth: lineWidth)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func rectPath(_ rect: NSRect, lineWidth: CGFloat, strokeStyle: ShapeStrokeStyle) -> CGPath {
        switch strokeStyle {
        case .standard:
            return CGPath(rect: rect, transform: nil)
        case .rounded, .handDrawn:
            return roundedRectPath(rect, lineWidth: lineWidth)
        }
    }

    private struct VariableStrokeSample {
        let point: CGPoint
        let width: CGFloat
    }

    private static func drawRoughStroke(color: NSColor, style: RoughShapeStyle, in context: CGContext, samplesForPass: (Int) -> [VariableStrokeSample]) {
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        for pass in 0..<style.passes {
            let alpha: CGFloat
            let widthScale: CGFloat
            switch pass {
            case 0:
                alpha = 1
                widthScale = 1
            case 1:
                alpha = 0.62
                widthScale = 0.86
            default:
                alpha = 0.38
                widthScale = 0.68
            }
            drawVariableWidthStroke(
                samples: samplesForPass(pass).map {
                    VariableStrokeSample(point: $0.point, width: max(1, $0.width * widthScale))
                },
                color: colorByMultiplyingAlpha(color, by: alpha),
                in: context
            )
        }

        context.restoreGState()
    }

    private static func colorByMultiplyingAlpha(_ color: NSColor, by alpha: CGFloat) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return rgb.withAlphaComponent(min(max(rgb.alphaComponent * alpha, 0), 1))
    }

    private static func strokeInset(for rect: NSRect, lineWidth: CGFloat) -> CGFloat {
        let maxInset = max(0, min(rect.width, rect.height) / 2 - 0.5)
        return min(maxInset, max(0, lineWidth / 2))
    }

    private static func roughRoundedRectPath(_ rect: NSRect, lineWidth: CGFloat, style: RoughShapeStyle, pass: Int) -> CGPath {
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        var rng = SeededRandom(seed: passSeed(style.seed, pass: pass))
        let radius = roundedRectRadius(for: rect, lineWidth: lineWidth)
        let points = roundedRectPoints(
            rect: rect,
            radius: radius,
            step: roughSampleStep,
            bowAmount: 0,
            rng: &rng
        )
        return smoothClosedPath(points: points)
    }

    private static func roughEllipsePath(_ rect: NSRect, style _: RoughShapeStyle, pass _: Int) -> CGPath {
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        return smoothClosedPath(points: ellipsePoints(rect: rect, step: roughSampleStep))
    }

    private static func roughRoundedRectStrokeSamples(_ rect: NSRect, lineWidth: CGFloat, style: RoughShapeStyle, pass: Int) -> [VariableStrokeSample] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        var rng = SeededRandom(seed: passSeed(style.seed, pass: pass))
        let radius = roundedRectRadius(for: rect, lineWidth: lineWidth)
        let points = roundedRectPoints(
            rect: rect,
            radius: radius,
            step: roughSampleStep,
            bowAmount: 0,
            rng: &rng
        )
        return pressureSamples(points: points, lineWidth: lineWidth, style: style, rng: &rng)
    }

    private static func roughEllipseStrokeSamples(_ rect: NSRect, lineWidth: CGFloat, style: RoughShapeStyle, pass: Int) -> [VariableStrokeSample] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        var rng = SeededRandom(seed: passSeed(style.seed, pass: pass))
        return pressureSamples(points: ellipsePoints(rect: rect, step: roughSampleStep), lineWidth: lineWidth, style: style, rng: &rng)
    }

    private static func pressureSamples(points: [CGPoint], lineWidth: CGFloat, style: RoughShapeStyle, rng: inout SeededRandom) -> [VariableStrokeSample] {
        guard !points.isEmpty else { return [] }
        let phaseA = rng.range(0, .pi * 2)
        let phaseB = rng.range(0, .pi * 2)
        let phaseC = rng.range(0, .pi * 2)
        let variation = max(0.12, min(0.24, 0.14 + style.roughness * 0.08))
        let count = CGFloat(points.count)

        return points.enumerated().map { index, point in
            let progress = CGFloat(index) / count
            let t = progress * .pi * 2
            let pressure = 1
                + variation * sin(t + phaseA)
                + variation * 0.45 * sin(t * 2.3 + phaseB)
                + variation * 0.24 * cos(t * 4.1 + phaseC)
            return VariableStrokeSample(
                point: point,
                width: max(1, lineWidth * min(max(pressure, 0.72), 1.28))
            )
        }
    }

    private static func drawVariableWidthStroke(samples: [VariableStrokeSample], color: NSColor, in context: CGContext) {
        guard samples.count >= 3 else { return }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(samples.count)
        right.reserveCapacity(samples.count)

        for index in samples.indices {
            let normal = strokeNormal(at: index, in: samples)
            let halfWidth = samples[index].width / 2
            let point = samples[index].point
            left.append(CGPoint(
                x: point.x + normal.dx * halfWidth,
                y: point.y + normal.dy * halfWidth
            ))
            right.append(CGPoint(
                x: point.x - normal.dx * halfWidth,
                y: point.y - normal.dy * halfWidth
            ))
        }

        let path = CGMutablePath()
        addSmoothedClosedLoop(left, to: path)
        addSmoothedClosedLoop(right.reversed(), to: path)

        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private static func strokeNormal(at index: Int, in samples: [VariableStrokeSample]) -> CGVector {
        let previousIndex = index == samples.startIndex
            ? samples.index(before: samples.endIndex)
            : samples.index(before: index)
        let nextIndex = index == samples.index(before: samples.endIndex)
            ? samples.startIndex
            : samples.index(after: index)
        let previous = samples[previousIndex].point
        let next = samples[nextIndex].point
        let dx = next.x - previous.x
        let dy = next.y - previous.y
        let length = max(0.001, hypot(dx, dy))
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    private static func addSmoothedClosedLoop<S: Sequence>(_ points: S, to path: CGMutablePath) where S.Element == CGPoint {
        let points = Array(points)
        guard points.count > 2 else { return }

        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        let count = points.count
        path.move(to: mid(points[0], points[1]))
        for index in 1...count {
            let current = points[index % count]
            let next = points[(index + 1) % count]
            path.addQuadCurve(to: mid(current, next), control: current)
        }
        path.closeSubpath()
    }

    private static func passSeed(_ seed: UInt64, pass: Int) -> UInt64 {
        seed &+ (UInt64(pass + 1) &* 0x9E3779B97F4A7C15)
    }

    private static let roughSampleStep: CGFloat = 10
    private static let roughArcStep: CGFloat = .pi / 12

    private static func roundedRectPoints(rect: NSRect, radius: CGFloat, step: CGFloat, bowAmount: CGFloat, rng: inout SeededRandom) -> [CGPoint] {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var points: [CGPoint] = []

        sampleRoughLine(
            from: CGPoint(x: rect.minX + r, y: rect.minY),
            to: CGPoint(x: rect.maxX - r, y: rect.minY),
            step: step,
            bowAmount: bowAmount,
            rng: &rng,
            points: &points
        )
        sampleArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: -.pi / 2,
            endAngle: 0,
            stepAngle: roughArcStep,
            points: &points
        )
        sampleRoughLine(
            from: CGPoint(x: rect.maxX, y: rect.minY + r),
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            step: step,
            bowAmount: bowAmount,
            rng: &rng,
            points: &points
        )
        sampleArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: 0,
            endAngle: .pi / 2,
            stepAngle: roughArcStep,
            points: &points
        )
        sampleRoughLine(
            from: CGPoint(x: rect.maxX - r, y: rect.maxY),
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            step: step,
            bowAmount: bowAmount,
            rng: &rng,
            points: &points
        )
        sampleArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .pi / 2,
            endAngle: .pi,
            stepAngle: roughArcStep,
            points: &points
        )
        sampleRoughLine(
            from: CGPoint(x: rect.minX, y: rect.maxY - r),
            to: CGPoint(x: rect.minX, y: rect.minY + r),
            step: step,
            bowAmount: bowAmount,
            rng: &rng,
            points: &points
        )
        sampleArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .pi,
            endAngle: .pi * 1.5,
            stepAngle: roughArcStep,
            points: &points
        )

        return points
    }

    private static func ellipsePoints(rect: NSRect, step: CGFloat) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2
        let ry = rect.height / 2
        let circumference = .pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
        let count = max(24, Int(ceil(circumference / step)))
        return (0..<count).map { index in
            let angle = .pi * 2 * CGFloat(index) / CGFloat(count)
            return CGPoint(
                x: center.x + rx * cos(angle),
                y: center.y + ry * sin(angle)
            )
        }
    }

    private static func sampleRoughLine(
        from start: CGPoint,
        to end: CGPoint,
        step: CGFloat,
        bowAmount: CGFloat,
        rng: inout SeededRandom,
        points: inout [CGPoint]
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0 else {
            appendPoint(start, to: &points)
            return
        }

        let count = max(1, Int(ceil(distance / step)))
        let nx = -dy / distance
        let ny = dx / distance
        let bowDirection = rng.range(-1, 1)
        for index in 0...count {
            if !points.isEmpty && index == 0 { continue }
            let t = CGFloat(index) / CGFloat(count)
            let bow = sin(t * .pi) * bowAmount * bowDirection
            points.append(CGPoint(
                x: start.x + dx * t + nx * bow,
                y: start.y + dy * t + ny * bow
            ))
        }
    }

    private static func sampleArc(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        stepAngle: CGFloat,
        points: inout [CGPoint]
    ) {
        guard radius > 0 else {
            appendPoint(center, to: &points)
            return
        }

        let total = abs(endAngle - startAngle)
        let count = max(3, Int(ceil(total / stepAngle)))
        for index in 0...count {
            if !points.isEmpty && index == 0 { continue }
            let t = CGFloat(index) / CGFloat(count)
            let angle = startAngle + (endAngle - startAngle) * t
            points.append(CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            ))
        }
    }

    private static func appendPoint(_ point: CGPoint, to points: inout [CGPoint]) {
        guard points.last != point else { return }
        points.append(point)
    }

    private static func smoothClosedPath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 2 else { return path }

        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        let count = points.count
        path.move(to: mid(points[0], points[1]))
        for index in 1...count {
            let current = points[index % count]
            let next = points[(index + 1) % count]
            path.addQuadCurve(to: mid(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }
}

enum ArrowStyle: String, CaseIterable {
    case tapered
    case doubleEnded
    case line
    case dotTail
}

private enum NumberArrowShape {
    static let shaftWidth: CGFloat = 3
    static let headStrokeWidth: CGFloat = 1.5
    static let dotTailRadius: CGFloat = 5

    static var headLength: CGFloat { max(10, shaftWidth * 4) }
    static var headWidth: CGFloat { max(7, shaftWidth * 3) }

    static func headPath(
        tip: NSPoint,
        unitX: CGFloat,
        unitY: CGFloat,
        length: CGFloat = headLength,
        width: CGFloat = headWidth
    ) -> CGMutablePath {
        let baseX = tip.x - unitX * length
        let baseY = tip.y - unitY * length
        let perpX = -unitY
        let perpY = unitX
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: baseX + perpX * width / 2, y: baseY + perpY * width / 2))
        path.addLine(to: CGPoint(x: baseX - perpX * width / 2, y: baseY - perpY * width / 2))
        path.closeSubpath()
        return path
    }

    static func drawHead(
        tip: NSPoint,
        unitX: CGFloat,
        unitY: CGFloat,
        length: CGFloat = headLength,
        width: CGFloat = headWidth,
        strokeWidth: CGFloat = headStrokeWidth,
        in context: CGContext
    ) {
        context.saveGState()
        context.addPath(headPath(tip: tip, unitX: unitX, unitY: unitY, length: length, width: width))
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
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
    let blockSize: CGFloat
    let style: MosaicStyle
    let blurRadius: CGFloat

    init(rect: NSRect, pixelatedImage: NSImage, blockSize: CGFloat,
         style: MosaicStyle = .pixelate, blurRadius: CGFloat = 12) {
        self.rect = rect
        self.pixelatedImage = pixelatedImage
        self.blockSize = blockSize
        self.style = style
        self.blurRadius = CGFloat(Defaults.normalizedMosaicBlurRadius(Double(blurRadius)))
    }

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
            pixelatedImage: pixelatedImage,
            blockSize: blockSize,
            style: style,
            blurRadius: blurRadius
        )
    }
}

// MARK: - Spotlight Annotation

/// A transparent rectangular window surrounded by a dimming layer. Spotlight
/// annotations are composited together by `EditCanvasView`, so several
/// windows share one overlay instead of repeatedly darkening each other.
struct SpotlightAnnotation: Annotation {
    let rect: NSRect

    static let dimmingAlpha: CGFloat = 0.52
    static let cornerRadius: CGFloat = 6

    var boundingRect: NSRect { rect }

    func draw(in context: CGContext, bounds: NSRect) {
        Self.drawDimmingOverlay(highlightRects: [rect], in: context, bounds: bounds)
    }

    static func drawDimmingOverlay(
        highlightRects: [NSRect],
        in context: CGContext,
        bounds: NSRect
    ) {
        guard !highlightRects.isEmpty else { return }
        let visibleRects = highlightRects
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(dimmingAlpha).cgColor)
        context.fill(bounds)
        context.setBlendMode(.clear)
        for rect in visibleRects {
            let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        rect.contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        SpotlightAnnotation(rect: rect.offsetBy(dx: delta.x, dy: delta.y))
    }

    func withRect(_ rect: NSRect) -> SpotlightAnnotation {
        SpotlightAnnotation(rect: rect)
    }
}

// MARK: - Magnifier Annotation

/// A circular magnifying-glass lens placed over the screenshot. The lens
/// samples the base image beneath `sourceCenter` (or beneath itself by
/// default) and redraws that region enlarged `zoom`× inside a plain line
/// frame. It holds a reference to the source image and re-samples it on every
/// draw, so moving or resizing the lens always shows fresh underlying pixels.
struct MagnifierAnnotation: Annotation {
    let center: NSPoint
    let radius: CGFloat
    let color: NSColor
    let lineWidth: CGFloat
    /// Magnification factor — the lens shows a `2·radius / zoom` wide region
    /// blown up to fill the `2·radius` circle.
    let zoom: CGFloat
    /// Base screenshot this lens magnifies. Sampled fresh on every draw.
    let sourceImage: NSImage
    /// Optional canvas point magnified by the lens. nil keeps the classic
    /// loupe behavior where the lens samples directly beneath its center.
    let sourceCenter: NSPoint?

    static let defaultZoom: CGFloat = 2.0
    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 6.0
    static let zoomStep: CGFloat = 0.5
    /// Smallest radius the lens may be created or resized to.
    static let minRadius: CGFloat = 16
    /// Dragging the source handle this close to the lens center resets the
    /// lens to the default "magnify what is under me" behavior.
    static let sourceResetDistance: CGFloat = 8

    var effectiveSourceCenter: NSPoint {
        sourceCenter ?? center
    }

    var boundingRect: NSRect {
        NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    init(
        center: NSPoint,
        radius: CGFloat,
        color: NSColor,
        lineWidth: CGFloat,
        zoom: CGFloat,
        sourceImage: NSImage,
        sourceCenter: NSPoint? = nil
    ) {
        self.center = center
        self.radius = radius
        self.color = color
        self.lineWidth = lineWidth
        self.zoom = zoom
        self.sourceImage = sourceImage
        self.sourceCenter = sourceCenter
    }

    private static func sourceIndicatorRadius(for lensRadius: CGFloat) -> CGFloat {
        max(12, min(24, lensRadius * 0.14))
    }

    private var detachedSourceGeometry: (source: NSPoint, start: NSPoint, end: NSPoint, indicatorRadius: CGFloat)? {
        guard let source = sourceCenter else { return nil }
        let dx = source.x - center.x
        let dy = source.y - center.y
        let distance = hypot(dx, dy)
        let indicatorRadius = Self.sourceIndicatorRadius(for: radius)
        guard distance > radius + indicatorRadius + 2 else { return nil }

        let ux = dx / distance
        let uy = dy / distance
        return (
            source: source,
            start: NSPoint(x: center.x + ux * radius, y: center.y + uy * radius),
            end: NSPoint(x: source.x - ux * indicatorRadius, y: source.y - uy * indicatorRadius),
            indicatorRadius: indicatorRadius
        )
    }

    func draw(in context: CGContext, bounds: NSRect) {
        guard radius > 6, let nsContext = NSGraphicsContext.current else { return }

        let squareRect = boundingRect
        let circle = NSBezierPath(ovalIn: squareRect)

        if let geometry = detachedSourceGeometry {
            drawSourceConnector(geometry, in: context)
        }

        // 1. Magnified content, clipped to the circle. The source region is
        // `2·radius / zoom` wide in canvas coords, centered on the lens; map
        // it into the source image's coordinate space and blow it up to fill.
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let imgSize = sourceImage.size
        let scaleX = bounds.width > 0 ? imgSize.width / bounds.width : 1
        let scaleY = bounds.height > 0 ? imgSize.height / bounds.height : 1
        let srcSize = (radius * 2) / max(zoom, 1)
        let sampleCenter = effectiveSourceCenter
        let fromRect = NSRect(
            x: (sampleCenter.x - srcSize / 2) * scaleX,
            y: (sampleCenter.y - srcSize / 2) * scaleY,
            width: srcSize * scaleX,
            height: srcSize * scaleY
        )
        nsContext.imageInterpolation = .high
        sourceImage.draw(in: squareRect, from: fromRect, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // 2. Plain annotation stroke, matching rectangle / ellipse tools.
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: squareRect)

        if let geometry = detachedSourceGeometry {
            drawSourceIndicator(geometry, in: context)
        }
    }

    private func drawSourceConnector(
        _ geometry: (source: NSPoint, start: NSPoint, end: NSPoint, indicatorRadius: CGFloat),
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        context.move(to: geometry.start)
        context.addLine(to: geometry.end)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSourceIndicator(
        _ geometry: (source: NSPoint, start: NSPoint, end: NSPoint, indicatorRadius: CGFloat),
        in context: CGContext
    ) {
        let rect = NSRect(
            x: geometry.source.x - geometry.indicatorRadius,
            y: geometry.source.y - geometry.indicatorRadius,
            width: geometry.indicatorRadius * 2,
            height: geometry.indicatorRadius * 2
        )
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        if hypot(point.x - center.x, point.y - center.y) <= radius {
            return true
        }
        guard let geometry = detachedSourceGeometry else { return false }
        if hypot(point.x - geometry.source.x, point.y - geometry.source.y) <= geometry.indicatorRadius + 5 {
            return true
        }
        return distanceFrom(point, toSegmentFrom: geometry.start, to: geometry.end) <= 6
    }

    func translated(by delta: NSPoint) -> Annotation {
        MagnifierAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }

    func translatedPreservingSourceFocus(by delta: NSPoint) -> MagnifierAnnotation {
        MagnifierAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: effectiveSourceCenter
        )
    }

    /// A document crop or extension moves both the lens and its sampling
    /// coordinates. Unlike dragging the lens, it also replaces the bitmap
    /// whose size defines the sampling scale in `draw(in:bounds:)`.
    func remappedToDocument(_ image: NSImage, by delta: NSPoint) -> MagnifierAnnotation {
        MagnifierAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: image,
            sourceCenter: sourceCenter.map {
                NSPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
        )
    }

    func withRadius(_ radius: CGFloat) -> MagnifierAnnotation {
        MagnifierAnnotation(
            center: center,
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }

    func withSourceCenter(_ sourceCenter: NSPoint?) -> MagnifierAnnotation {
        MagnifierAnnotation(
            center: center,
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }

    func withZoom(_ zoom: CGFloat) -> MagnifierAnnotation {
        MagnifierAnnotation(
            center: center,
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: min(max(zoom, Self.minZoom), Self.maxZoom),
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        MagnifierAnnotation(
            center: center,
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        MagnifierAnnotation(
            center: center,
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }
}

// MARK: - Rectangle Annotation

struct RectAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    let fillMode: ShapeFillMode
    let strokeStyle: ShapeStrokeStyle
    let roughStyle: RoughShapeStyle
    var rotation: CGFloat = 0

    init(
        rect: NSRect,
        color: NSColor,
        lineWidth: CGFloat,
        filled: Bool = false,
        fillMode: ShapeFillMode? = nil,
        strokeStyle: ShapeStrokeStyle = .standard,
        roughStyle: RoughShapeStyle? = nil,
        rotation: CGFloat = 0
    ) {
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.fillMode = fillMode ?? (filled ? .opaque : .none)
        self.strokeStyle = strokeStyle
        self.roughStyle = roughStyle ?? RoughShapeStyle.make(rect: rect, lineWidth: lineWidth)
        self.rotation = rotation
    }

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }
    var filled: Bool { fillMode.isFilled }

    func draw(in context: CGContext, bounds: NSRect) {
        ShapeDrawing.fillRect(rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
        ShapeDrawing.strokeRect(rect, color: color, lineWidth: lineWidth, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = ShapeDrawing.rectPath(rect, lineWidth: lineWidth, strokeStyle: strokeStyle)
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
            fillMode: fillMode,
            strokeStyle: strokeStyle,
            roughStyle: roughStyle,
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle.tuned(for: rect, lineWidth: lineWidth), rotation: rotation)
    }

    func withFill(_ filled: Bool) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation {
        RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }
}

// MARK: - Ellipse Annotation

struct EllipseAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    let fillMode: ShapeFillMode
    let strokeStyle: ShapeStrokeStyle
    let roughStyle: RoughShapeStyle
    var rotation: CGFloat = 0

    init(
        rect: NSRect,
        color: NSColor,
        lineWidth: CGFloat,
        filled: Bool = false,
        fillMode: ShapeFillMode? = nil,
        strokeStyle: ShapeStrokeStyle = .standard,
        roughStyle: RoughShapeStyle? = nil,
        rotation: CGFloat = 0
    ) {
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.fillMode = fillMode ?? (filled ? .opaque : .none)
        self.strokeStyle = strokeStyle
        self.roughStyle = roughStyle ?? RoughShapeStyle.make(rect: rect, lineWidth: lineWidth)
        self.rotation = rotation
    }

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }
    var filled: Bool { fillMode.isFilled }

    func draw(in context: CGContext, bounds: NSRect) {
        ShapeDrawing.fillEllipse(rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
        ShapeDrawing.strokeEllipse(rect, color: color, lineWidth: lineWidth, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
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
            fillMode: fillMode,
            strokeStyle: strokeStyle,
            roughStyle: roughStyle,
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle.tuned(for: rect, lineWidth: lineWidth), rotation: rotation)
    }

    func withFill(_ filled: Bool) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation {
        EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }
}

// MARK: - Arrow Annotation

struct ArrowAnnotation: Annotation {
    let startPoint: NSPoint
    let endPoint: NSPoint
    let color: NSColor
    let lineWidth: CGFloat
    let style: ArrowStyle
    /// Optional curve handle. When set, the shaft is drawn as a quadratic
    /// bezier through `controlPoint` and the arrowhead orientation follows
    /// the tangent at the end of the curve. nil = straight arrow.
    var controlPoint: NSPoint? = nil

    init(
        startPoint: NSPoint,
        endPoint: NSPoint,
        color: NSColor,
        lineWidth: CGFloat,
        style: ArrowStyle = .tapered,
        controlPoint: NSPoint? = nil
    ) {
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.lineWidth = lineWidth
        self.style = style
        self.controlPoint = controlPoint
    }

    var boundingRect: NSRect {
        var minX = min(startPoint.x, endPoint.x)
        var minY = min(startPoint.y, endPoint.y)
        var maxX = max(startPoint.x, endPoint.x)
        var maxY = max(startPoint.y, endPoint.y)
        if let cp = controlPoint {
            minX = min(minX, cp.x); maxX = max(maxX, cp.x)
            minY = min(minY, cp.y); maxY = max(maxY, cp.y)
        }

        // The drawn polygon flares out perpendicular to the spine by up to
        // headWidth/2 at the arrowhead's outer corners, which would sit
        // outside the spine-only rect. Inflate so erase/selection rect
        // intersection tests cover the rendered pixels.
        let pad = boundingPad
        return NSRect(
            x: minX - pad,
            y: minY - pad,
            width: maxX - minX + 2 * pad,
            height: maxY - minY + 2 * pad
        )
    }

    private var boundingPad: CGFloat {
        switch style {
        case .tapered:
            return (arrowGeometry?.headWidth ?? 0) / 2
        case .doubleEnded, .line, .dotTail:
            guard let metrics = strokedMetrics else { return lineWidth / 2 }
            return max(metrics.headWidth / 2, metrics.shaftWidth / 2, metrics.tailRadius) + NumberArrowShape.headStrokeWidth + 2
        }
    }

    /// Scaled geometry shared by `draw`, `containsPoint`, and `boundingRect`.
    /// Returns `nil` when the arrow is degenerate (zero length).
    private struct ArrowGeometry {
        let length: CGFloat
        let unitX: CGFloat
        let unitY: CGFloat
        let perpX: CGFloat
        let perpY: CGFloat
        let headLength: CGFloat
        let headWidth: CGFloat
        let neckHalf: CGFloat
        let tailHalf: CGFloat
        let neckIndent: CGFloat
    }

    private var arrowGeometry: ArrowGeometry? {
        let dx: CGFloat
        let dy: CGFloat
        if let cp = controlPoint {
            dx = endPoint.x - cp.x
            dy = endPoint.y - cp.y
        } else {
            dx = endPoint.x - startPoint.x
            dy = endPoint.y - startPoint.y
        }
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return nil }

        var headLength: CGFloat = max(22, lineWidth * 6.5)
        var headWidth: CGFloat = max(22, lineWidth * 7.5)
        var neckHalf: CGFloat = max(3, lineWidth * 1.4)
        var tailHalf: CGFloat = max(0.5, lineWidth * 0.25)

        // Short arrow: scale the whole geometry down proportionally so the
        // head's base never overshoots the tail and the polygon stays
        // simple instead of self-intersecting.
        //
        // Use the actual arrow span (chord |end - start|) — not `length`,
        // which for curved arrows is just the end-tangent magnitude
        // |end - cp|. Dragging the curve handle near the tip would
        // otherwise collapse a long arrow into a sliver.
        let spanLength: CGFloat = controlPoint == nil
            ? length
            : hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        if spanLength > 0 && spanLength < headLength {
            let scale = spanLength / headLength
            headWidth *= scale
            neckHalf *= scale
            tailHalf *= scale
            headLength = spanLength
        }

        let unitX = dx / length
        let unitY = dy / length
        return ArrowGeometry(
            length: length,
            unitX: unitX,
            unitY: unitY,
            perpX: -unitY,
            perpY: unitX,
            headLength: headLength,
            headWidth: headWidth,
            neckHalf: neckHalf,
            tailHalf: tailHalf,
            neckIndent: headLength * 0.14
        )
    }

    private struct UnitVector {
        let x: CGFloat
        let y: CGFloat
        let length: CGFloat
    }

    private struct StrokedGeometry {
        let startUnit: UnitVector
        let endUnit: UnitVector
        let spanLength: CGFloat
    }

    private struct StrokedMetrics {
        let headLength: CGFloat
        let headWidth: CGFloat
        let shaftWidth: CGFloat
        let tailRadius: CGFloat
    }

    private var strokedGeometry: StrokedGeometry? {
        let chordDX = endPoint.x - startPoint.x
        let chordDY = endPoint.y - startPoint.y
        let chordLength = hypot(chordDX, chordDY)
        guard chordLength > 0 else { return nil }

        let rawStartDX: CGFloat
        let rawStartDY: CGFloat
        let rawEndDX: CGFloat
        let rawEndDY: CGFloat
        if let cp = controlPoint {
            rawStartDX = cp.x - startPoint.x
            rawStartDY = cp.y - startPoint.y
            rawEndDX = endPoint.x - cp.x
            rawEndDY = endPoint.y - cp.y
        } else {
            rawStartDX = chordDX
            rawStartDY = chordDY
            rawEndDX = chordDX
            rawEndDY = chordDY
        }

        let startUnit = normalized(dx: rawStartDX, dy: rawStartDY)
            ?? normalized(dx: chordDX, dy: chordDY)
        let endUnit = normalized(dx: rawEndDX, dy: rawEndDY)
            ?? normalized(dx: chordDX, dy: chordDY)
        guard let startUnit, let endUnit else { return nil }
        return StrokedGeometry(startUnit: startUnit, endUnit: endUnit, spanLength: chordLength)
    }

    private var strokedMetrics: StrokedMetrics? {
        guard let geometry = strokedGeometry else { return nil }
        let headLimit = style == .doubleEnded ? 0.34 : 0.46
        guard style != .tapered else { return nil }
        let shaftWidth = max(1, lineWidth)
        var headLength = max(10, shaftWidth * 4)
        var headWidth = max(7, shaftWidth * 3)
        let tailRadius: CGFloat = style == .dotTail ? max(4, shaftWidth + 2) : 0
        headLength = min(headLength, max(4, geometry.spanLength * headLimit))
        headWidth = min(headWidth, max(6, geometry.spanLength * 0.75))
        return StrokedMetrics(
            headLength: headLength,
            headWidth: headWidth,
            shaftWidth: shaftWidth,
            tailRadius: tailRadius
        )
    }

    private func normalized(dx: CGFloat, dy: CGFloat) -> UnitVector? {
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        return UnitVector(x: dx / length, y: dy / length, length: length)
    }

    private func point(_ point: NSPoint, advancedBy distance: CGFloat, along unit: UnitVector) -> NSPoint {
        NSPoint(x: point.x + unit.x * distance, y: point.y + unit.y * distance)
    }

    private func insetSpineEndpoints(
        geometry: StrokedGeometry,
        metrics: StrokedMetrics
    ) -> (start: NSPoint, end: NSPoint) {
        var startInset: CGFloat = 0
        var endInset: CGFloat = metrics.headLength

        if style == .doubleEnded {
            startInset = metrics.headLength
        }

        let totalInset = startInset + endInset
        if totalInset > geometry.spanLength - 1, totalInset > 0 {
            let scale = max(0, geometry.spanLength - 1) / totalInset
            startInset *= scale
            endInset *= scale
        }

        return (
            point(startPoint, advancedBy: startInset, along: geometry.startUnit),
            point(endPoint, advancedBy: -endInset, along: geometry.endUnit)
        )
    }

    private func spinePath(from start: NSPoint, to end: NSPoint) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: start)
        if let cp = controlPoint {
            path.addQuadCurve(to: end, control: cp)
        } else {
            path.addLine(to: end)
        }
        return path
    }

    private func arrowHeadPath(
        tip: NSPoint,
        unitX: CGFloat,
        unitY: CGFloat,
        length: CGFloat,
        width: CGFloat
    ) -> CGMutablePath {
        NumberArrowShape.headPath(tip: tip, unitX: unitX, unitY: unitY, length: length, width: width)
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
        switch style {
        case .tapered:
            drawTapered(in: context, bounds: bounds)
        case .doubleEnded, .line, .dotTail:
            drawStroked(in: context, bounds: bounds)
        }
    }

    private func drawTapered(in context: CGContext, bounds: NSRect) {
        guard let g = arrowGeometry else { return }
        context.setFillColor(color.cgColor)

        // Head base center and the concave neck point (closer to the tip).
        let baseX = endPoint.x - g.unitX * g.headLength
        let baseY = endPoint.y - g.unitY * g.headLength
        let neckX = endPoint.x - g.unitX * (g.headLength - g.neckIndent)
        let neckY = endPoint.y - g.unitY * (g.headLength - g.neckIndent)

        // Outer corners of the arrowhead.
        let headLX = baseX + g.perpX * g.headWidth / 2
        let headLY = baseY + g.perpY * g.headWidth / 2
        let headRX = baseX - g.perpX * g.headWidth / 2
        let headRY = baseY - g.perpY * g.headWidth / 2

        // Where the shaft meets the head (concave base).
        let neckLX = neckX + g.perpX * g.neckHalf
        let neckLY = neckY + g.perpY * g.neckHalf
        let neckRX = neckX - g.perpX * g.neckHalf
        let neckRY = neckY - g.perpY * g.neckHalf

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

            // Perpendicular at the control point — uses the chord direction
            // (start → end), which equals the sum of the in/out tangents at
            // the control point of a quadratic bezier.
            let cpTangentX = endPoint.x - startPoint.x
            let cpTangentY = endPoint.y - startPoint.y
            let cpTangentLen = max(hypot(cpTangentX, cpTangentY), 0.0001)
            let cpPerpX = -cpTangentY / cpTangentLen
            let cpPerpY = cpTangentX / cpTangentLen

            // Width at the control point — linearly between tail and neck.
            let midHalf = (g.tailHalf + g.neckHalf) * 0.5

            // Truncate the cp via de Casteljau so the shaft is the actual
            // sub-bezier from t=0 to t≈t_neck of the original spine curve.
            // Using `cp` directly would let the shaft bulge well past where
            // the original quadratic was. For a quadratic bezier the
            // velocity at the endpoint is 2·(end - cp), so the parameter
            // step to cover distance d from the tip is d/(2·length).
            let neckDist = g.headLength - g.neckIndent
            let t = max(0, min(1, 1 - neckDist / (2 * g.length)))
            let cpTruncX = startPoint.x + (cp.x - startPoint.x) * t
            let cpTruncY = startPoint.y + (cp.y - startPoint.y) * t

            let tailLX = startPoint.x + startPerpX * g.tailHalf
            let tailLY = startPoint.y + startPerpY * g.tailHalf
            let tailRX = startPoint.x - startPerpX * g.tailHalf
            let tailRY = startPoint.y - startPerpY * g.tailHalf
            let cpLX = cpTruncX + cpPerpX * midHalf
            let cpLY = cpTruncY + cpPerpY * midHalf
            let cpRX = cpTruncX - cpPerpX * midHalf
            let cpRY = cpTruncY - cpPerpY * midHalf

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
            let tailLX = startPoint.x + g.perpX * g.tailHalf
            let tailLY = startPoint.y + g.perpY * g.tailHalf
            let tailRX = startPoint.x - g.perpX * g.tailHalf
            let tailRY = startPoint.y - g.perpY * g.tailHalf

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

    private func drawStroked(in context: CGContext, bounds: NSRect) {
        guard let geometry = strokedGeometry, let metrics = strokedMetrics else { return }
        let endpoints = insetSpineEndpoints(geometry: geometry, metrics: metrics)
        let path = spinePath(from: endpoints.start, to: endpoints.end)

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(metrics.shaftWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()

        NumberArrowShape.drawHead(
            tip: endPoint,
            unitX: geometry.endUnit.x,
            unitY: geometry.endUnit.y,
            length: metrics.headLength,
            width: metrics.headWidth,
            in: context
        )

        if style == .doubleEnded {
            NumberArrowShape.drawHead(
                tip: startPoint,
                unitX: -geometry.startUnit.x,
                unitY: -geometry.startUnit.y,
                length: metrics.headLength,
                width: metrics.headWidth,
                in: context
            )
        } else if style == .dotTail {
            let rect = NSRect(
                x: startPoint.x - metrics.tailRadius,
                y: startPoint.y - metrics.tailRadius,
                width: metrics.tailRadius * 2,
                height: metrics.tailRadius * 2
            )
            context.fillEllipse(in: rect)
        }

        context.restoreGState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        switch style {
        case .tapered:
            return containsTapered(point)
        case .doubleEnded, .line, .dotTail:
            return containsStroked(point)
        }
    }

    private func containsTapered(_ point: NSPoint) -> Bool {
        // Match the rendered silhouette exactly: scaled head polygon for
        // the concave swept arrowhead + scaled shaft polygon for the
        // tapered body. A small `grab` inflation keeps the thin tail
        // clickable without resorting to a uniform fat spine band that
        // would under-cover the much wider neck at large line widths.
        guard let g = arrowGeometry else { return false }
        let grab: CGFloat = 3

        let baseX = endPoint.x - g.unitX * g.headLength
        let baseY = endPoint.y - g.unitY * g.headLength
        let neckX = endPoint.x - g.unitX * (g.headLength - g.neckIndent)
        let neckY = endPoint.y - g.unitY * (g.headLength - g.neckIndent)

        // Head polygon — concave swept silhouette, matches draw().
        let headHalf = g.headWidth / 2 + grab
        let neckHitHalf = g.neckHalf + grab
        let head = CGMutablePath()
        head.move(to: endPoint)
        head.addLine(to: CGPoint(x: baseX + g.perpX * headHalf, y: baseY + g.perpY * headHalf))
        head.addLine(to: CGPoint(x: neckX + g.perpX * neckHitHalf, y: neckY + g.perpY * neckHitHalf))
        head.addLine(to: CGPoint(x: neckX - g.perpX * neckHitHalf, y: neckY - g.perpY * neckHitHalf))
        head.addLine(to: CGPoint(x: baseX - g.perpX * headHalf, y: baseY - g.perpY * headHalf))
        head.closeSubpath()
        if head.contains(point) {
            return true
        }

        // Shaft polygon — tapered trapezoid (straight) or tapered bezier
        // band (curved). Mirrors the geometry drawn in `draw(in:bounds:)`.
        let tailHitHalf = g.tailHalf + grab
        let shaft = CGMutablePath()
        if let cp = controlPoint {
            let startDX = cp.x - startPoint.x
            let startDY = cp.y - startPoint.y
            let startLen = max(hypot(startDX, startDY), 0.0001)
            let startPerpX = -startDY / startLen
            let startPerpY = startDX / startLen

            let cpTangentX = endPoint.x - startPoint.x
            let cpTangentY = endPoint.y - startPoint.y
            let cpTangentLen = max(hypot(cpTangentX, cpTangentY), 0.0001)
            let cpPerpX = -cpTangentY / cpTangentLen
            let cpPerpY = cpTangentX / cpTangentLen

            let midHitHalf = (tailHitHalf + neckHitHalf) * 0.5

            // Match draw(): truncate cp so the hit-test curve traces the
            // same sub-bezier as the rendered shaft, not the original
            // (over-bulged) one.
            let neckDist = g.headLength - g.neckIndent
            let t = max(0, min(1, 1 - neckDist / (2 * g.length)))
            let cpTruncX = startPoint.x + (cp.x - startPoint.x) * t
            let cpTruncY = startPoint.y + (cp.y - startPoint.y) * t

            shaft.move(to: CGPoint(x: startPoint.x + startPerpX * tailHitHalf,
                                   y: startPoint.y + startPerpY * tailHitHalf))
            shaft.addQuadCurve(
                to: CGPoint(x: neckX + g.perpX * neckHitHalf, y: neckY + g.perpY * neckHitHalf),
                control: CGPoint(x: cpTruncX + cpPerpX * midHitHalf, y: cpTruncY + cpPerpY * midHitHalf)
            )
            shaft.addLine(to: CGPoint(x: neckX - g.perpX * neckHitHalf, y: neckY - g.perpY * neckHitHalf))
            shaft.addQuadCurve(
                to: CGPoint(x: startPoint.x - startPerpX * tailHitHalf,
                            y: startPoint.y - startPerpY * tailHitHalf),
                control: CGPoint(x: cpTruncX - cpPerpX * midHitHalf, y: cpTruncY - cpPerpY * midHitHalf)
            )
            shaft.closeSubpath()
        } else {
            shaft.move(to: CGPoint(x: startPoint.x + g.perpX * tailHitHalf,
                                   y: startPoint.y + g.perpY * tailHitHalf))
            shaft.addLine(to: CGPoint(x: neckX + g.perpX * neckHitHalf, y: neckY + g.perpY * neckHitHalf))
            shaft.addLine(to: CGPoint(x: neckX - g.perpX * neckHitHalf, y: neckY - g.perpY * neckHitHalf))
            shaft.addLine(to: CGPoint(x: startPoint.x - g.perpX * tailHitHalf,
                                      y: startPoint.y - g.perpY * tailHitHalf))
            shaft.closeSubpath()
        }
        return shaft.contains(point)
    }

    private func containsStroked(_ point: NSPoint) -> Bool {
        guard let geometry = strokedGeometry, let metrics = strokedMetrics else { return false }
        let endpoints = insetSpineEndpoints(geometry: geometry, metrics: metrics)
        let path = spinePath(from: endpoints.start, to: endpoints.end)

        if strokedPathContains(path, point: point, lineWidth: metrics.shaftWidth) {
            return true
        }

        let endHead = arrowHeadPath(
            tip: endPoint,
            unitX: geometry.endUnit.x,
            unitY: geometry.endUnit.y,
            length: metrics.headLength,
            width: metrics.headWidth
        )
        if endHead.contains(point) {
            return true
        }

        if style == .doubleEnded {
            let startHead = arrowHeadPath(
                tip: startPoint,
                unitX: -geometry.startUnit.x,
                unitY: -geometry.startUnit.y,
                length: metrics.headLength,
                width: metrics.headWidth
            )
            return startHead.contains(point)
        }

        if style == .dotTail {
            return hypot(point.x - startPoint.x, point.y - startPoint.y) <= metrics.tailRadius + 4
        }

        return false
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
            style: style,
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
            style: style,
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
            style: style,
            controlPoint: controlPoint
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        ArrowAnnotation(
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        ArrowAnnotation(
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }

    func withStyle(_ style: ArrowStyle) -> ArrowAnnotation {
        ArrowAnnotation(
            startPoint: startPoint,
            endPoint: endPoint,
            color: color,
            lineWidth: lineWidth,
            style: style,
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

// MARK: - Image Annotation

struct ImageAnnotation: Annotation {
    let image: NSImage
    let rect: NSRect
    var rotation: CGFloat = 0

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: rect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return rect.insetBy(dx: -8, dy: -8).contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        ImageAnnotation(
            image: image,
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        ImageAnnotation(image: image, rect: rect, rotation: rotation)
    }

    func withRect(_ rect: NSRect) -> ImageAnnotation {
        ImageAnnotation(image: image, rect: rect, rotation: rotation)
    }
}

// MARK: - Emoji Annotation

struct EmojiAnnotation: Annotation {
    let emoji: String
    let rect: NSRect
    var rotation: CGFloat = 0

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        EmojiGlyphRenderer.image(for: emoji).draw(
            in: rect,
            from: NSRect(origin: .zero, size: EmojiGlyphRenderer.imageSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return rect.insetBy(dx: -8, dy: -8).contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EmojiAnnotation(
            emoji: emoji,
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        EmojiAnnotation(emoji: emoji, rect: rect, rotation: rotation)
    }

    func withRect(_ rect: NSRect) -> EmojiAnnotation {
        EmojiAnnotation(emoji: emoji, rect: rect, rotation: rotation)
    }
}

private enum EmojiGlyphRenderer {
    static let imageSize = NSSize(width: 128, height: 128)
    private static var cache: [String: NSImage] = [:]

    static func image(for emoji: String) -> NSImage {
        if let cached = cache[emoji] { return cached }

        let image = NSImage(size: imageSize, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: 96)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let measured = (emoji as NSString).size(withAttributes: attributes)
            let origin = NSPoint(
                x: rect.midX - measured.width / 2,
                y: rect.midY - measured.height / 2
            )
            (emoji as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
        cache[emoji] = image
        return image
    }
}

// MARK: - Text Annotation

struct TextAnnotation: Annotation {
    let text: String
    /// Bottom-left of the editing/drawing frame, in canvas coordinates.
    let origin: NSPoint
    let color: NSColor
    let fontSize: CGFloat
    /// Font family name the glyphs are drawn with. `nil` keeps the historical
    /// system bold face, so existing annotations render exactly as before.
    var fontName: String? = nil
    var rotation: CGFloat = 0
    /// When true the glyphs get a black-or-white outline picked for maximum
    /// contrast against `color`, so the text reads against any background.
    var hasStroke: Bool = false
    /// Callout mode turns `color` into the bubble/arrow fill and renders glyphs
    /// in black or white for contrast.
    var hasCallout: Bool = false
    /// Optional arrow tip pulled out from the callout bubble via the selection
    /// handle. nil means bubble only.
    var calloutTip: NSPoint? = nil
    /// Optional second arrow tip. New text callouts leave this nil so the
    /// creation drag still produces exactly one leader; a selected callout
    /// exposes a separate add handle for pulling this one out.
    var secondCalloutTip: NSPoint? = nil

    static let trailingCaretPadding: CGFloat = 12
    static let minimumEditorWidth: CGFloat = 32
    static let calloutHorizontalPadding: CGFloat = 10
    static let calloutVerticalPadding: CGFloat = 4
    static let calloutCornerRadius: CGFloat = 7
    static let calloutHandleOffset: CGFloat = 18
    static let calloutArrowMinDistance: CGFloat = 18
    static let calloutArrowLineWidth: CGFloat = 3
    private static let calloutTailBaseWidth: CGFloat = 30
    private static let calloutTailTipMaxRadius: CGFloat = 3.2
    private static let textVerticalCenteringFactor: CGFloat = 0.2

    /// Outline pen width for the silhouette pass, as the percentage-of-font
    /// unit `NSAttributedString.Key.strokeWidth` expects. The fill pass on top
    /// covers the inner half, so the visible outline is roughly half of this.
    static let strokeWidthPercent: CGFloat = 6.0

    /// Single resolution entry point for every place that needs the text
    /// annotation's face — drawing, measuring, the live editor field and the
    /// font-preview menus. `nil` (or a family that is no longer installed)
    /// resolves to the system bold face the tool has always used. An installed
    /// family prefers its bold variant and falls back to the regular one.
    static func font(named fontName: String?, size: CGFloat) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let family = fontName, !family.isEmpty else { return fallback }
        let manager = NSFontManager.shared
        if let bold = manager.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size) {
            return bold
        }
        if let regular = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
            return regular
        }
        return NSFont(name: family, size: size) ?? fallback
    }

    static func font(forSize size: CGFloat) -> NSFont {
        font(named: nil, size: size)
    }

    /// The face this annotation actually renders with.
    var resolvedFont: NSFont {
        TextAnnotation.font(named: fontName, size: fontSize)
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

    static func contrastingTextColor(for background: NSColor) -> NSColor {
        strokeColor(for: background)
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func lines(for text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return lines.isEmpty ? [""] : lines
    }

    private static func measuredLineWidth(_ line: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        return ceil((line as NSString).size(withAttributes: attributes).width)
    }

    private static func inkBounds(for line: String, attributes: [NSAttributedString.Key: Any]) -> NSRect {
        let textToMeasure = line.isEmpty ? "M" : line
        return NSAttributedString(string: textToMeasure, attributes: attributes).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesDeviceMetrics]
        )
    }

    private static func centeredDrawOffsetY(
        for line: String,
        lineHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let ink = inkBounds(for: line, attributes: attributes)
        let metricOffset = (lineHeight - ink.height) / 2 - ink.origin.y
        return metricOffset * textVerticalCenteringFactor
    }

    static func editorSize(for text: String, font: NSFont) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = Self.lines(for: text)
        let fallbackWidth = ceil(("M" as NSString).size(withAttributes: attrs).width)
        let measuredWidth = lines
            .map { measuredLineWidth($0, attributes: attrs) }
            .max() ?? fallbackWidth
        let lineCount = max(1, lines.count)
        return NSSize(
            width: max(measuredWidth + trailingCaretPadding, minimumEditorWidth),
            height: lineHeight(for: font) * CGFloat(lineCount)
        )
    }

    /// Tight ink-bounds rect for the rendered glyphs, in canvas coordinates.
    ///
    /// Used for the dashed selection frame and as the rotation pivot, so the
    /// chrome hugs what's actually painted instead of the editor frame's
    /// trailing-caret padding + line leading (which made the box look skewed
    /// toward bottom-left of the text).
    var textBounds: NSRect {
        let font = resolvedFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = TextAnnotation.lines(for: text)
        let lineHeight = TextAnnotation.lineHeight(for: font)
        let rects = lines.enumerated().map { index, line in
            let ink = TextAnnotation.inkBounds(for: line, attributes: attrs)
            let offsetY = TextAnnotation.centeredDrawOffsetY(
                for: line,
                lineHeight: lineHeight,
                attributes: attrs
            )
            return NSRect(
                x: origin.x + ink.origin.x,
                y: origin.y + lineHeight * CGFloat(lines.count - 1 - index) + offsetY + ink.origin.y,
                width: ink.width,
                height: ink.height
            )
        }
        guard let first = rects.first else { return textBlockRect }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    var textBlockRect: NSRect {
        let font = resolvedFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = TextAnnotation.lines(for: text)
        let measuredWidth = lines
            .map { TextAnnotation.measuredLineWidth($0, attributes: attrs) }
            .max() ?? 0
        let blockHeight = TextAnnotation.lineHeight(for: font) * CGFloat(lines.count)
        let width = max(measuredWidth, TextAnnotation.minimumEditorWidth - TextAnnotation.trailingCaretPadding)
        return NSRect(x: origin.x, y: origin.y, width: width, height: blockHeight)
    }

    var calloutBodyRect: NSRect {
        textBlockRect.insetBy(
            dx: -TextAnnotation.calloutHorizontalPadding,
            dy: -TextAnnotation.calloutVerticalPadding
        )
    }

    var calloutHandlePoint: NSPoint {
        calloutTip ?? NSPoint(
            x: calloutBodyRect.midX,
            y: calloutBodyRect.minY - TextAnnotation.calloutHandleOffset
        )
    }

    var secondCalloutHandlePoint: NSPoint {
        secondCalloutTip ?? NSPoint(
            x: calloutBodyRect.minX - TextAnnotation.calloutHandleOffset,
            y: calloutBodyRect.midY
        )
    }

    var hasCalloutArrow: Bool {
        hasCalloutArrow(to: calloutTip)
    }

    var hasSecondCalloutArrow: Bool {
        hasCalloutArrow(to: secondCalloutTip)
    }

    private func hasCalloutArrow(to tip: NSPoint?) -> Bool {
        guard hasCallout, let tip else { return false }
        guard !calloutBodyRect.insetBy(dx: -2, dy: -2).contains(tip) else { return false }
        let anchor = calloutAnchorPoint(for: tip)
        return hypot(tip.x - anchor.x, tip.y - anchor.y) >= TextAnnotation.calloutArrowMinDistance
    }

    var hitBounds: NSRect {
        textBounds.insetBy(dx: -10, dy: -max(10, fontSize * 0.75))
    }

    var boundingRect: NSRect {
        guard hasCallout else { return textBounds }
        return calloutBackgroundPath().boundingBoxOfPath
            .insetBy(dx: -TextAnnotation.calloutArrowLineWidth, dy: -TextAnnotation.calloutArrowLineWidth)
    }
    var supportsRotation: Bool { true }

    func calloutAnchorPoint(for tip: NSPoint?) -> NSPoint {
        calloutAnchorPoint(for: tip, in: calloutBodyRect)
    }

    private func calloutAnchorPoint(for tip: NSPoint?, in rect: NSRect) -> NSPoint {
        guard let tip else {
            return NSPoint(x: rect.midX, y: rect.minY)
        }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let dx = tip.x - center.x
        let dy = tip.y - center.y
        guard dx != 0 || dy != 0 else {
            return NSPoint(x: rect.midX, y: rect.minY)
        }

        let tx: CGFloat = dx > 0
            ? (rect.maxX - center.x) / dx
            : (dx < 0 ? (rect.minX - center.x) / dx : .greatestFiniteMagnitude)
        let ty: CGFloat = dy > 0
            ? (rect.maxY - center.y) / dy
            : (dy < 0 ? (rect.minY - center.y) / dy : .greatestFiniteMagnitude)
        let t = min(tx, ty)
        guard t.isFinite, t > 0 else {
            return NSPoint(x: rect.midX, y: rect.minY)
        }
        return NSPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    func draw(in context: CGContext, bounds: NSRect) {
        let font = resolvedFont
        let lines = TextAnnotation.lines(for: text)
        let lineHeight = TextAnnotation.lineHeight(for: font)
        NSGraphicsContext.saveGraphicsState()
        if hasCallout {
            drawCalloutBackground(in: context)
        }
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: hasCallout ? TextAnnotation.contrastingTextColor(for: color) : color,
            .font: font
        ]
        let strokeAttributes: [NSAttributedString.Key: Any]? = {
            guard hasStroke, !hasCallout else { return nil }
            let stroke = TextAnnotation.strokeColor(for: color)
            return [
                .foregroundColor: stroke,
                .strokeColor: stroke,
                .strokeWidth: -TextAnnotation.strokeWidthPercent,
                .font: font
            ]
        }()

        for (index, line) in lines.enumerated() where !line.isEmpty {
            let offsetY = TextAnnotation.centeredDrawOffsetY(
                for: line,
                lineHeight: lineHeight,
                attributes: fillAttributes
            )
            let lineOrigin = NSPoint(
                x: origin.x,
                y: origin.y + lineHeight * CGFloat(lines.count - 1 - index) + offsetY
            )
            if let strokeAttributes {
                (line as NSString).draw(at: lineOrigin, withAttributes: strokeAttributes)
            }
            (line as NSString).draw(at: lineOrigin, withAttributes: fillAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawCalloutBackgroundOnly(in context: CGContext, bodyRect: NSRect? = nil) {
        guard hasCallout else { return }
        drawCalloutBackground(in: context, bodyRect: bodyRect ?? calloutBodyRect)
    }

    private func drawCalloutBackground(in context: CGContext, bodyRect: NSRect? = nil) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(calloutBackgroundPath(bodyRect: bodyRect ?? calloutBodyRect))
        context.fillPath()
        context.restoreGState()
    }

    private func calloutBackgroundPath() -> CGPath {
        calloutBackgroundPath(bodyRect: calloutBodyRect)
    }

    private func calloutBackgroundPath(bodyRect: NSRect) -> CGPath {
        let arrowTips = [
            hasCalloutArrow ? calloutTip : nil,
            hasSecondCalloutArrow ? secondCalloutTip : nil
        ].compactMap { $0 }
        guard let firstTip = arrowTips.first else {
            return CGPath(
                roundedRect: bodyRect,
                cornerWidth: TextAnnotation.calloutCornerRadius,
                cornerHeight: TextAnnotation.calloutCornerRadius,
                transform: nil
            )
        }
        guard arrowTips.count > 1 else {
            // Keep the established one-leader rendering path pixel-identical.
            return calloutBubblePath(to: firstTip, bodyRect: bodyRect)
        }

        // With two leaders, fill the rounded body and each tail as overlapping
        // subpaths. The shared fill makes a seamless union while allowing
        // both tails to occupy the same edge without path-order conflicts.
        let path = CGMutablePath()
        path.addPath(CGPath(
            roundedRect: bodyRect,
            cornerWidth: TextAnnotation.calloutCornerRadius,
            cornerHeight: TextAnnotation.calloutCornerRadius,
            transform: nil
        ))
        for tip in arrowTips {
            path.addPath(calloutTailPath(to: tip, bodyRect: bodyRect))
        }
        return path
    }

    private func calloutTailPath(to tip: NSPoint, bodyRect rect: NSRect) -> CGPath {
        let base = calloutTailBase(for: tip, in: rect)
        let path = CGMutablePath()
        path.move(to: base.start)
        appendCalloutTail(to: tip, base: base, in: path)
        path.closeSubpath()
        return path
    }

    private func calloutBubblePath(to tip: NSPoint, bodyRect rect: NSRect) -> CGPath {
        let radius = min(TextAnnotation.calloutCornerRadius, rect.width / 2, rect.height / 2)
        guard radius > 0 else {
            return CGPath(
                rect: rect,
                transform: nil
            )
        }

        let base = calloutTailBase(for: tip, in: rect)
        let path = CGMutablePath()
        let kappa: CGFloat = 0.552_284_749_830_793_6
        let k = radius * kappa

        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        path.move(to: NSPoint(x: minX + radius, y: minY))
        addBottomEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: NSPoint(x: maxX, y: minY + radius),
            control1: NSPoint(x: maxX - radius + k, y: minY),
            control2: NSPoint(x: maxX, y: minY + radius - k)
        )
        addRightEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: NSPoint(x: maxX - radius, y: maxY),
            control1: NSPoint(x: maxX, y: maxY - radius + k),
            control2: NSPoint(x: maxX - radius + k, y: maxY)
        )
        addTopEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: NSPoint(x: minX, y: maxY - radius),
            control1: NSPoint(x: minX + radius - k, y: maxY),
            control2: NSPoint(x: minX, y: maxY - radius + k)
        )
        addLeftEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: NSPoint(x: minX + radius, y: minY),
            control1: NSPoint(x: minX, y: minY + radius - k),
            control2: NSPoint(x: minX + radius - k, y: minY)
        )
        path.closeSubpath()
        return path
    }

    private func addBottomEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: NSPoint
    ) {
        if base.side == .bottom {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
    }

    private func addRightEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: NSPoint
    ) {
        if base.side == .right {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
    }

    private func addTopEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: NSPoint
    ) {
        if base.side == .top {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
    }

    private func addLeftEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: NSPoint
    ) {
        if base.side == .left {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: NSPoint(x: rect.minX, y: rect.minY + radius))
    }

    private func appendCalloutTail(to tip: NSPoint, base: CalloutTailBase, in path: CGMutablePath) {
        let dx = tip.x - base.center.x
        let dy = tip.y - base.center.y
        let distance = hypot(dx, dy)
        guard distance >= TextAnnotation.calloutArrowMinDistance else { return }
        let unitX = dx / distance
        let unitY = dy / distance
        let perpX = -unitY
        let perpY = unitX
        let tipRadius = min(
            TextAnnotation.calloutTailTipMaxRadius,
            max(1.25, fontSize * 0.05),
            distance * 0.08
        )
        let rootRound = min(max(5, fontSize * 0.22), base.halfWidth * 0.72, distance * 0.22)
        let sideControl = max(rootRound, distance * 0.32)

        let tipBack = NSPoint(x: tip.x - unitX * tipRadius, y: tip.y - unitY * tipRadius)
        let negativePerpTip = NSPoint(x: tipBack.x - perpX * tipRadius, y: tipBack.y - perpY * tipRadius)
        let positivePerpTip = NSPoint(x: tipBack.x + perpX * tipRadius, y: tipBack.y + perpY * tipRadius)
        let tangentDotPerp = base.tangent.dx * perpX + base.tangent.dy * perpY
        let startTip: NSPoint
        let endTip: NSPoint
        let startTipSide: CGVector
        let endTipSide: CGVector
        if tangentDotPerp >= 0 {
            startTip = negativePerpTip
            endTip = positivePerpTip
            startTipSide = CGVector(dx: -perpX, dy: -perpY)
            endTipSide = CGVector(dx: perpX, dy: perpY)
        } else {
            startTip = positivePerpTip
            endTip = negativePerpTip
            startTipSide = CGVector(dx: perpX, dy: perpY)
            endTipSide = CGVector(dx: -perpX, dy: -perpY)
        }
        let roundedTipControl = tipRadius * 0.55

        path.addCurve(
            to: startTip,
            control1: NSPoint(
                x: base.start.x + base.tangent.dx * rootRound,
                y: base.start.y + base.tangent.dy * rootRound
            ),
            control2: NSPoint(
                x: startTip.x - unitX * sideControl,
                y: startTip.y - unitY * sideControl
            )
        )
        path.addCurve(
            to: tip,
            control1: NSPoint(
                x: startTip.x + unitX * roundedTipControl,
                y: startTip.y + unitY * roundedTipControl
            ),
            control2: NSPoint(
                x: tip.x + startTipSide.dx * roundedTipControl,
                y: tip.y + startTipSide.dy * roundedTipControl
            )
        )
        path.addCurve(
            to: endTip,
            control1: NSPoint(
                x: tip.x + endTipSide.dx * roundedTipControl,
                y: tip.y + endTipSide.dy * roundedTipControl
            ),
            control2: NSPoint(
                x: endTip.x + unitX * roundedTipControl,
                y: endTip.y + unitY * roundedTipControl
            )
        )
        path.addCurve(
            to: base.end,
            control1: NSPoint(
                x: endTip.x - unitX * sideControl,
                y: endTip.y - unitY * sideControl
            ),
            control2: NSPoint(
                x: base.end.x - base.tangent.dx * rootRound,
                y: base.end.y - base.tangent.dy * rootRound
            )
        )
    }

    private struct CalloutTailBase {
        let center: NSPoint
        let start: NSPoint
        let end: NSPoint
        let tangent: CGVector
        let halfWidth: CGFloat
        let side: CalloutTailSide
    }

    private enum CalloutTailSide {
        case top
        case right
        case bottom
        case left
    }

    private func calloutTailBase(for tip: NSPoint, in rect: NSRect) -> CalloutTailBase {
        let anchor = calloutAnchorPoint(for: tip, in: rect)
        let side = calloutTailSide(for: anchor, tip: tip, in: rect)
        let desiredWidth = min(
            TextAnnotation.calloutTailBaseWidth,
            max(18, fontSize * 0.78)
        )
        let inset = TextAnnotation.calloutCornerRadius + 1

        let rawTangent: CGVector
        let availableSpan: CGFloat
        let center: NSPoint
        switch side {
        case .top:
            rawTangent = CGVector(dx: -1, dy: 0)
            availableSpan = max(2, rect.width - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = NSPoint(
                x: min(max(anchor.x, rect.minX + inset + half), rect.maxX - inset - half),
                y: rect.maxY
            )
        case .bottom:
            rawTangent = CGVector(dx: 1, dy: 0)
            availableSpan = max(2, rect.width - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = NSPoint(
                x: min(max(anchor.x, rect.minX + inset + half), rect.maxX - inset - half),
                y: rect.minY
            )
        case .left:
            rawTangent = CGVector(dx: 0, dy: -1)
            availableSpan = max(2, rect.height - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = NSPoint(
                x: rect.minX,
                y: min(max(anchor.y, rect.minY + inset + half), rect.maxY - inset - half)
            )
        case .right:
            rawTangent = CGVector(dx: 0, dy: 1)
            availableSpan = max(2, rect.height - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = NSPoint(
                x: rect.maxX,
                y: min(max(anchor.y, rect.minY + inset + half), rect.maxY - inset - half)
            )
        }

        let halfWidth = min(desiredWidth / 2, availableSpan / 2)

        return CalloutTailBase(
            center: center,
            start: NSPoint(x: center.x - rawTangent.dx * halfWidth, y: center.y - rawTangent.dy * halfWidth),
            end: NSPoint(x: center.x + rawTangent.dx * halfWidth, y: center.y + rawTangent.dy * halfWidth),
            tangent: rawTangent,
            halfWidth: halfWidth,
            side: side
        )
    }

    private func calloutTailSide(for anchor: NSPoint, tip: NSPoint, in rect: NSRect) -> CalloutTailSide {
        let distances: [(CalloutTailSide, CGFloat)] = [
            (.top, abs(anchor.y - rect.maxY)),
            (.right, abs(anchor.x - rect.maxX)),
            (.bottom, abs(anchor.y - rect.minY)),
            (.left, abs(anchor.x - rect.minX))
        ]
        let minDistance = distances.map(\.1).min() ?? 0
        let candidates = distances.filter { abs($0.1 - minDistance) < 0.5 }.map(\.0)
        guard candidates.count > 1 else {
            return candidates.first ?? .bottom
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let dx = tip.x - center.x
        let dy = tip.y - center.y
        if abs(dx) > abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .top : .bottom
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        if hasCallout {
            return calloutBackgroundPath().contains(p)
                || calloutBodyRect.insetBy(dx: -4, dy: -4).contains(p)
        }
        return hitBounds.contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        TextAnnotation(
            text: text,
            origin: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize,
            fontName: fontName,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            secondCalloutTip: secondCalloutTip.map {
                NSPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
        )
    }

    func translatedBodyPreservingCalloutTip(by delta: NSPoint) -> TextAnnotation {
        TextAnnotation(
            text: text,
            origin: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize,
            fontName: fontName,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: hasCalloutArrow ? calloutTip : calloutTip.map {
                NSPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            },
            secondCalloutTip: hasSecondCalloutArrow ? secondCalloutTip : secondCalloutTip.map {
                NSPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
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
            fontName: fontName,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip,
            secondCalloutTip: secondCalloutTip
        )
    }

    /// Returns a copy with the outline toggled on or off.
    func withStroke(_ hasStroke: Bool) -> TextAnnotation {
        var copy = self
        copy.hasStroke = hasStroke
        return copy
    }

    func withCallout(_ hasCallout: Bool) -> TextAnnotation {
        var copy = self
        copy.hasCallout = hasCallout
        return copy
    }

    func withCalloutTip(_ tip: NSPoint?) -> TextAnnotation {
        var copy = self
        copy.calloutTip = tip
        return copy
    }

    func withSecondCalloutTip(_ tip: NSPoint?) -> TextAnnotation {
        var copy = self
        copy.secondCalloutTip = tip
        return copy
    }

    /// Resize the text in place. The visual top-left stays anchored — fonts
    /// grow downward in canvas coords, so the origin shifts by the full text
    /// block height delta to keep the cap line steady.
    func withFontSize(_ fontSize: CGFloat) -> Annotation {
        let oldFont = TextAnnotation.font(named: fontName, size: self.fontSize)
        let newFont = TextAnnotation.font(named: fontName, size: fontSize)
        let oldHeight = TextAnnotation.editorSize(for: text, font: oldFont).height
        let newHeight = TextAnnotation.editorSize(for: text, font: newFont).height
        let newOrigin = NSPoint(x: origin.x, y: origin.y + (oldHeight - newHeight))
        return TextAnnotation(
            text: text,
            origin: newOrigin,
            color: color,
            fontSize: fontSize,
            fontName: fontName,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip,
            secondCalloutTip: secondCalloutTip
        )
    }

    /// Re-typeset in another family at the same point size. Like
    /// `withFontSize`, the visual cap line stays anchored: fonts grow downward
    /// in canvas coords, so the origin absorbs the line-height delta instead of
    /// letting the text jump when the face changes.
    func withFontName(_ fontName: String?) -> TextAnnotation {
        let oldFont = TextAnnotation.font(named: self.fontName, size: fontSize)
        let newFont = TextAnnotation.font(named: fontName, size: fontSize)
        let oldHeight = TextAnnotation.editorSize(for: text, font: oldFont).height
        let newHeight = TextAnnotation.editorSize(for: text, font: newFont).height
        let newOrigin = NSPoint(x: origin.x, y: origin.y + (oldHeight - newHeight))
        return TextAnnotation(
            text: text,
            origin: newOrigin,
            color: color,
            fontSize: fontSize,
            fontName: fontName,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip,
            secondCalloutTip: secondCalloutTip
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
    let size: CGFloat

    private static let baseRadius: CGFloat = 14
    private static let baseFontSize: CGFloat = 14

    init(
        center: NSPoint,
        tip: NSPoint? = nil,
        controlPoint: NSPoint? = nil,
        number: Int,
        color: NSColor,
        size: CGFloat = CGFloat(Defaults.numberSizeDefault)
    ) {
        self.center = center
        self.tip = tip
        self.controlPoint = controlPoint
        self.number = number
        self.color = color
        self.size = min(max(size, CGFloat(Defaults.numberSizeMin)), CGFloat(Defaults.numberSizeMax))
    }

    private var scale: CGFloat {
        size / CGFloat(Defaults.numberSizeDefault)
    }

    var radius: CGFloat { Self.baseRadius * scale }
    /// Below this distance from `center` we treat the tip as "no arrow" so
    /// the head won't sit on top of the badge glyph.
    var arrowMinDistance: CGFloat { radius + 6 * scale }

    static func arrowMinDistance(for size: CGFloat) -> CGFloat {
        let clamped = min(max(size, CGFloat(Defaults.numberSizeMin)), CGFloat(Defaults.numberSizeMax))
        let scale = clamped / CGFloat(Defaults.numberSizeDefault)
        return baseRadius * scale + 6 * scale
    }

    /// Black on light badges, white on dark — perceived-luminance threshold.
    static func contrastingTextColor(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var hasArrow: Bool {
        guard let tip else { return false }
        return hypot(tip.x - center.x, tip.y - center.y) >= arrowMinDistance
    }

    var circleRect: NSRect {
        NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
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
            let shaftWidth = NumberArrowShape.shaftWidth * scale
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
                let headLength = NumberArrowShape.headLength * scale
                let headWidth = NumberArrowShape.headWidth * scale
                let baseX = tip.x - unitX * headLength
                let baseY = tip.y - unitY * headLength

                // Shaft — stop at the arrowhead base so the round line cap
                // stays hidden inside the filled triangle.
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

                NumberArrowShape.drawHead(
                    tip: tip,
                    unitX: unitX,
                    unitY: unitY,
                    length: headLength,
                    width: headWidth,
                    strokeWidth: NumberArrowShape.headStrokeWidth * scale,
                    in: context
                )
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
            .font: NSFont.systemFont(ofSize: Self.baseFontSize * scale, weight: .bold)
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
        let r = radius
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
            return strokedPathContains(line, point: point, lineWidth: max(4, 4 * scale))
        }
        return false
    }

    func translated(by delta: NSPoint) -> Annotation {
        NumberAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            tip: tip.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            controlPoint: controlPoint.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            number: number,
            color: color,
            size: size
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
            color: color,
            size: size
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        NumberAnnotation(
            center: center,
            tip: tip,
            controlPoint: controlPoint,
            number: number,
            color: color,
            size: size
        )
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        NumberAnnotation(
            center: center,
            tip: tip,
            controlPoint: controlPoint,
            number: number,
            color: color,
            size: lineWidth
        )
    }
}
