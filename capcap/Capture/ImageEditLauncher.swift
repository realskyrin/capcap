import AppKit

enum ImageEditLauncher {
    /// Hands the supplied image file off to the editor in image-edit mode.
    /// Returns false if the file could not be loaded; the caller should then
    /// fall back to the normal screenshot flow. The source file is copied
    /// into a per-app temp directory before loading so the editor is never
    /// reading directly from the user's library.
    static func launch(
        sourceURL: URL,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        guard let copyURL = copyToTemp(sourceURL),
              let original = NSImage(contentsOf: copyURL),
              original.size.width > 0, original.size.height > 0
        else { return nil }

        return present(original, source: .finder, onComplete: onComplete)
    }

    /// Hands a clipboard image off to the editor in image-edit mode. Returns
    /// nil for an empty or zero-size image so the caller can fall back to the
    /// normal screenshot flow.
    static func launch(
        clipboardImage image: NSImage,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return present(image, source: .clipboard, onComplete: onComplete)
    }

    private static func present(
        _ image: NSImage,
        source: OverlayWindowController.PresetSource,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        let screen = activeScreen()
        let displayImage = fitForDisplay(image, on: screen)

        let controller = OverlayWindowController(
            presetImage: displayImage,
            presetSource: source,
            onComplete: onComplete
        )
        controller.activate()
        return controller
    }

    /// Wipe the per-session temp dir so we don't leave decoded copies behind
    /// across launches.
    static func clearTempDir() {
        let dir = tempDir()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("capcap-edit", isDirectory: true)
    }

    private static func copyToTemp(_ source: URL) -> URL? {
        let dir = tempDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Use a UUID prefix so multiple opens of the same filename don't collide.
        let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            NSLog("capcap: failed to copy image to temp: \(error)")
            return nil
        }
    }

    private static func activeScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Returns an NSImage sized to fit within the screen with margins. If the
    /// source already fits, returns it unchanged. Otherwise resamples to the
    /// fit size — keeping canvas bounds == base image size so annotations and
    /// composites stay in alignment.
    private static func fitForDisplay(_ image: NSImage, on screen: NSScreen) -> NSImage {
        let frame = screen.visibleFrame
        let horizontalMargin: CGFloat = 60
        let verticalMargin: CGFloat = 120 // leave room for toolbar above/below
        let maxWidth = max(200, frame.width - horizontalMargin * 2)
        let maxHeight = max(200, frame.height - verticalMargin * 2)

        let size = image.size
        let widthRatio = maxWidth / size.width
        let heightRatio = maxHeight / size.height
        let ratio = min(1.0, min(widthRatio, heightRatio))
        if ratio >= 1.0 { return image }

        let target = NSSize(
            width: floor(size.width * ratio),
            height: floor(size.height * ratio)
        )
        return resample(image, to: target)
    }

    private static func resample(_ image: NSImage, to size: NSSize) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelW = Int(size.width * scale)
        let pixelH = Int(size.height * scale)
        guard pixelW > 0, pixelH > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelW,
                pixelsHigh: pixelH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )
        else { return image }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}
