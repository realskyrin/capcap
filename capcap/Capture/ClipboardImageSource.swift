import AppKit
import UniformTypeIdentifiers

/// Pulls an editable image out of the system clipboard for explicit edit and
/// pin shortcuts.
enum ClipboardImageSource {
    /// Returns an image when the clipboard holds one — either raw bitmap data
    /// (a copied screenshot, an image dragged from a browser, etc.) or a
    /// single copied image file. Returns nil when the clipboard has no image.
    static func currentImage() -> NSImage? {
        let pasteboard = NSPasteboard.general

        let imageFileURLs = currentImageFileURLs()

        // A copied image file (e.g. ⌘C on a file in Finder) takes priority.
        // Finder puts the file's *icon* on the clipboard as TIFF data too, so
        // the raw-bitmap path below would decode that generic document icon
        // instead of the real image. Load from the file URL first.
        if imageFileURLs.count == 1,
           let data = try? Data(contentsOf: imageFileURLs[0]) {
            return image(from: data)
        }

        if !imageFileURLs.isEmpty {
            return nil
        }

        // Otherwise fall back to raw bitmap data: a copied screenshot or web
        // image. Decode through NSBitmapImageRep so the editor canvas works at
        // the image's true pixel resolution rather than DPI-scaled points.
        for type in bitmapPasteboardTypes {
            if let data = pasteboard.data(forType: type),
               let image = image(from: data) {
                return image
            }
        }

        return nil
    }

    /// Empties the clipboard. Used by pin mode so the same source is not
    /// re-pinned.
    static func clear() {
        NSPasteboard.general.clearContents()
    }

    /// Returns all copied image file URLs on the clipboard, preserving the
    /// pasteboard order. This lets multi-image workflows import Finder copies.
    static func currentImageFileURLs() -> [URL] {
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls.filter(isImage)
    }

    /// Wraps a decoded bitmap in an NSImage sized to its pixel dimensions, so
    /// the editor canvas bounds match the image's full resolution.
    private static func image(from rep: NSBitmapImageRep) -> NSImage? {
        let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        rep.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(rep)
        return image
    }

    private static func image(from data: Data) -> NSImage? {
        if let rep = NSBitmapImageRep(data: data) {
            return image(from: rep)
        }

        guard let source = NSImage(data: data),
              let cgImage = source.cgImagePreservingBacking()
        else {
            return nil
        }

        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(rep)
        return image
    }

    private static let bitmapPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
    ]

    private static func isImage(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType else { return false }
        return type.conforms(to: .image)
    }
}
