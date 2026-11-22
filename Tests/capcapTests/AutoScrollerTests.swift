import XCTest

@testable import capcap

final class AutoScrollerTests: XCTestCase {
    func testOnlyFirstConsecutiveRetryResamplesInPlace() {
        let first = AutoScroller.nextCapture(after: .retry, consecutiveRetries: 0)
        XCTAssertFalse(first.shouldScroll)
        XCTAssertEqual(first.consecutiveRetries, 1)

        let second = AutoScroller.nextCapture(after: .retry, consecutiveRetries: first.consecutiveRetries)
        XCTAssertTrue(second.shouldScroll)
        XCTAssertEqual(second.consecutiveRetries, 2)

        let third = AutoScroller.nextCapture(after: .retry, consecutiveRetries: second.consecutiveRetries)
        XCTAssertTrue(third.shouldScroll)
        XCTAssertEqual(third.consecutiveRetries, 3)
    }

    func testProgressAndStallEndTheConsecutiveRetrySequence() {
        for result: AutoScroller.StepResult in [.progressed, .stalled] {
            let next = AutoScroller.nextCapture(after: result, consecutiveRetries: 2)
            XCTAssertTrue(next.shouldScroll)
            XCTAssertEqual(next.consecutiveRetries, 0)
            XCTAssertFalse(AutoScroller.nextCapture(after: .retry, consecutiveRetries: next.consecutiveRetries).shouldScroll)
        }
    }
}
