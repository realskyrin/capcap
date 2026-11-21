import XCTest
@testable import capcap

final class AutoScrollStepPolicyTests: XCTestCase {
    func testFourConsecutiveStationaryFramesFinishCapture() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.stalled), .finish)
        XCTAssertFalse(policy.failed)
    }

    func testUnreliableFrameRetriesAtSamePositionAndDoesNotCountAsPageEnd() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)
        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        }

        // 匹配失败只重试采集，不能滚动并消耗仍有可能找回的重叠内容
        XCTAssertEqual(policy.accept(.retry), .retryCapture)
        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.stalled), .finish)
    }

    func testProgressResetsStationaryAndRetryCounts() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)
        for _ in 0..<3 { _ = policy.accept(.stalled) }
        XCTAssertEqual(policy.accept(.progressed), .scrollAgain)
        XCTAssertEqual(policy.accept(.stalled), .scrollAgain)

        for _ in 0..<3 { _ = policy.accept(.retry) }
        XCTAssertEqual(policy.accept(.progressed), .scrollAgain)
        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.retry), .retryCapture)
        }
        XCTAssertEqual(policy.accept(.retry), .finish)
    }

    func testFourConsecutiveRetriesFinishInsteadOfBlockingInputForever() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.retry), .retryCapture)
        }
        XCTAssertEqual(policy.accept(.retry), .finish)
        XCTAssertTrue(policy.failed)
    }

    func testExplicitFinishStopsImmediately() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        XCTAssertEqual(policy.accept(.finished), .finish)
    }

    func testStationarySamplesWithoutNewScrollDoNotCountAsPageEnd() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)
        for _ in 0..<3 { XCTAssertEqual(policy.accept(.stalled), .scrollAgain) }

        for _ in 0..<8 {
            XCTAssertEqual(policy.accept(.stalled, hadScroll: false), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.stalled, hadScroll: true), .finish)
        XCTAssertFalse(policy.failed)
    }
}
