import AppKit
import CoreGraphics
import ImageIO

enum BeautifyRenderer {
    // MARK: - Layout constants

    static let paddingRatio: CGFloat = 0.10
    static let paddingMin: CGFloat = 16
    static let paddingMax: CGFloat = 220
    static let innerCornerRadius: CGFloat = 12
    // Ambient shadow (uniform glow around all edges)
    static let ambientShadowBlur: CGFloat = 24
    static let ambientShadowOpacity: CGFloat = 0.30
    static let ambientShadowOffset: CGSize = CGSize(width: 0, height: 0)
    // Key shadow (slight downward bias for natural depth)
    static let keyShadowBlur: CGFloat = 38
    static let keyShadowOpacity: CGFloat = 0.36
    static let keyShadowOffset: CGSize = CGSize(width: 0, height: -7)
    /// Window captures already carry the real system corner alpha. Their
    /// beautify shadow only needs to start slightly inside that edge so the
    /// light background does not peek through corner mismatches.
    static let windowInnerShadowInset: CGFloat = 5

    // MARK: - Slider bounds (user-controlled padding)
    static let paddingSliderMin: CGFloat = 0
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

    /// Longest-edge pixel cap for the cached wallpaper bitmap. The raw desktop
    /// image is often a multi-frame "dynamic" HEIC well over 100 MB; that only
    /// ever fills the thin padding band, so a 2560 px copy is plenty.
    private static let wallpaperMaxEdge: CGFloat = 2560

    /// Decoded + downscaled wallpaper bitmaps, keyed by source file path.
    private static var wallpaperCache: [String: NSImage] = [:]
    private static var wallpaperLoadCallbacks: [String: [(NSImage?) -> Void]] = [:]
    private static let wallpaperCacheLock = NSLock()
    private static let wallpaperDecodeQueue = DispatchQueue(
        label: "capcap.beautify.wallpaper.decode",
        qos: .userInitiated
    )

