import AppKit

enum HistoryEntryKind {
    case image
    case color(hex: String)
}

struct HistoryEntry {
    let fileURL: URL
    let createdAt: Date
    let kind: HistoryEntryKind
    let cloudURL: URL?
}

private let cloudURLXattrKey = "com.capcap.cloudURL"

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cacheEnabledChanged),
            name: .historyCacheEnabledDidChange,
            object: nil
        )

        if !Defaults.historyCacheEnabled {
            removeAllEntries()
        }
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

    @objc private func cacheEnabledChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            if !Defaults.historyCacheEnabled {
                self.removeAllEntries()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func add(image: NSImage, cloudURL: URL? = nil) {
        guard Defaults.historyCacheEnabled else { return }
        guard let data = image.pngDataPreservingBacking() else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            guard Defaults.historyCacheEnabled else { return }
            let name = Self.filenameFormatter.string(from: Date()) + ".png"
            let url = self.directoryURL.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return
            }
            if let cloudURL = cloudURL {
                Self.writeCloudURLXattr(cloudURL, on: url)
            }
            self.pruneToLimit()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func addColor(hex: String) {
        guard Defaults.historyCacheEnabled else { return }
        let normalized = hex.uppercased()
        queue.async { [weak self] in
            guard let self = self else { return }
            guard Defaults.historyCacheEnabled else { return }
            let name = Self.filenameFormatter.string(from: Date()) + ".color"
            let url = self.directoryURL.appendingPathComponent(name)
            do {
                try normalized.write(to: url, atomically: true, encoding: .utf8)
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
        guard Defaults.historyCacheEnabled else { return [] }
        return loadEntries()
    }

    func imageEntries() -> [HistoryEntry] {
        entries().filter {
            guard case .image = $0.kind else {
                return false
            }
            return true
        }
    }

    func cacheDirectoryURL() -> URL {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func loadEntries() -> [HistoryEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let items: [HistoryEntry] = urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            switch ext {
            case "png":
                let cloudURL = Self.readCloudURLXattr(on: url)
                return HistoryEntry(fileURL: url, createdAt: date, kind: .image, cloudURL: cloudURL)
            case "color":
                guard let hex = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return HistoryEntry(fileURL: url, createdAt: date, kind: .color(hex: trimmed), cloudURL: nil)
            default:
                return nil
            }
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func image(for entry: HistoryEntry) -> NSImage? {
        guard Defaults.historyCacheEnabled else { return nil }
        guard case .image = entry.kind else { return nil }
        return NSImage(contentsOf: entry.fileURL)
    }

    func clearAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.removeAllEntries()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    private func pruneToLimit() {
        guard Defaults.historyCacheEnabled else {
            removeAllEntries()
            return
        }
        let limit = Defaults.historyCacheLimit
        let all = loadEntries()
        guard all.count > limit else { return }
        let fm = FileManager.default
        for extra in all.dropFirst(limit) {
            try? fm.removeItem(at: extra.fileURL)
        }
    }

    private func removeAllEntries() {
        let fm = FileManager.default
        for url in storedHistoryFileURLs() {
            try? fm.removeItem(at: url)
        }
    }

    private func storedHistoryFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            switch url.pathExtension.lowercased() {
            case "png", "color":
                return true
            default:
                return false
            }
        }
    }

    private static func writeCloudURLXattr(_ cloudURL: URL, on fileURL: URL) {
        let value = cloudURL.absoluteString
        fileURL.withUnsafeFileSystemRepresentation { fsPath in
            guard let fsPath = fsPath else { return }
            value.withCString { cstr in
                _ = setxattr(fsPath, cloudURLXattrKey, cstr, strlen(cstr), 0, 0)
            }
        }
    }

    private static func readCloudURLXattr(on fileURL: URL) -> URL? {
        return fileURL.withUnsafeFileSystemRepresentation { fsPath -> URL? in
            guard let fsPath = fsPath else { return nil }
            let size = getxattr(fsPath, cloudURLXattrKey, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: size)
            let read = buf.withUnsafeMutableBytes { raw -> ssize_t in
                getxattr(fsPath, cloudURLXattrKey, raw.baseAddress, raw.count, 0, 0)
            }
            guard read > 0 else { return nil }
            guard let str = String(bytes: buf[0..<read], encoding: .utf8) else { return nil }
            return URL(string: str)
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
