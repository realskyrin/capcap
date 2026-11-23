import Foundation
import XCTest
@testable import capcap

final class ScreenCaptureSessionTests: XCTestCase {
    func testFreshSessionRequiresContentForEveryExclusionList() throws {
        let session = ScreenCapturer.ContentSession()
        XCTAssertNil(try session.cachedContent(excluding: []))
        XCTAssertNil(try session.cachedContent(excluding: [12, 34]))
    }

    func testFinishedSessionCannotStartAnotherCapture() {
        let session = ScreenCapturer.ContentSession()
        session.finish()
        // 收尾后迟到的后台任务不能重新开始抓屏，也不能重新建立缓存
        XCTAssertThrowsError(try session.cachedContent(excluding: [])) {
            XCTAssertTrue($0 is CancellationError)
        }
        session.finish()
        XCTAssertThrowsError(try session.cachedContent(excluding: [12, 34])) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
