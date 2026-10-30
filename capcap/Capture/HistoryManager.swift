import AppKit

enum HistoryEntryKind {
    case image
    case video
    case color(hex: String)
    case text(HistoryTextContent)
    case files(HistoryFileReferences)
}

final class HistoryTextContent {
    private final class CacheValue: NSObject {
        let value: String

        init(_ value: String) {
            self.value = value
        }
    }

    private static let loadQueue = DispatchQueue(
        label: "capcap.historyTextContent",
        qos: .utility,
        attributes: .concurrent
    )
    private static let cache: NSCache<NSString, CacheValue> = {
        let cache = NSCache<NSString, CacheValue>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    let fileURL: URL

    private let lock = NSLock()
    private var cacheKey: NSString {
        fileURL.standardizedFileURL.path as NSString
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var loadedValue: String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.cache.object(forKey: cacheKey)?.value
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedValue = Self.cache.object(forKey: cacheKey)?.value {
            return cachedValue
        }
        let loadedValue = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        Self.cache.setObject(
            CacheValue(loadedValue),
            forKey: cacheKey,
            cost: loadedValue.utf8.count
        )
        return loadedValue
    }

    func save(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        // Copy the existing file first so its extended attributes (including
        // favorite state) survive the atomic replacement.
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(at: fileURL, to: temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Self.cache.setObject(CacheValue(text), forKey: cacheKey, cost: text.utf8.count)
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
private let favoriteXattrKey = "com.capcap.favorite"

final class HistoryManager {
    static let shared = HistoryManager()

    private let queue = DispatchQueue(label: "capcap.history", qos: .utility)
    private let directoryURL: URL
    private let copiedEntryPromotionsURL: URL
    private let entriesCacheLock = NSLock()
    private var cachedEntries: [HistoryEntry]?
    private var cachedEntryCount: Int?
    private var copiedEntryPromotions: [String: Date]
    private var fileReferenceGeneration = 0

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let historyDirectoryURL = base.appendingPathComponent("capcap/History", isDirectory: true)
        directoryURL = historyDirectoryURL
        copiedEntryPromotionsURL = historyDirectoryURL.appendingPathComponent(
            ".copied-entry-promotions.plist"
        )
        copiedEntryPromotions = Self.loadCopiedEntryPromotions(from: copiedEntryPromotionsURL)
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
            selector: #selector(clipboardTextHistoryLimitChanged),
            name: .clipboardTextHistoryLimitDidChange,
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
            removeStoredHistoryEntries(withExtensions: ["txt", "fileref"])
        }

        queue.async { [weak self] in
            guard let self else { return }
            let removedCount = self.pruneToLimits()
            guard removedCount > 0 else { return }
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func limitChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pruneMediaToLimit()
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    @objc private func clipboardTextHistoryLimitChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pruneTextToLimits()
            self.pruneFileReferencesToLimit()
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
        entriesCacheLock.lock()
        fileReferenceGeneration += 1
        entriesCacheLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            if !Defaults.clipboardTextCacheEnabled {
                self.removeStoredHistoryEntries(withExtensions: ["txt", "fileref"])
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
            self.pruneMediaToLimit()
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
            self.pruneMediaToLimit()
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func addText(_ text: String) {
        guard Defaults.clipboardTextCacheEnabled,
              !text.isEmpty,
              text.utf8.count <= HistoryRetentionPolicy.maximumTextEntryBytes else { return }
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
            self.pruneTextToLimits()
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
            self.pruneMediaToLimit()
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
            }
        }
    }

    func addFileReferences(_ urls: [URL]) {
        guard Defaults.clipboardTextCacheEnabled else { return }
        var seen = Set<String>()
        let sources = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        guard !sources.isEmpty else { return }
        entriesCacheLock.lock()
        let generation = fileReferenceGeneration
        entriesCacheLock.unlock()
        let copiedAt = Date()
        HistoryFileReferences.captureQueue.addOperation { [weak self] in
            guard let self else { return }
            self.entriesCacheLock.lock()
            let isCurrent = generation == self.fileReferenceGeneration
            self.entriesCacheLock.unlock()
            guard isCurrent, Defaults.clipboardTextCacheEnabled else { return }
            let references = sources.map { HistoryFileReferences.Reference(url: $0) }
            guard let data = try? JSONEncoder().encode(references) else { return }
            self.queue.async {
                self.entriesCacheLock.lock()
                let isCurrent = generation == self.fileReferenceGeneration
                self.entriesCacheLock.unlock()
                guard isCurrent, Defaults.clipboardTextCacheEnabled else { return }
                let identity = Set(references.map(\.path))
                let duplicates = self.loadCachedEntries().filter { entry in
                    guard case .files(let files) = entry.kind else { return false }
                    return Set(files.references.map(\.path)) == identity
                }
                if let favorite = duplicates.first(where: { Self.isFavorite(url: $0.fileURL) }) {
                    // Preserve the favorite's manifest and xattrs, updating only its history date.
                    try? FileManager.default.setAttributes([.modificationDate: copiedAt],
                                                           ofItemAtPath: favorite.fileURL.path)
                } else {
                    let manifest = self.directoryURL.appendingPathComponent(UUID().uuidString + ".fileref")
                    do { try data.write(to: manifest, options: .atomic) } catch { return }
                    try? FileManager.default.setAttributes([.modificationDate: copiedAt], ofItemAtPath: manifest.path)
                    for duplicate in duplicates { try? FileManager.default.removeItem(at: duplicate.fileURL) }
                }
                self.pruneFileReferencesToLimit()
                self.invalidateEntriesCache()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
                }
            }
        }
    }

    func entries() -> [HistoryEntry] {
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

    func panelEntries() -> [HistoryEntry] {
        let entries = entries()
        let promotedAtByPath = copiedEntryPromotionSnapshot(validFor: entries)
        return HistoryCopyPromotionPolicy.orderedEntries(
            entries,
            promotedAtByPath: promotedAtByPath
        )
    }

    func promoteCopiedEntryIfNeeded(_ entry: HistoryEntry) {
        let entries = entries()
        let promotedAtByPath = copiedEntryPromotionSnapshot(validFor: entries)
        let orderedEntries = HistoryCopyPromotionPolicy.orderedEntries(
            entries,
            promotedAtByPath: promotedAtByPath
        )
        guard let promotedAt = HistoryCopyPromotionPolicy.promotionDate(
            afterCopying: entry,
            in: orderedEntries,
            promotedAtByPath: promotedAtByPath
        ) else {
            return
        }

        entriesCacheLock.lock()
        copiedEntryPromotions[HistoryCopyPromotionPolicy.key(for: entry)] = promotedAt
        let promotionsSnapshot = copiedEntryPromotions
        entriesCacheLock.unlock()

        queue.async { [weak self] in
            self?.persistCopiedEntryPromotions(promotionsSnapshot)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
        }
    }

    func entryCount() -> Int {
        entriesCacheLock.lock()
        defer { entriesCacheLock.unlock() }
        if let cachedEntryCount {
            return cachedEntryCount
        }
        let count = loadEntryCount()
        cachedEntryCount = count
        return count
    }

    func hasFavoriteEntries() -> Bool {
        fileURLsToRemove(includeRecordingMedia: true).contains { Self.isFavorite(url: $0) }
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
        let mediaEntries = loadRecordingDirectoryEntries()
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
            allowedExtensions.insert("fileref")
        }
        return entries(in: directoryURL, allowedExtensions: allowedExtensions,
                       supportedExtensions: ["png", "gif", "mp4", "color", "txt", "fileref"])
    }

    private func loadRecordingDirectoryEntries() -> [HistoryEntry] {
        recordingDirectoriesToScan().flatMap { directory in
            entries(in: directory,
                    allowedExtensions: Defaults.historyCacheEnabled ? ["gif", "mp4"] : [],
                    supportedExtensions: ["gif", "mp4"])
        }
    }

    private func loadEntryCount() -> Int {
        var locations: [(URL, Set<String>)] = []
        for directory in recordingDirectoriesToScan() {
            locations.append((directory, Defaults.historyCacheEnabled ? ["gif", "mp4"] : []))
        }

        var cachedExtensions = Set<String>()
        if Defaults.historyCacheEnabled {
            cachedExtensions.formUnion(["png", "gif", "mp4", "color"])
        }
        if Defaults.clipboardTextCacheEnabled {
            cachedExtensions.insert("txt")
            cachedExtensions.insert("fileref")
        }
        locations.append((directoryURL, cachedExtensions))

        var identities = Set<String>()
        let fm = FileManager.default
        for (directory, allowedExtensions) in locations {
            guard let urls = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            let supportedExtensions: Set<String> = directory == directoryURL
                ? ["png", "gif", "mp4", "color", "txt", "fileref"] : ["gif", "mp4"]
            for url in urls where Self.shouldIncludeEntry(url,
                                                          allowedExtensions: allowedExtensions,
                                                          supportedExtensions: supportedExtensions) {
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

    private func entries(in directory: URL, allowedExtensions: Set<String>,
                         supportedExtensions: Set<String>) -> [HistoryEntry] {
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
            guard Self.shouldIncludeEntry(url,
                                          allowedExtensions: allowedExtensions,
                                          supportedExtensions: supportedExtensions) else { return nil }
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
            case "fileref":
                guard let files = HistoryFileReferences.load(from: url) else { return nil }
                return HistoryEntry(fileURL: url, createdAt: date, kind: .files(files), cloudURL: nil)
            default:
                return nil
            }
        }
    }

    static func shouldIncludeEntry(_ url: URL, allowedExtensions: Set<String>,
                                   supportedExtensions: Set<String>) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
            && (allowedExtensions.contains(ext) || isFavorite(url: url))
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
        guard Defaults.historyCacheEnabled || Self.isFavorite(url: entry.fileURL) else { return nil }
        guard case .image = entry.kind else { return nil }
        return NSImage(contentsOf: entry.fileURL)
    }

    func clearAll(completion: ((Int, Int) -> Void)? = nil) {
        entriesCacheLock.lock()
        fileReferenceGeneration += 1
        entriesCacheLock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.removeAllEntries(includeRecordingMedia: true)
            self.keepCopiedEntryPromotions(forKeptURLs: result.kept)
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
                completion?(result.removed.count, result.kept.count)
            }
        }
    }

