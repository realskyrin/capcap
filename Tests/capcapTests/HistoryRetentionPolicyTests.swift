import Foundation
import XCTest
@testable import capcap

final class HistoryRetentionPolicyTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func testMediaLimitDoesNotConsumeOrDeleteTextEntries() throws {
        let oldestImage = try makeFile(name: "old.png", contents: Data([0x01]), age: 30)
        let middleImage = try makeFile(name: "middle.png", contents: Data([0x02]), age: 20)
        let newestImage = try makeFile(name: "new.png", contents: Data([0x03]), age: 10)
        let text = try makeFile(name: "note.txt", contents: Data("note".utf8), age: 5)

        XCTAssertEqual(HistoryRetentionPolicy.pruneMedia(in: directoryURL, limit: 2), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestImage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middleImage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestImage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
    }

    func testTextLimitDoesNotConsumeOrDeleteMediaEntries() throws {
        let image = try makeFile(name: "image.png", contents: Data([0x01]), age: 30)
        let oldestText = try makeFile(name: "old.txt", contents: Data("old".utf8), age: 20)
        let newestText = try makeFile(name: "new.txt", contents: Data("new".utf8), age: 10)

        XCTAssertEqual(HistoryRetentionPolicy.pruneText(in: directoryURL, limit: 1), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestText.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newestText.path))
    }

    func testTextPruningKeepsOnlyNewestExactDuplicate() throws {
        let oldDuplicate = try makeFile(name: "old.txt", contents: Data("same text".utf8), age: 20)
        let newDuplicate = try makeFile(name: "new.txt", contents: Data("same text".utf8), age: 10)
        let distinct = try makeFile(name: "distinct.txt", contents: Data("Same text".utf8), age: 5)

        XCTAssertEqual(HistoryRetentionPolicy.pruneText(in: directoryURL, limit: 10), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDuplicate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDuplicate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: distinct.path))
    }

    func testTextPruningHonorsEntryAndTotalByteLimits() throws {
        let oversized = try makeFile(name: "oversized.txt", contents: Data("12345".utf8), age: 5)
        let newest = try makeFile(name: "newest.txt", contents: Data("aaa".utf8), age: 10)
        let middle = try makeFile(name: "middle.txt", contents: Data("bb".utf8), age: 20)
        let oldest = try makeFile(name: "oldest.txt", contents: Data("c".utf8), age: 30)

        XCTAssertEqual(
            HistoryRetentionPolicy.pruneText(
                in: directoryURL,
                limit: 10,
                maximumEntryBytes: 4,
                maximumTotalBytes: 5
            ),
            2
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
    }

    @discardableResult
    private func makeFile(name: String, contents: Data, age: TimeInterval) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try contents.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }
}
