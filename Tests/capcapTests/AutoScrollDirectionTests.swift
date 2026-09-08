import XCTest
@testable import capcap

final class AutoScrollDirectionTests: XCTestCase {
    func testReversedWheelPolarityFlipsOnlyOnceAtStallBoundary() {
        var polarity = -1
        var hasReversed = false

        for stallCount in 0..<3 {
            let next = AutoScroller.nextWheelPolarityForTesting(
                current: polarity,
                stallCount: stallCount,
                stallThreshold: 4,
                hasTriedReversal: hasReversed
            )
            XCTAssertEqual(next.polarity, polarity)
            XCTAssertEqual(next.shouldTryReversal, hasReversed)
        }

        let boundary = AutoScroller.nextWheelPolarityForTesting(
            current: polarity,
            stallCount: 3,
            stallThreshold: 4,
            hasTriedReversal: hasReversed
        )
        XCTAssertEqual(boundary.polarity, 1)
        XCTAssertTrue(boundary.shouldTryReversal)

        polarity = boundary.polarity
        hasReversed = boundary.shouldTryReversal

        let afterBoundary = AutoScroller.nextWheelPolarityForTesting(
            current: polarity,
            stallCount: 4,
            stallThreshold: 4,
            hasTriedReversal: hasReversed
        )
        XCTAssertEqual(afterBoundary.polarity, 1)
        XCTAssertTrue(afterBoundary.shouldTryReversal)
    }

    func testAutoScrollSpeedCasesAreStableAndRejectUnknownValues() {
        XCTAssertEqual(Defaults.AutoScrollSpeed(rawValue: "slow"), .slow)
        XCTAssertEqual(Defaults.AutoScrollSpeed(rawValue: "normal"), .normal)
        XCTAssertEqual(Defaults.AutoScrollSpeed(rawValue: "fast"), .fast)
        XCTAssertNil(Defaults.AutoScrollSpeed(rawValue: "unexpected"))
    }
}
