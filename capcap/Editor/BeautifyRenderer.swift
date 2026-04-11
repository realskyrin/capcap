import AppKit
import CoreGraphics

enum BeautifyRenderer {
    // MARK: - Layout constants

    static let paddingRatio: CGFloat = 0.10
    static let paddingMin: CGFloat = 16
    static let paddingMax: CGFloat = 220
    static let innerCornerRadius: CGFloat = 12
    // Ambient shadow (uniform glow around all edges)
    static let ambientShadowBlur: CGFloat = 20
    static let ambientShadowOpacity: CGFloat = 0.22
    static let ambientShadowOffset: CGSize = CGSize(width: 0, height: 0)
    // Key shadow (slight downward bias for natural depth)
    static let keyShadowBlur: CGFloat = 30
    static let keyShadowOpacity: CGFloat = 0.25
    static let keyShadowOffset: CGSize = CGSize(width: 0, height: -5)

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

    // MARK: - Wallpaper

    /// Loads the desktop wallpaper image for the given screen.
    static func wallpaperImage(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    // MARK: - Drawing primitives

    /// Draws a linear gradient across `outerRect` using the preset colors and angle.
    /// For wallpaper presets the area is left clear (caller draws wallpaper separately).
    static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset) {
        if preset.isWallpaper { return }
        guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
            preset.startColor.setFill()
            outerRect.fill()
            return
        }
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    }

    /// Draws a wallpaper image as background, aspect-fill centered in `outerRect`.
    static func drawWallpaperBackground(in outerRect: CGRect, wallpaper: NSImage) {
        let wpSize = wallpaper.size
        guard wpSize.width > 0, wpSize.height > 0 else { return }
        let scaleX = outerRect.width / wpSize.width
        let scaleY = outerRect.height / wpSize.height
        let scale = max(scaleX, scaleY)
        let drawSize = CGSize(width: wpSize.width * scale, height: wpSize.height * scale)
        let drawRect = CGRect(
            x: outerRect.origin.x + (outerRect.width - drawSize.width) / 2,
            y: outerRect.origin.y + (outerRect.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        wallpaper.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    /// Draws a two-layer shadow (ambient + key light) cast by a rounded-rect
    /// silhouette at `innerRect`, creating a natural floating-card effect.
    /// The fills under the shadows are opaque black, so callers should draw
    /// the actual image content on top afterwards (clipped to the same rounded rect).
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        let path = CGPath(
            roundedRect: innerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // Pass 1: ambient shadow — uniform glow around all edges
        context.saveGState()
        context.setShadow(
            offset: ambientShadowOffset,
            blur: ambientShadowBlur,
            color: NSColor.black.withAlphaComponent(ambientShadowOpacity).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        // Pass 2: key shadow — slight downward offset for natural depth
        context.saveGState()
        context.setShadow(
            offset: keyShadowOffset,
            blur: keyShadowBlur,
            color: NSColor.black.withAlphaComponent(keyShadowOpacity).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Full composite

    /// Measures the inner image's pixel density (pixels per point).
    private static func pixelScale(of innerImage: NSImage) -> CGFloat {
        let pointWidth = innerImage.size.width
        guard pointWidth > 0 else { return 1 }
        let maxPixelsWide = innerImage.representations
            .map(\.pixelsWide)
            .filter { $0 > 0 }
            .max() ?? 0
        guard maxPixelsWide > 0 else { return 1 }
        return max(CGFloat(maxPixelsWide) / pointWidth, 1)
    }

    /// Returns a new NSImage containing `innerImage` wrapped in the beautified frame.
    static func render(innerImage: NSImage, preset: BeautifyPreset) -> NSImage {
        return render(
            innerImage: innerImage,
            preset: preset,
            padding: padding(for: innerImage.size),
            wallpaperImage: nil
        )
    }

    /// Variant of `render` that uses an explicit padding value (in points)
    /// instead of running the auto-ratio `padding(for:)`. Used by the
    /// beautify editor when the user drives padding from the sub-toolbar slider.
    static func render(
        innerImage: NSImage,
        preset: BeautifyPreset,
        padding: CGFloat,
        wallpaperImage: NSImage? = nil
    ) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        let outer = outputSize(innerSize: innerSize, padding: padding)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(innerSize: innerSize, padding: padding)

        // Preserve backing scale by mirroring the inner image's pixel density.
        let innerPixelScale = pixelScale(of: innerImage)
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

        // 1. Background
        if preset.isWallpaper, let wp = wallpaperImage {
            drawWallpaperBackground(in: outerRect, wallpaper: wp)
        } else {
            drawBackground(in: outerRect, preset: preset)
        }

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
