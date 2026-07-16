import XCTest
@testable import capcap

final class ClipboardColorParserTests: XCTestCase {
    func testNormalizesSixDigitHexColor() {
        XCTAssertEqual(
            ClipboardColorParser.normalizedHex(from: "  #fb6a23\n"),
            "#FB6A23"
        )
    }

    func testRejectsTextWithoutColorPrefix() {
        XCTAssertNil(ClipboardColorParser.normalizedHex(from: "FB6A23"))
    }

    func testRejectsUnsupportedOrInvalidHexColors() {
        XCTAssertNil(ClipboardColorParser.normalizedHex(from: "#FFF"))
        XCTAssertNil(ClipboardColorParser.normalizedHex(from: "#FB6A23FF"))
        XCTAssertNil(ClipboardColorParser.normalizedHex(from: "#FG6A23"))
        XCTAssertNil(ClipboardColorParser.normalizedHex(from: "color #FB6A23"))
    }
}
