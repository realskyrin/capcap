import Foundation

enum HistoryRetentionPolicy {
    static let mediaExtensions: Set<String> = ["png", "gif", "mp4", "color"]
    static let maximumTextEntryBytes = 1 * 1024 * 1024
    static let maximumTextHistoryBytes = 20 * 1024 * 1024

    private struct StoredFile {
        let url: URL
        let modificationDate: Date
        let byteCount: Int
    }

    @discardableResult
    static func pruneMedia(in directory: URL, limit: Int) -> Int {
        let files = storedFiles(in: directory, allowedExtensions: mediaExtensions)
            .sorted(by: newestFirst)
        return remove(files.dropFirst(max(0, limit)).map(\.url))
    }

    @discardableResult
    static func pruneText(
        in directory: URL,
        limit: Int,
        maximumEntryBytes: Int = maximumTextEntryBytes,
        maximumTotalBytes: Int = maximumTextHistoryBytes
    ) -> Int {
        let files = storedFiles(in: directory, allowedExtensions: ["txt"])
            .sorted(by: newestFirst)
        let normalizedLimit = max(0, limit)
        let normalizedEntryLimit = max(0, maximumEntryBytes)
        let normalizedTotalLimit = max(0, maximumTotalBytes)
        var seenContents = Set<Data>()
        var keptCount = 0
        var keptBytes = 0
        var urlsToRemove: [URL] = []

        for file in files {
            guard file.byteCount > 0,
                  file.byteCount <= normalizedEntryLimit,
                  let data = try? Data(contentsOf: file.url, options: [.mappedIfSafe]),
                  !data.isEmpty,
                  data.count <= normalizedEntryLimit else {
                urlsToRemove.append(file.url)
                continue
            }

            let isDuplicate = seenContents.contains(data)
            let exceedsCount = keptCount >= normalizedLimit
            let exceedsTotalBytes = keptBytes + data.count > normalizedTotalLimit
            guard !isDuplicate, !exceedsCount, !exceedsTotalBytes else {
                urlsToRemove.append(file.url)
                continue
            }

            seenContents.insert(data)
            keptCount += 1
            keptBytes += data.count
        }

        return remove(urlsToRemove)
    }

    private static func storedFiles(in directory: URL, allowedExtensions: Set<String>) -> [StoredFile] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile != false else { return nil }
            return StoredFile(
                url: url,
                modificationDate: values?.contentModificationDate ?? .distantPast,
                byteCount: values?.fileSize ?? 0
            )
        }
    }

    private static func newestFirst(_ lhs: StoredFile, _ rhs: StoredFile) -> Bool {
        if lhs.modificationDate != rhs.modificationDate {
            return lhs.modificationDate > rhs.modificationDate
        }
        return lhs.url.lastPathComponent > rhs.url.lastPathComponent
    }

    private static func remove(_ urls: [URL]) -> Int {
        var removedCount = 0
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                removedCount += 1
            } catch {
                continue
            }
        }
        return removedCount
    }
}