    func remove(_ entries: [HistoryEntry], completion: ((Int, Int) -> Void)? = nil) {
        var seen = Set<String>()
        let urls = entries.compactMap { entry -> URL? in
            let url = entry.fileURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            return url
        }

        queue.async {
            let result = Self.removeUnfavoritedEntries(urls)
            self.removeCopiedEntryPromotions(for: result.removed)
            self.invalidateEntriesCache()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .historyDidUpdate, object: nil)
                completion?(result.removed.count, result.kept.count)
            }
        }
    }

    @discardableResult
    private func pruneToLimits() -> Int {
        var removedCount = 0
        if Defaults.historyCacheEnabled {
            removedCount += pruneMediaToLimit()
        }
        if Defaults.clipboardTextCacheEnabled {
            removedCount += pruneTextToLimits()
            removedCount += pruneFileReferencesToLimit()
        }
        return removedCount
    }

    @discardableResult
    private func pruneMediaToLimit() -> Int {
        guard Defaults.historyCacheEnabled else { return 0 }
        return HistoryRetentionPolicy.pruneMedia(
            in: directoryURL,
            limit: Defaults.historyCacheLimit
        )
    }

    @discardableResult
    private func pruneTextToLimits() -> Int {
        guard Defaults.clipboardTextCacheEnabled else { return 0 }
        return HistoryRetentionPolicy.pruneText(
            in: directoryURL,
            limit: Defaults.clipboardTextHistoryLimit
        )
    }

    @discardableResult
    private func pruneFileReferencesToLimit() -> Int {
        HistoryRetentionPolicy.pruneFileReferences(in: directoryURL, limit: Defaults.clipboardTextHistoryLimit)
    }

    private func invalidateEntriesCache() {
        entriesCacheLock.lock()
        cachedEntries = nil
        cachedEntryCount = nil
        entriesCacheLock.unlock()
    }

    private func copiedEntryPromotionSnapshot(validFor entries: [HistoryEntry]) -> [String: Date] {
        let validKeys = Set(entries.map(HistoryCopyPromotionPolicy.key))
        var promotionsToPersist: [String: Date]?

        entriesCacheLock.lock()
        let filteredPromotions = copiedEntryPromotions.filter { validKeys.contains($0.key) }
        if filteredPromotions.count != copiedEntryPromotions.count {
            copiedEntryPromotions = filteredPromotions
            promotionsToPersist = filteredPromotions
        }
        let snapshot = copiedEntryPromotions
        entriesCacheLock.unlock()

        if let promotionsToPersist {
            queue.async { [weak self] in
                self?.persistCopiedEntryPromotions(promotionsToPersist)
            }
        }
        return snapshot
    }

    /// Keeps only the copied-promotion records whose entry survives "delete all
    /// history" (the favorite `keptURLs`), mirroring `removeCopiedEntryPromotions`
    /// but inverted. Promotion keys are standardized file paths
    /// (`HistoryCopyPromotionPolicy.key(for:)`), so a kept entry keeps its rank
    /// intact instead of silently demoting by creation date. Empty `keptURLs`
    /// keeps nothing, reproducing the previous wipe-all behaviour.
    private func keepCopiedEntryPromotions(forKeptURLs keptURLs: [URL]) {
        let keptKeys = Set(keptURLs.map { $0.standardizedFileURL.path })
        entriesCacheLock.lock()
        let previousCount = copiedEntryPromotions.count
        let snapshot = copiedEntryPromotions.filter { keptKeys.contains($0.key) }
        copiedEntryPromotions = snapshot
        entriesCacheLock.unlock()
        guard snapshot.count != previousCount else { return }
        persistCopiedEntryPromotions(snapshot)
    }

    private func removeCopiedEntryPromotions(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let keys = Set(urls.map { $0.standardizedFileURL.path })

        entriesCacheLock.lock()
        let previousCount = copiedEntryPromotions.count
        copiedEntryPromotions = copiedEntryPromotions.filter { !keys.contains($0.key) }
        let promotionsSnapshot = copiedEntryPromotions
        entriesCacheLock.unlock()

        if promotionsSnapshot.count != previousCount {
            persistCopiedEntryPromotions(promotionsSnapshot)
        }
    }

    private static func loadCopiedEntryPromotions(from url: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: url),
              let storedValues = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: TimeInterval] else {
            return [:]
        }
        return storedValues.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func persistCopiedEntryPromotions(_ promotions: [String: Date]) {
        if promotions.isEmpty {
            try? FileManager.default.removeItem(at: copiedEntryPromotionsURL)
            return
        }
        let storedValues = promotions.mapValues(\.timeIntervalSince1970)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: storedValues,
            format: .binary,
            options: 0
        ) else {
            return
        }
        try? data.write(to: copiedEntryPromotionsURL, options: .atomic)
    }

    private func removeAllEntries(includeRecordingMedia: Bool)
        -> (removed: [URL], kept: [URL]) {
        let candidates = fileURLsToRemove(includeRecordingMedia: includeRecordingMedia)
        return Self.removeUnfavoritedEntries(candidates)
    }

    /// Partitions `candidates` into the entries "delete all history" may remove
    /// and the entries it must keep (the favorited ones). A favorited entry is never
    /// removed by the bulk path, so it stays out of `remove` and is returned in
    /// `kept`; `clearAll` uses `kept` to preserve those entries' copied-promotion
    /// rank instead of wiping it. Pure and `@testable`-visible so the bulk
    /// decision can be exercised headlessly without driving the shared
    /// `HistoryManager` directory. Selected deletion and cache disabling use
    /// the same partition so they also preserve favorites.
    static func partitionEntriesForRemoval(_ candidates: [URL]) -> (remove: [URL], kept: [URL]) {
        var remove: [URL] = []
        var kept: [URL] = []
        for url in candidates {
            if isFavorite(url: url) {
                kept.append(url)
            } else {
                remove.append(url)
            }
        }
        return (remove, kept)
    }

    @discardableResult
    static func removeUnfavoritedEntries(_ candidates: [URL]) -> (removed: [URL], kept: [URL]) {
        let decision = partitionEntriesForRemoval(candidates)
        let fm = FileManager.default
        var removed: [URL] = []
        for url in decision.remove {
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                continue
            }
        }
        return (removed, decision.kept)
    }

    private func removeStoredHistoryEntries(withExtensions extensions: Set<String>) {
        Self.removeStoredHistoryEntries(storedHistoryFileURLs(), withExtensions: extensions)
    }

    @discardableResult
    static func removeStoredHistoryEntries(_ candidates: [URL],
                                           withExtensions extensions: Set<String>)
        -> (removed: [URL], kept: [URL]) {
        let matching = candidates.filter {
            extensions.contains($0.pathExtension.lowercased())
        }
        return removeUnfavoritedEntries(matching)
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
            case "png", "gif", "mp4", "color", "txt", "fileref":
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

    /// Marks `fileURL` as favorited (`true`) or unfavorited (`false`) by setting or
    /// removing the `com.capcap.favorite` extended attribute, mirroring the
    /// cloudURL xattr helpers so retention pruning stays a pure read.
    ///
    /// Returns whether the on-disk state now matches the requested state:
    /// favoriting succeeds when `setxattr` writes the marker; unfavoriting succeeds
    /// when the attribute is removed OR when it was already absent (`ENOATTR`),
    /// because an already-unfavorited file is the requested state, not a failure.
    /// Any other failure (missing path, permission denied, …) returns `false`.
    /// The result is intentionally non-discardable: a caller that ignores it can
    /// silently claim success for a write that never persisted (review point 3).
    static func setFavorite(_ favorite: Bool, on fileURL: URL) -> Bool {
        fileURL.withUnsafeFileSystemRepresentation { fsPath -> Bool in
            guard let fsPath = fsPath else { return false }
            if favorite {
                let marker = "1"
                return marker.withCString { cstr in
                    setxattr(fsPath, favoriteXattrKey, cstr, strlen(cstr), 0, 0) == 0
                }
            } else {
                if removexattr(fsPath, favoriteXattrKey, 0) == 0 { return true }
                let reason = errno
                return reason == ENOATTR
            }
        }
    }

    static func isFavorite(url fileURL: URL) -> Bool {
        return fileURL.withUnsafeFileSystemRepresentation { fsPath -> Bool in
            guard let fsPath = fsPath else { return false }
            return getxattr(fsPath, favoriteXattrKey, nil, 0, 0, 0) > 0
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
