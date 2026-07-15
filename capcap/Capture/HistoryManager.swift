import AppKit

enum HistoryEntryKind {
    case image
    case video
    case color(hex: String)
    case text(HistoryTextContent)
}

final class HistoryTextContent {
    private static let loadQueue = DispatchQueue(
        label: "capcap.historyTextContent",
        qos: .utility,
        attributes: .concurrent
    )

    let fileURL: URL

    private let lock = NSLock()
    private var cachedValue: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var loadedValue: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedValue
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedValue {
            return cachedValue
        }
        let loadedValue = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        cachedValue = loadedValue
        return loadedValue
    }

    func load(completion: @escaping (String) -> Void) {
        if let loadedValue {
            if Thread.isMainThread {
                completion(loadedValue)
            } else {
                DispatchQueue.main.async {
                    completion(loadedValue)
                }
            }
            return
        }
        Self.loadQueue.async { [self] in
            let value = value
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }

    func preload() {
        guard loadedValue == nil else { return }
        Self.loadQueue.async { [self] in
            _ = value
        }
    }
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
    private let entriesCacheLock = NSLock()
    private var cachedEntries: [HistoryEntry]?
    private var cachedEntryCount: Int?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardTextCacheEnabledChanged),
            name: .clipboardTextCacheEnabledDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingSaveDirectoryChanged),
            name: .recordingSaveDirectoryDidChange,
            object: nil
        )

        if !Defaults.historyCacheEnabled {
            removeStoredHistoryEntries(withExtensions: ["png", "gif", "mp4", "color"])
        }
        if !Defaults.clipboardTextCacheEnabled {
            removeStoredHistoryEntries(withExtensions: ["txt"])
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func limitChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pruneToLimit()
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    @objc private func cacheEnabledChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            if !Defaults.historyCacheEnabled {
                self.removeStoredHistoryEntries(withExtensions: ["png", "gif", "mp4", "color"])
            }
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    @objc private func clipboardTextCacheEnabledChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            if !Defaults.clipboardTextCacheEnabled {
                self.removeStoredHistoryEntries(withExtensions: ["txt"])
            }
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    @objc private func recordingSaveDirectoryChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.invalidateEntriesCache()
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
            self.invalidateEntriesCache()
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
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func addText(_ text: String) {
        guard Defaults.clipboardTextCacheEnabled, !text.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard Defaults.clipboardTextCacheEnabled else { return }
            let name = Self.filenameFormatter.string(from: Date()) + ".txt"
            let url = self.directoryURL.appendingPathComponent(name)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return
            }
            self.pruneToLimit()
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func addFile(_ sourceURL: URL) {
        guard Defaults.historyCacheEnabled else { return }
        let ext = sourceURL.pathExtension.lowercased()
        guard ["gif", "mp4"].contains(ext) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard Defaults.historyCacheEnabled else { return }
            let name = Self.filenameFormatter.string(from: Date()) + "." + ext
            let url = self.directoryURL.appendingPathComponent(name)
            let fm = FileManager.default
            do {
                try? fm.removeItem(at: url)
                do {
                    try fm.linkItem(at: sourceURL, to: url)
                } catch {
                    try fm.copyItem(at: sourceURL, to: url)
                }
            } catch {
                return
            }
            self.pruneToLimit()
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func entries() -> [HistoryEntry] {
        guard Defaults.isHistoryCacheAvailable else { return [] }
        entriesCacheLock.lock()
        defer { entriesCacheLock.unlock() }
        if let cachedEntries {
            return cachedEntries
        }
        let entries = loadEntries()
        cachedEntries = entries
        cachedEntryCount = entries.count
        return entries
    }

    func entryCount() -> Int {
        guard Defaults.isHistoryCacheAvailable else { return 0 }
        entriesCacheLock.lock()
        defer { entriesCacheLock.unlock() }
        if let cachedEntryCount {
            return cachedEntryCount
        }
        let count = loadEntryCount()
        cachedEntryCount = count
        return count
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
        let mediaEntries = Defaults.historyCacheEnabled ? loadRecordingDirectoryEntries() : []
        let cachedEntries = loadCachedEntries()
        let items = deduplicatedEntries(mediaEntries + cachedEntries)
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    private func loadCachedEntries() -> [HistoryEntry] {
        var allowedExtensions = Set<String>()
        if Defaults.historyCacheEnabled {
            allowedExtensions.formUnion(["png", "gif", "mp4", "color"])
        }
        if Defaults.clipboardTextCacheEnabled {
            allowedExtensions.insert("txt")
        }
        return entries(in: directoryURL, allowedExtensions: allowedExtensions)
    }

    private func loadRecordingDirectoryEntries() -> [HistoryEntry] {
        recordingDirectoriesToScan().flatMap { directory in
            entries(in: directory, allowedExtensions: ["gif", "mp4"])
        }
    }

    private func loadEntryCount() -> Int {
        var locations: [(URL, Set<String>)] = []
        if Defaults.historyCacheEnabled {
            for directory in recordingDirectoriesToScan() {
                locations.append((directory, ["gif", "mp4"]))
            }
        }

        var cachedExtensions = Set<String>()
        if Defaults.historyCacheEnabled {
            cachedExtensions.formUnion(["png", "gif", "mp4", "color"])
        }
        if Defaults.clipboardTextCacheEnabled {
            cachedExtensions.insert("txt")
        }
        locations.append((directoryURL, cachedExtensions))

        var identities = Set<String>()
        let fm = FileManager.default
        for (directory, allowedExtensions) in locations {
            guard !allowedExtensions.isEmpty,
                  let urls = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for url in urls where allowedExtensions.contains(url.pathExtension.lowercased()) {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile != false, (values?.fileSize ?? 0) > 0 else { continue }
                identities.insert(Self.fileIdentity(for: url))
            }
        }
        return identities.count
    }

    private func recordingDirectoriesToScan() -> [URL] {
        var directories: [URL] = []
        var seen = Set<String>()
        for directory in [Defaults.recordingSaveDirectory, Defaults.defaultRecordingSaveDirectory] {
            let normalized = directory.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { continue }
            directories.append(normalized)
        }
        return directories
    }

    private func entries(in directory: URL, allowedExtensions: Set<String>) -> [HistoryEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { return nil }
            let date = values?.contentModificationDate ?? .distantPast
            switch ext {
            case "png", "gif":
                let cloudURL = Self.readCloudURLXattr(on: url)
                return HistoryEntry(fileURL: url, createdAt: date, kind: .image, cloudURL: cloudURL)
            case "mp4":
                return HistoryEntry(fileURL: url, createdAt: date, kind: .video, cloudURL: nil)
            case "color":
                guard let hex = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return HistoryEntry(fileURL: url, createdAt: date, kind: .color(hex: trimmed), cloudURL: nil)
            case "txt":
                guard (values?.fileSize ?? 0) > 0 else { return nil }
                return HistoryEntry(
                    fileURL: url,
                    createdAt: date,
                    kind: .text(HistoryTextContent(fileURL: url)),
                    cloudURL: nil
                )
            default:
                return nil
            }
        }
    }

    private func deduplicatedEntries(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let identity = Self.fileIdentity(for: entry.fileURL)
            guard seen.insert(identity).inserted else { return nil }
            return entry
        }
    }

    func image(for entry: HistoryEntry) -> NSImage? {
        guard Defaults.historyCacheEnabled else { return nil }
        guard case .image = entry.kind else { return nil }
        return NSImage(contentsOf: entry.fileURL)
    }

    func clearAll(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.removeAllEntries(includeRecordingMedia: true)
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
                completion?()
            }
        }
    }

    func remove(_ entries: [HistoryEntry], completion: ((Int) -> Void)? = nil) {
        var seen = Set<String>()
        let urls = entries.compactMap { entry -> URL? in
            let url = entry.fileURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            return url
        }

        queue.async {
            let fm = FileManager.default
            var removedCount = 0
            for url in urls {
                do {
                    try fm.removeItem(at: url)
                    removedCount += 1
                } catch {
                    continue
                }
            }
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
                completion?(removedCount)
            }
        }
    }

    private func pruneToLimit() {
        guard Defaults.isHistoryCacheAvailable else {
            removeAllEntries(includeRecordingMedia: false)
            return
        }
        let limit = Defaults.historyCacheLimit
        let all = loadCachedEntries().sorted { $0.createdAt > $1.createdAt }
        guard all.count > limit else { return }
        let fm = FileManager.default
        for extra in all.dropFirst(limit) {
            try? fm.removeItem(at: extra.fileURL)
        }
    }

    private func invalidateEntriesCache() {
        entriesCacheLock.lock()
        cachedEntries = nil
        cachedEntryCount = nil
        entriesCacheLock.unlock()
    }

    private func removeAllEntries(includeRecordingMedia: Bool) {
        let fm = FileManager.default
        for url in fileURLsToRemove(includeRecordingMedia: includeRecordingMedia) {
            try? fm.removeItem(at: url)
        }
    }

    private func removeStoredHistoryEntries(withExtensions extensions: Set<String>) {
        let fm = FileManager.default
        for url in storedHistoryFileURLs() where extensions.contains(url.pathExtension.lowercased()) {
            try? fm.removeItem(at: url)
        }
    }

    private func fileURLsToRemove(includeRecordingMedia: Bool) -> [URL] {
        var urls = storedHistoryFileURLs()
        if includeRecordingMedia {
            urls += recordingDirectoriesToScan().flatMap { directory in
                storedMediaFileURLs(in: directory)
            }
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { return nil }
            return normalized
        }
    }

    private func storedMediaFileURLs(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "gif" || ext == "mp4" else { return false }
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
            return isRegularFile
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
            case "png", "gif", "mp4", "color", "txt":
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

    private static func fileIdentity(for url: URL) -> String {
        let normalized = url.standardizedFileURL
        if let values = try? normalized.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
           let fileIdentifier = values.fileResourceIdentifier {
            let volumeIdentifier = values.volumeIdentifier.map { String(describing: $0) } ?? ""
            return "file:\(volumeIdentifier):\(String(describing: fileIdentifier))"
        }
        return "path:\(normalized.path)"
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