    /// Loads the desktop wallpaper image for the given screen.
    ///
    /// The desktop image returned by `desktopImageURL` can be a dynamic HEIC
    /// containing many full-resolution frames. Decoding that synchronously —
    /// and re-decoding it on every swatch/preview redraw, since nothing was
    /// cached — froze the editor for several seconds on machines using the
    /// default macOS dynamic wallpaper. We instead decode a single downscaled
    /// thumbnail once (ImageIO never expands the full-size image) and cache it.
    static func wallpaperImage(for screen: NSScreen) -> NSImage? {
        DiagnosticLog.log(
            "beautify.wallpaper",
            "request.begin",
            metadata: [
                "screen": screen.localizedName,
                "screenFrame": diagnosticString(screen.frame),
                "screenScale": screen.backingScaleFactor,
            ]
        )
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            DiagnosticLog.log("beautify.wallpaper", "request.noDesktopImageURL")
            return nil
        }
        return cachedOrLoadWallpaper(url: url)
    }

    /// Asynchronously loads the desktop wallpaper image for the given screen.
    /// Completion is always delivered on the main queue.
    static func loadWallpaperImage(for screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        DiagnosticLog.log(
            "beautify.wallpaper",
            "request.async.begin",
            metadata: [
                "screen": screen.localizedName,
                "screenFrame": diagnosticString(screen.frame),
                "screenScale": screen.backingScaleFactor,
            ]
        )
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            DiagnosticLog.log("beautify.wallpaper", "request.async.noDesktopImageURL")
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        if let cached = cachedWallpaper(url: url) {
            DiagnosticLog.log(
                "beautify.wallpaper",
                "cache.hit",
                metadata: ["url": url.path, "image": diagnosticString(cached)]
            )
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        let key = url.path
        wallpaperCacheLock.lock()
        if var callbacks = wallpaperLoadCallbacks[key] {
            callbacks.append(completion)
            wallpaperLoadCallbacks[key] = callbacks
            wallpaperCacheLock.unlock()
            DiagnosticLog.log(
                "beautify.wallpaper",
                "load.coalesced",
                metadata: ["url": url.path, "pendingCallbacks": callbacks.count]
            )
            return
        }
        wallpaperLoadCallbacks[key] = [completion]
        wallpaperCacheLock.unlock()

        DiagnosticLog.log(
            "beautify.wallpaper",
            "cache.miss",
            metadata: ["url": url.path, "fileSize": fileSizeString(url)]
        )

        wallpaperDecodeQueue.async {
            let image = autoreleasepool {
                downscaledWallpaper(url: url)
            }
            if let image {
                storeWallpaper(image, url: url)
            }

            wallpaperCacheLock.lock()
            let callbacks = wallpaperLoadCallbacks.removeValue(forKey: key) ?? []
            wallpaperCacheLock.unlock()

            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    private static func cachedOrLoadWallpaper(url: URL) -> NSImage? {
        if let cached = cachedWallpaper(url: url) {
            DiagnosticLog.log(
                "beautify.wallpaper",
                "cache.hit",
                metadata: ["url": url.path, "image": diagnosticString(cached)]
            )
            return cached
        }

        DiagnosticLog.log(
            "beautify.wallpaper",
            "cache.miss",
            metadata: ["url": url.path, "fileSize": fileSizeString(url)]
        )
        guard let image = downscaledWallpaper(url: url) else { return nil }
        storeWallpaper(image, url: url)
        return image
    }

    private static func cachedWallpaper(url: URL) -> NSImage? {
        let key = url.path
        wallpaperCacheLock.lock()
        let cached = wallpaperCache[key]
        wallpaperCacheLock.unlock()
        return cached
    }

    private static func storeWallpaper(_ image: NSImage, url: URL) {
        wallpaperCacheLock.lock()
        wallpaperCache[url.path] = image
        wallpaperCacheLock.unlock()
        DiagnosticLog.log(
            "beautify.wallpaper",
            "cache.store",
            metadata: ["url": url.path, "image": diagnosticString(image)]
        )
    }

    /// Decodes only the primary frame of `url`, downscaled so the longest edge
    /// is at most `wallpaperMaxEdge`. `CGImageSourceCreateThumbnailAtIndex`
    /// performs the scaling inside ImageIO, so a 100 MB+ dynamic wallpaper is
    /// never fully decoded into memory.
    private static func downscaledWallpaper(url: URL) -> NSImage? {
        DiagnosticLog.log(
            "beautify.wallpaper",
            "source.create.begin",
            metadata: ["url": url.path, "fileSize": fileSizeString(url)]
        )
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            DiagnosticLog.log("beautify.wallpaper", "source.create.failed", metadata: ["url": url.path])
            return NSImage(contentsOf: url)
        }
        DiagnosticLog.log(
            "beautify.wallpaper",
            "source.create.end",
            metadata: ["url": url.path]
        )
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let imageCount = CGImageSourceGetCount(source)
        DiagnosticLog.log(
            "beautify.wallpaper",
            "thumbnail.create.begin",
            metadata: [
                "url": url.path,
                "primaryIndex": index,
                "imageCount": imageCount,
                "maxPixelSize": wallpaperMaxEdge,
            ]
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: wallpaperMaxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            DiagnosticLog.log("beautify.wallpaper", "thumbnail.create.failed", metadata: ["url": url.path])
            return NSImage(contentsOf: url)
        }
        DiagnosticLog.log(
            "beautify.wallpaper",
            "thumbnail.create.end",
            metadata: ["url": url.path, "pixels": "\(cg.width)x\(cg.height)"]
        )
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
    /// The fill used to cast the shadow is clipped out, so transparent pixels
    /// in the screenshot reveal the beautify background instead of a black
    /// backing rectangle.
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        drawInnerShadow(
            innerRect: innerRect,
            cornerRadius: cornerRadius,
            inset: 0,
            context: context
        )
    }

    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, inset: CGFloat, context: CGContext) {
        let shadowRect = innerRect.insetBy(dx: inset, dy: inset)
        guard shadowRect.width > 0, shadowRect.height > 0 else { return }
        let radius = max(0, cornerRadius - inset)
        let path = CGPath(
            roundedRect: shadowRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // Pass 1: ambient shadow — uniform glow around all edges
        drawShadowOnly(
            path: path,
            innerRect: shadowRect,
            offset: ambientShadowOffset,
            blur: ambientShadowBlur,
            opacity: ambientShadowOpacity,
            context: context
        )

        // Pass 2: key shadow — slight downward offset for natural depth
        drawShadowOnly(
            path: path,
            innerRect: shadowRect,
            offset: keyShadowOffset,
            blur: keyShadowBlur,
            opacity: keyShadowOpacity,
            context: context
        )
    }

    private static func drawShadowOnly(
        path: CGPath,
        innerRect: CGRect,
        offset: CGSize,
        blur: CGFloat,
        opacity: CGFloat,
        context: CGContext
    ) {
        let shadowOutset = shadowOutset(blur: blur, offset: offset)
        let clipRect = innerRect.insetBy(dx: -shadowOutset, dy: -shadowOutset)

        context.saveGState()
        context.addRect(clipRect)
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: offset,
            blur: blur,
            color: NSColor.black.withAlphaComponent(opacity).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static func shadowOutset(blur: CGFloat, offset: CGSize) -> CGFloat {
        blur * 3 + max(abs(offset.width), abs(offset.height)) + 2
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
        wallpaperImage: NSImage? = nil,
        shadowEnabled: Bool = true,
        innerClipRadius: CGFloat? = BeautifyRenderer.innerCornerRadius,
        innerShadowCornerRadius: CGFloat = BeautifyRenderer.innerCornerRadius,
        innerShadowInset: CGFloat = 0
    ) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }
        DiagnosticLog.log(
            "beautify.render",
            "begin",
            metadata: [
                "preset": preset.id,
                "innerImage": diagnosticString(innerImage),
                "padding": String(format: "%.2f", padding),
                "shadowEnabled": shadowEnabled,
                "innerClipRadius": innerClipRadius.map { String(format: "%.2f", $0) } ?? "nil",
                "innerShadowCornerRadius": String(format: "%.2f", innerShadowCornerRadius),
                "innerShadowInset": String(format: "%.2f", innerShadowInset),
            ]
        )

        let outer = outputSize(innerSize: innerSize, padding: padding)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(innerSize: innerSize, padding: padding)

        // Preserve backing scale by mirroring the inner image's pixel density.
        let innerPixelScale = pixelScale(of: innerImage)
        let pixelsWide = Int((outer.width * innerPixelScale).rounded())
        let pixelsHigh = Int((outer.height * innerPixelScale).rounded())
        DiagnosticLog.log(
            "beautify.render",
            "bitmap.allocate.begin",
            metadata: [
                "outerSize": diagnosticString(CGRect(origin: .zero, size: outer)),
                "pixelScale": String(format: "%.2f", innerPixelScale),
                "pixels": "\(pixelsWide)x\(pixelsHigh)",
            ]
        )

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
            DiagnosticLog.log("beautify.render", "bitmap.allocate.failed")
            return innerImage
        }
        rep.size = outer

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            DiagnosticLog.log("beautify.render", "graphicsContext.failed")
            return innerImage
        }
        DiagnosticLog.log("beautify.render", "bitmap.allocate.end")

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
        if shadowEnabled {
            drawInnerShadow(
                innerRect: inner,
                cornerRadius: innerShadowCornerRadius,
                inset: innerShadowInset,
                context: cg
            )
        }

        // 3. Draw the image. Normal selections use the beautify card's fixed
        // rounded clip; clicked-window captures pass nil here because their
        // base image is already cut to the window's own alpha/rounded shape.
        if let innerClipRadius {
            cg.saveGState()
            let clipPath = CGPath(
                roundedRect: inner,
                cornerWidth: innerClipRadius,
                cornerHeight: innerClipRadius,
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
        } else {
            innerImage.draw(
                in: inner,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        DiagnosticLog.log(
            "beautify.render",
            "end",
            metadata: ["result": diagnosticString(image)]
        )
        return image
    }

    private static func diagnosticString(_ rect: CGRect) -> String {
        "x:\(String(format: "%.1f", rect.origin.x)),y:\(String(format: "%.1f", rect.origin.y)),w:\(String(format: "%.1f", rect.width)),h:\(String(format: "%.1f", rect.height))"
    }

    private static func diagnosticString(_ image: NSImage) -> String {
        let reps = image.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ",")
        return "points=\(String(format: "%.1f", image.size.width))x\(String(format: "%.1f", image.size.height));reps=\(reps)"
    }

    private static func fileSizeString(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values?.fileSize else { return "unknown" }
        return "\(bytes)"
    }
}
