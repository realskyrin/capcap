import AppKit

enum ImageEditLauncher {
    /// Hands the supplied image file off to the editor in image-edit mode.
    /// Returns false if the file could not be loaded; the caller should then
    /// fall back to the normal screenshot flow. The source file is copied
    /// into a per-app temp directory before loading so the editor is never
    /// reading directly from the user's library.
    static func launch(
        sourceURL: URL,
        onRequestFocusReturn: (() -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        guard let copyURL = copyToTemp(sourceURL),
              let data = try? Data(contentsOf: copyURL),
              let original = NSImage.imagePreservingPixelDimensions(from: data),
              original.size.width > 0, original.size.height > 0
        else { return nil }

        return present(
            original,
            source: .finder,
            onRequestFocusReturn: onRequestFocusReturn,
            onComplete: onComplete
        )
    }

    /// Hands a clipboard image off to the editor in image-edit mode. Returns
    /// nil for an empty or zero-size image so the caller can fall back to the
    /// normal screenshot flow.
    static func launch(
        clipboardImage image: NSImage,
        onRequestFocusReturn: (() -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return present(
            image,
            source: .clipboard,
            onRequestFocusReturn: onRequestFocusReturn,
            onComplete: onComplete
        )
    }

    /// Hands an in-memory generated image off to the existing editor. Used by
    /// workflows such as Image Merge where the source image is not a file or
    /// the live clipboard.
    static func launch(
        generatedImage image: NSImage,
        source: OverlayWindowController.PresetSource = .merge,
        keepsEditorAcrossSpaces: Bool = false,
        onRequestFocusReturn: (() -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return present(
            image,
            source: source,
            keepsEditorAcrossSpaces: keepsEditorAcrossSpaces,
            onRequestFocusReturn: onRequestFocusReturn,
            onComplete: onComplete
        )
    }

    private static func present(
        _ image: NSImage,
        source: OverlayWindowController.PresetSource,
        keepsEditorAcrossSpaces: Bool = false,
        onRequestFocusReturn: (() -> Void)?,
        onComplete: @escaping (NSImage?) -> Void
    ) -> OverlayWindowController? {
        let controller = OverlayWindowController(
            presetImage: image,
            presetSource: source,
            keepsEditorAcrossSpaces: keepsEditorAcrossSpaces,
            onRequestFocusReturn: onRequestFocusReturn,
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

}
