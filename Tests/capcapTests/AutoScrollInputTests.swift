import AppKit
import Carbon
import XCTest
@testable import capcap

final class AutoScrollInputTests: XCTestCase {
    func testEscapeAndFinishKeysAreConsumedAndForwardedToTheCaptureSession() throws {
        for keyCode in [kVK_Escape, kVK_ANSI_A, kVK_Return, kVK_Space] {
            let forwarded = expectation(description: "Forward key \(keyCode)")
            forwarded.assertForOverFulfill = true
            let scroller = AutoScroller(
                centerPoint: .zero,
                blockingRect: .zero,
                speedPointsPerSecond: 300,
                onKeyPressed: { event in
                    XCTAssertEqual(event.type, .keyDown)
                    XCTAssertEqual(Int(event.keyCode), keyCode)
                    forwarded.fulfill()
                }
            )
            // 直接检查事件分发，不安装全局监听或向其他应用发送按键
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil,
                                             virtualKey: CGKeyCode(keyCode), keyDown: true))
            event.flags = []
            XCTAssertNil(scroller.handleTappedEvent(type: .keyDown, event: event))
            XCTAssertNil(scroller.handleTappedEvent(type: .keyDown, event: event))
            wait(for: [forwarded], timeout: 1)
        }
    }
}
