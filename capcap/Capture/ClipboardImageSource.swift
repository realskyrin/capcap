import AppKit
import UniformTypeIdentifiers

/// Pulls an editable image out of the system clipboard. Acts as the second
/// source for the image-edit shortcut, alongside `FinderSelection`.
enum ClipboardImageSource {
    /// Returns an image when the clipboard holds one — either raw bitmap data
    /// (a copied screenshot, an image dragged from a browser, etc.) or a
    /// single copied image file. Returns nil when the clipboard has no image,
    /// so the caller can fall through to the normal screenshot flow.
    static func currentImage() -> NSImage? {
        let pasteboard = NSPasteboard.general

        // Raw bitmap data takes priority: a copied screenshot or web image.
        // Decode through NSBitmapImageRep so the editor canvas works at the
        // image's true pixel resolution rather than DPI-scaled points.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let rep = NSBitmapImageRep(data: data) {
                return image(from: rep)
            }
        }

        // A copied image file (e.g. ⌘C on a file in Finder) lands on the
        // clipboard as a file URL — load and decode it the same way.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           urls.count == 1,
           isImage(urls[0]),
           let data = try? Data(contentsOf: urls[0]),
           let rep = NSBitmapImageRep(data: data) {
            return image(from: rep)
        }

        return nil
    }

    /// Empties the clipboard. Used after the image-edit shortcut fires by
    /// mistake, so the next screenshot trigger runs the normal flow instead of
    /// re-opening the same clipboard image.
    static func clear() {
        NSPasteboard.general.clearContents()
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

    private static func isImage(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType else { return false }
        return type.conforms(to: .image)
    }
}
