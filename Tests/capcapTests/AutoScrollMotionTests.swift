import AppKit
import XCTest
@testable import capcap

final class AutoScrollMotionTests: XCTestCase {
    func testSixtyHertzTicksMoveInSmallStepsAtRequestedSpeed() {
        var motion = AutoScroller.MotionState(speed: 360, maximumUnconfirmedTravel: 1_000)
        let steps = (0..<60).map { _ in motion.advance(elapsed: 1.0 / 60) }

        XCTAssertTrue(steps.allSatisfy { $0 == 6 })
        XCTAssertEqual(steps.reduce(0, +), 360)
        XCTAssertEqual(motion.totalTravel, 360)
    }

    func testFractionalPixelsAccumulateInsteadOfLosingSpeed() {
        var motion = AutoScroller.MotionState(speed: 90, maximumUnconfirmedTravel: 1_000)
        let steps = (0..<60).map { _ in motion.advance(elapsed: 1.0 / 60) }

        XCTAssertEqual(Array(steps.prefix(4)), [1, 2, 1, 2])
        XCTAssertEqual(steps.reduce(0, +), 90)
    }

    func testCaptureAcknowledgesOnlyTravelBeforeItsSnapshot() {
        var motion = AutoScroller.MotionState(speed: 600, maximumUnconfirmedTravel: 120)
        for _ in 0..<6 { _ = motion.advance(elapsed: 1.0 / 60) }
        let snapshotTravel = motion.totalTravel
        XCTAssertEqual(snapshotTravel, 60)

        // 匹配期间仍在滚动的距离必须留在未确认额度中
        for _ in 0..<6 { _ = motion.advance(elapsed: 1.0 / 60) }
        XCTAssertEqual(motion.totalTravel, 120)
        XCTAssertEqual(motion.advance(elapsed: 1.0 / 60), 0)
        motion.acknowledge(snapshotTravel)

        for _ in 0..<6 { XCTAssertEqual(motion.advance(elapsed: 1.0 / 60), 10) }
        XCTAssertEqual(motion.totalTravel, 180)
        XCTAssertEqual(motion.advance(elapsed: 1.0 / 60), 0)
    }

    func testPausedOrBackpressuredTicksDoNotBuildUpALargeResumeStep() {
        var motion = AutoScroller.MotionState(speed: 360, maximumUnconfirmedTravel: 18)
        for _ in 0..<3 { _ = motion.advance(elapsed: 1.0 / 60) }
        for _ in 0..<30 { XCTAssertEqual(motion.advance(elapsed: 1.0 / 60), 0) }

        motion.pause()
        XCTAssertEqual(motion.advance(elapsed: 5), 0)
        XCTAssertEqual(motion.totalTravel, 18)
        motion.acknowledge(18)
        XCTAssertEqual(motion.advance(elapsed: 1.0 / 60), 6)
    }

    func testLateTimerDoesNotCatchUpWithOneLargeJump() {
        var motion = AutoScroller.MotionState(speed: 360, maximumUnconfirmedTravel: 1_000)

        XCTAssertEqual(motion.advance(elapsed: 2), 12)
        XCTAssertEqual(motion.advance(elapsed: 1.0 / 60), 6)
        XCTAssertEqual(motion.advance(elapsed: -1), 0)
        XCTAssertEqual(motion.totalTravel, 18)
    }

    func testEventsPreservePrecisePixelsAndGesturePhasesWithoutMomentum() throws {
        let location = CGPoint(x: 120, y: 240)
        let scroller = AutoScroller(
            centerPoint: location,
            blockingRect: CGRect(x: 20, y: 40, width: 400, height: 500),
            speedPointsPerSecond: 360
        )
        let phases: [(CGScrollPhase, NSEvent.Phase, Int)] = [
            (.began, .began, -6),
            (.changed, .changed, -6),
            (.ended, .ended, 0),
        ]

        // 只构造和读取事件，测试不会向其他应用投递滚动输入
        for (cgPhase, expectedPhase, delta) in phases {
            let event = try XCTUnwrap(scroller.makeScrollEvent(delta: delta, phase: cgPhase))
            let nativeEvent = try XCTUnwrap(NSEvent(cgEvent: event))
            XCTAssertEqual(event.location, location)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(delta))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), Int64(cgPhase.rawValue))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
            XCTAssertTrue(nativeEvent.hasPreciseScrollingDeltas)
            XCTAssertEqual(nativeEvent.scrollingDeltaY, CGFloat(delta), accuracy: 0.01)
            XCTAssertEqual(nativeEvent.phase, expectedPhase)
            XCTAssertEqual(nativeEvent.momentumPhase, [])
        }
    }
}
