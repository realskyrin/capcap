import Foundation
import XCTest
@testable import capcap

final class CustomHTTPUploaderTests: XCTestCase {
    func testResponsePathReadsNestedImageURL() throws {
        let body = Data(#"{"data":{"links":{"url":"https://cdn.example.com/image.png"}}}"#.utf8)

        let url = try XCTUnwrap(
            CustomHTTPUploader.responseURL(from: body, path: "data.links.url")
        )

        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/image.png")
    }

    func testResponsePathFallsBackToCommonURLKeys() throws {
        let body = Data(#"{"url":"https://cdn.example.com/image.png"}"#.utf8)

        let url = try XCTUnwrap(CustomHTTPUploader.responseURL(from: body, path: nil))

        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/image.png")
    }

    func testValidationAllowsLocalHTTPAndRejectsRemoteHTTP() {
        XCTAssertNil(CustomHTTPUploader.validate(ProviderConfig(
            kind: .custom,
            fields: ["endpoint": "http://127.0.0.1:8080/upload"]
        )))
        XCTAssertNotNil(CustomHTTPUploader.validate(ProviderConfig(
            kind: .custom,
            fields: ["endpoint": "http://example.com/upload"]
        )))
    }
}
