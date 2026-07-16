import Foundation

enum HistoryCopyPromotionPolicy {
    static let firstPageItemCount = 6

    static func promotionDate(
        afterCopying entry: HistoryEntry,
        in orderedEntries: [HistoryEntry],
        promotedAtByPath: [String: Date],
        now: Date = Date()
    ) -> Date? {
        let copiedKey = key(for: entry)
        guard let copiedIndex = orderedEntries.firstIndex(where: { key(for: $0) == copiedKey }),
              copiedIndex >= firstPageItemCount else {
            return nil
        }

        let newestSortDate = orderedEntries.reduce(Date.distantPast) { newestDate, candidate in
            max(newestDate, sortDate(for: candidate, promotedAtByPath: promotedAtByPath))
        }
        return max(now, newestSortDate.addingTimeInterval(0.001))
    }

    static func orderedEntries(
        _ entries: [HistoryEntry],
        promotedAtByPath: [String: Date]
    ) -> [HistoryEntry] {
        entries.sorted { lhs, rhs in
            let lhsSortDate = sortDate(for: lhs, promotedAtByPath: promotedAtByPath)
            let rhsSortDate = sortDate(for: rhs, promotedAtByPath: promotedAtByPath)
            if lhsSortDate != rhsSortDate {
                return lhsSortDate > rhsSortDate
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return key(for: lhs) < key(for: rhs)
        }
    }

    static func key(for entry: HistoryEntry) -> String {
        entry.fileURL.standardizedFileURL.path
    }

    private static func sortDate(
        for entry: HistoryEntry,
        promotedAtByPath: [String: Date]
    ) -> Date {
        max(entry.createdAt, promotedAtByPath[key(for: entry)] ?? .distantPast)
    }
}
