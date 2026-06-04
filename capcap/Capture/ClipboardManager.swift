import AppKit

struct ClipboardManager {
    static func copyToClipboard(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let pngData = image.pngDataPreservingBacking() {
            pasteboard.setData(pngData, forType: .png)
        }

        if let tiffData = image.tiffDataPreservingBacking() {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    static func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
