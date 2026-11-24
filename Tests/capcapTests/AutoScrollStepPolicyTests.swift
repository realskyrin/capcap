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

    func testRevisitedFramesAccumulateWithStationaryFramesUntilPageEnd() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        XCTAssertEqual(policy.accept(.revisited), .scrollAgain)
        XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        XCTAssertEqual(policy.accept(.revisited), .finish)
        XCTAssertFalse(policy.failed)
    }

    func testFreshContentResetsRevisitedAndStationaryCounts() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<3 { XCTAssertEqual(policy.accept(.revisited), .scrollAgain) }
        XCTAssertEqual(policy.accept(.progressed), .scrollAgain)
        XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        XCTAssertEqual(policy.accept(.revisited), .scrollAgain)
        XCTAssertEqual(policy.accept(.stalled), .scrollAgain)
        XCTAssertEqual(policy.accept(.revisited), .finish)
    }

    func testRevisitedSamplesWithoutNewScrollDoNotRepeatPageEndEvidence() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)
        for _ in 0..<3 { XCTAssertEqual(policy.accept(.revisited), .scrollAgain) }

        for _ in 0..<8 {
            XCTAssertEqual(policy.accept(.revisited, hadScroll: false), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.stalled), .finish)
    }

    func testAlternatingRetriesAndStationaryFramesHaveABoundedFailureBudget() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.retry), .retryCapture)
            XCTAssertEqual(policy.accept(.stalled, hadScroll: false), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.retry), .retryCapture)
        XCTAssertEqual(policy.accept(.stalled, hadScroll: false), .finish)
        XCTAssertTrue(policy.failed)
    }

    func testAlternatingRetriesAndRevisitedFramesCannotRunForever() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.retry), .retryCapture)
            XCTAssertEqual(policy.accept(.revisited, hadScroll: false), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.retry), .retryCapture)
        XCTAssertEqual(policy.accept(.revisited, hadScroll: false), .finish)
        XCTAssertTrue(policy.failed)
    }

    func testFreshProgressResetsTheMixedFailureBudget() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<3 {
            _ = policy.accept(.retry)
            _ = policy.accept(.stalled, hadScroll: false)
        }
        XCTAssertEqual(policy.accept(.progressed), .scrollAgain)
        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.retry), .retryCapture)
            XCTAssertEqual(policy.accept(.revisited, hadScroll: false), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.retry), .retryCapture)
        XCTAssertEqual(policy.accept(.revisited, hadScroll: false), .finish)
        XCTAssertTrue(policy.failed)
    }

    func testIdleSamplesWithoutAnyMotionOrFailureDoNotEndCapture() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        for _ in 0..<20 {
            XCTAssertEqual(policy.accept(.stalled, hadScroll: false), .scrollAgain)
            XCTAssertEqual(policy.accept(.revisited, hadScroll: false), .scrollAgain)
        }
        XCTAssertFalse(policy.failed)
    }

    func testReliableStationaryFramesAfterRetryRecoverAndReportPageEnd() {
        var policy = AutoScroller.StepPolicy(stallThreshold: 4)

        XCTAssertEqual(policy.accept(.retry), .retryCapture)
        for _ in 0..<3 {
            XCTAssertEqual(policy.accept(.stalled, hadScroll: true), .scrollAgain)
        }
        XCTAssertEqual(policy.accept(.stalled, hadScroll: true), .finish)
        XCTAssertFalse(policy.failed)
    }

}
