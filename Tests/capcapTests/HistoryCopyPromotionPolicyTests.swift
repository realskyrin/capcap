import Foundation
import XCTest
@testable import capcap

final class HistoryCopyPromotionPolicyTests: XCTestCase {
    func testCopyingSeventhItemPromotesItToFront() {
        let entries = makeEntries(count: 8)
        let copiedEntry = entries[6]
        let promotedAt = HistoryCopyPromotionPolicy.promotionDate(
            afterCopying: copiedEntry,
            in: entries,
            promotedAtByPath: [:],
            now: entries[0].createdAt.addingTimeInterval(10)
        )

        XCTAssertNotNil(promotedAt)
        let reorderedEntries = HistoryCopyPromotionPolicy.orderedEntries(
            entries,
            promotedAtByPath: [HistoryCopyPromotionPolicy.key(for: copiedEntry): promotedAt!]
        )
        let expectedEntries = [copiedEntry] + entries.filter {
            HistoryCopyPromotionPolicy.key(for: $0) != HistoryCopyPromotionPolicy.key(for: copiedEntry)
        }
        XCTAssertEqual(
            reorderedEntries.map(HistoryCopyPromotionPolicy.key),
            expectedEntries.map(HistoryCopyPromotionPolicy.key)
        )
    }

    func testCopyingAnyFirstPageItemLeavesItsPositionUnchanged() {
        let entries = makeEntries(count: 8)

        for copiedIndex in 0..<HistoryCopyPromotionPolicy.firstPageItemCount {
            XCTAssertNil(
                HistoryCopyPromotionPolicy.promotionDate(
                    afterCopying: entries[copiedIndex],
                    in: entries,
                    promotedAtByPath: [:]
                )
            )
            XCTAssertEqual(
                HistoryCopyPromotionPolicy.orderedEntries(entries, promotedAtByPath: [:])
                    .map(HistoryCopyPromotionPolicy.key),
                entries.map(HistoryCopyPromotionPolicy.key)
            )
        }
    }

    func testPromotionKeepsOriginalCreationDate() {
        let entries = makeEntries(count: 7)
        let copiedEntry = entries[6]
        let originalCreationDate = copiedEntry.createdAt
        let promotedAt = HistoryCopyPromotionPolicy.promotionDate(
            afterCopying: copiedEntry,
            in: entries,
            promotedAtByPath: [:],
            now: entries[0].createdAt.addingTimeInterval(10)
        )!

        let promotedEntry = HistoryCopyPromotionPolicy.orderedEntries(
            entries,
            promotedAtByPath: [HistoryCopyPromotionPolicy.key(for: copiedEntry): promotedAt]
        )[0]

        XCTAssertEqual(promotedEntry.createdAt, originalCreationDate)
    }

    private func makeEntries(count: Int) -> [HistoryEntry] {
        let newestDate = Date(timeIntervalSince1970: 10_000)
        return (0..<count).map { index in
            HistoryEntry(
                fileURL: URL(fileURLWithPath: "/tmp/history-\(index).png"),
                createdAt: newestDate.addingTimeInterval(TimeInterval(-index)),
                kind: .image,
                cloudURL: nil
            )
        }
    }
}
