import AppKit
import XCTest
@testable import capcap

final class AutoScrollInputTests: XCTestCase {
    private let controlRect = CGRect(x: 220, y: 220, width: 150, height: 40)

    private func makeScroller(interactiveRect: CGRect? = nil) -> AutoScroller {
        AutoScroller(
            centerPoint: CGPoint(x: 300, y: 350),
            blockingRect: CGRect(x: 100, y: 200, width: 400, height: 300),
            interactiveRect: interactiveRect,
            speedPointsPerSecond: 300
        )
    }

    func testScreenshotBodyStillBlocksMouseInput() {
        let scroller = makeScroller(interactiveRect: controlRect)

        XCTAssertTrue(scroller.blocksMouseInput(at: CGPoint(x: 120, y: 280)))
        XCTAssertTrue(scroller.blocksMouseInput(at: CGPoint(x: 210, y: 240)))
        XCTAssertTrue(scroller.blocksMouseInput(at: CGPoint(x: 380, y: 240)))
    }

    func testControlInsideCaptureAllowsMouseInput() {
        let scroller = makeScroller(interactiveRect: controlRect)

        XCTAssertFalse(scroller.blocksMouseInput(at: CGPoint(x: 250, y: 240)))
    }

    func testNoControlRectPreservesCaptureBlocking() {
        let scroller = makeScroller()

        XCTAssertTrue(scroller.blocksMouseInput(at: CGPoint(x: 250, y: 240)))
    }

    func testPointsOutsideCaptureRemainAllowed() {
        let scroller = makeScroller(interactiveRect: controlRect)

        XCTAssertFalse(scroller.blocksMouseInput(at: CGPoint(x: 90, y: 240)))
        XCTAssertFalse(scroller.blocksMouseInput(at: CGPoint(x: 510, y: 240)))
    }
}
