import AppKit
import UniformTypeIdentifiers

enum ImageMergeTemplate: Int, CaseIterable {
    case horizontal
    case vertical
    case grid
    case longStitch

    var title: String {
        switch self {
        case .horizontal: return L10n.imageMergeTemplateHorizontal
        case .vertical: return L10n.imageMergeTemplateVertical
        case .grid: return L10n.imageMergeTemplateGrid
        case .longStitch: return L10n.imageMergeTemplateLongStitch
        }
    }
}

enum ImageMergeBackground {
    case transparent
    case solid(NSColor)
}

struct ImageMergeItem {
    let id: UUID
    let displayName: String
    let image: NSImage
    let originalSize: NSSize
    var offset: NSPoint
    var scale: CGFloat

    init(displayName: String, image: NSImage) {
        id = UUID()
        self.displayName = displayName
        self.image = image
        originalSize = image.size
        offset = .zero
        scale = 1.0
    }
}

final class ImageMergeDocument {
    var items: [ImageMergeItem]
    var template: ImageMergeTemplate {
        didSet {
            if oldValue != template {
                resetAdjustments()
            }
        }
    }
    var spacing: CGFloat
    var margin: CGFloat
    var background: ImageMergeBackground
    var cornerRadius: CGFloat
    var selectedItemID: UUID?

    init(items: [ImageMergeItem] = []) {
        self.items = items
        template = .horizontal
        spacing = 12
        margin = 24
        background = .transparent
        cornerRadius = 0
        selectedItemID = items.first?.id
    }

    var canOutput: Bool {
        items.count >= 2
    }

    func append(_ newItems: [ImageMergeItem]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        if selectedItemID == nil {
            selectedItemID = newItems.first?.id
        }
    }

    func removeInvalidSelectionIfNeeded() {
        guard let selectedItemID else { return }
        if !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = items.first?.id
        }
    }

    func resetAdjustments() {
        for index in items.indices {
            items[index].offset = .zero
            items[index].scale = 1.0
        }
    }

    func select(_ id: UUID?) {
        selectedItemID = id
    }

    func updateAdjustment(for id: UUID, offset: NSPoint? = nil, scale: CGFloat? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let offset {
            items[index].offset = offset
        }
        if let scale {
            items[index].scale = min(max(scale, 0.2), 4.0)
        }
    }

    func reorderItem(from sourceIndex: Int, to targetIndex: Int) {
        guard sourceIndex != targetIndex,
              items.indices.contains(sourceIndex),
              items.indices.contains(targetIndex)
        else { return }
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: targetIndex)
    }

    static func loadItems(from urls: [URL]) -> (items: [ImageMergeItem], failedCount: Int) {
        var loaded: [ImageMergeItem] = []
        var failed = 0

        for url in urls {
            guard isImageFile(url),
                  let data = try? Data(contentsOf: url),
                  let image = image(from: data)
            else {
                failed += 1
                continue
            }
            loaded.append(ImageMergeItem(displayName: url.lastPathComponent, image: image))
        }

        return (loaded, failed)
    }

    static func item(fromClipboardImage image: NSImage) -> ImageMergeItem? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return ImageMergeItem(displayName: L10n.imageMergeClipboardSourceName, image: normalizedImage(image) ?? image)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType else { return false }
        return type.conforms(to: .image)
    }

    private static func image(from data: Data) -> NSImage? {
        if let rep = NSBitmapImageRep(data: data) {
            let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            guard size.width > 0, size.height > 0 else { return nil }
            rep.size = size
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }

        guard let source = NSImage(data: data) else { return nil }
        return normalizedImage(source)
    }

    private static func normalizedImage(_ source: NSImage) -> NSImage? {
        guard let cgImage = source.cgImagePreservingBacking() else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        guard size.width > 0, size.height > 0 else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
