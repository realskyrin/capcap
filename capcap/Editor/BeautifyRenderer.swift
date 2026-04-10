import AppKit
import CoreGraphics

enum BeautifyRenderer {
    // MARK: - Layout constants

    static let paddingRatio: CGFloat = 0.10
    static let paddingMin: CGFloat = 16
    static let paddingMax: CGFloat = 220
    static let innerCornerRadius: CGFloat = 12
    static let shadowBlur: CGFloat = 18
    static let shadowOpacity: CGFloat = 0.18
    static let shadowOffset: CGSize = CGSize(width: 0, height: -6)

    // MARK: - Slider bounds (user-controlled padding)
    static let paddingSliderMin: CGFloat = 8
    static let paddingSliderMax: CGFloat = 56
    static let paddingSliderDefault: CGFloat = 24

    // MARK: - Geometry

    static func padding(for innerSize: CGSize) -> CGFloat {
        let shortEdge = min(innerSize.width, innerSize.height)
        guard shortEdge > 0 else { return paddingMin }
        let base = shortEdge * paddingRatio
        return max(paddingMin, min(paddingMax, base))
    }

    static func outputSize(for innerSize: CGSize) -> CGSize {
        let p = padding(for: innerSize)
        return CGSize(width: innerSize.width + 2 * p, height: innerSize.height + 2 * p)
    }

    static func innerRect(for innerSize: CGSize) -> CGRect {
        let p = padding(for: innerSize)
        return CGRect(x: p, y: p, width: innerSize.width, height: innerSize.height)
    }

    static func outputSize(innerSize: CGSize, padding: CGFloat) -> CGSize {
        return CGSize(
            width: innerSize.width + 2 * padding,
            height: innerSize.height + 2 * padding
        )
    }

    static func innerRect(innerSize: CGSize, padding: CGFloat) -> CGRect {
        return CGRect(x: padding, y: padding, width: innerSize.width, height: innerSize.height)
    }

    // MARK: - Drawing primitives

    /// Draws a linear gradient across `outerRect` using the preset colors and angle.
    /// Caller must ensure `NSGraphicsContext.current` is set.
    static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset) {
        guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
            preset.startColor.setFill()
            outerRect.fill()
            return
        }
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    }

    /// Draws a shadow cast by a rounded-rect silhouette at `innerRect`. The fill
    /// under the shadow is opaque black, so callers should draw the actual image
    /// content on top afterwards (clipped to the same rounded rect).
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        context.saveGState()
        let shadowColor = NSColor.black.withAlphaComponent(shadowOpacity).cgColor
        context.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
        let path = CGPath(
            roundedRect: innerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Full composite

    /// Returns a new NSImage containing `innerImage` wrapped in the beautified frame.
    static func render(innerImage: NSImage, preset: BeautifyPreset) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        let outer = outputSize(for: innerSize)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(for: innerSize)

        // Preserve backing scale by mirroring the inner image's pixel density.
        let innerPixelScale: CGFloat
        if let rep = innerImage.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.size.width > 0 {
            innerPixelScale = CGFloat(rep.pixelsWide) / rep.size.width
        } else {
            innerPixelScale = 1
        }
        let pixelsWide = Int((outer.width * innerPixelScale).rounded())
        let pixelsHigh = Int((outer.height * innerPixelScale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            return innerImage
        }
        rep.size = outer

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return innerImage }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let cg = ctx.cgContext

        // 1. Gradient background across full outer area
        drawBackground(in: outerRect, preset: preset)

        // 2. Soft shadow under the inner rounded rect
        drawInnerShadow(innerRect: inner, cornerRadius: innerCornerRadius, context: cg)

        // 3. Clip to the inner rounded rect and draw the image
        cg.saveGState()
        let clipPath = CGPath(
            roundedRect: inner,
            cornerWidth: innerCornerRadius,
            cornerHeight: innerCornerRadius,
            transform: nil
        )
        cg.addPath(clipPath)
        cg.clip()
        innerImage.draw(
            in: inner,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        return image
    }

    /// Variant of `render` that uses an explicit padding value (in points)
    /// instead of running the auto-ratio `padding(for:)`. Used by the
    /// beautify editor when the user drives padding from the sub-toolbar slider.
    static func render(innerImage: NSImage, preset: BeautifyPreset, padding: CGFloat) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        let outer = outputSize(innerSize: innerSize, padding: padding)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(innerSize: innerSize, padding: padding)

        // Preserve backing scale by mirroring the inner image's pixel density.
        let innerPixelScale: CGFloat
        if let rep = innerImage.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.size.width > 0 {
            innerPixelScale = CGFloat(rep.pixelsWide) / rep.size.width
        } else {
            innerPixelScale = 1
        }
        let pixelsWide = Int((outer.width * innerPixelScale).rounded())
        let pixelsHigh = Int((outer.height * innerPixelScale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            return innerImage
        }
        rep.size = outer

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return innerImage }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let cg = ctx.cgContext

        // 1. Gradient background across full outer area
        drawBackground(in: outerRect, preset: preset)

        // 2. Soft shadow under the inner rounded rect
        drawInnerShadow(innerRect: inner, cornerRadius: innerCornerRadius, context: cg)

        // 3. Clip to the inner rounded rect and draw the image
        cg.saveGState()
        let clipPath = CGPath(
            roundedRect: inner,
            cornerWidth: innerCornerRadius,
            cornerHeight: innerCornerRadius,
            transform: nil
        )
        cg.addPath(clipPath)
        cg.clip()
        innerImage.draw(
            in: inner,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        return image
    }
}
