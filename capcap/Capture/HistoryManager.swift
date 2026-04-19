import AppKit

struct HistoryEntry {
    let fileURL: URL
    let createdAt: Date
}

final class HistoryManager {
    static let shared = HistoryManager()

    private let queue = DispatchQueue(label: "capcap.history", qos: .utility)
    private let directoryURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directoryURL = base.appendingPathComponent("capcap/History", isDirectory: true)
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(limitChanged),
            name: .historyCacheLimitDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func limitChanged() {
        queue.async { [weak self] in
            self?.pruneToLimit()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func add(image: NSImage) {
        guard let data = image.pngDataPreservingBacking() else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let name = Self.filenameFormatter.string(from: Date()) + ".png"
            let url = self.directoryURL.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }
            self.pruneToLimit()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func entries() -> [HistoryEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let items: [HistoryEntry] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "png" else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return HistoryEntry(fileURL: url, createdAt: date)
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func image(for entry: HistoryEntry) -> NSImage? {
        NSImage(contentsOf: entry.fileURL)
    }

    func clearAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            for entry in self.entries() {
                try? fm.removeItem(at: entry.fileURL)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    private func pruneToLimit() {
        let limit = Defaults.historyCacheLimit
        let all = entries()
        guard all.count > limit else { return }
        let fm = FileManager.default
        for extra in all.dropFirst(limit) {
            try? fm.removeItem(at: extra.fileURL)
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
