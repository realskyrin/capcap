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

    func testExistingCustomConfigurationKeepsItsFields() {
        let config = ProviderConfig(kind: .custom, fields: [
            "endpoint": "https://img.example.com/upload",
            "fileField": "image",
            "headers": "Authorization: Bearer existing-token",
            "responsePath": "data.links.url",
        ])

        XCTAssertEqual(CustomUploadPreset.selected(in: config), .other)
        XCTAssertEqual(CustomUploadPreset.other.resolvedConfig(from: config), config)
        var unknownPreset = config
        unknownPreset.fields["preset"] = "future-provider"
        XCTAssertEqual(CustomUploadPreset.selected(in: unknownPreset), .other)
    }

    func testZiplineRequestUsesPlainTextResponseAndSeparateCredentials() throws {
        let config = ProviderConfig(kind: .custom, fields: [
            "preset": "zipline",
            "ziplineURL": "https://img.example.com/team/",
            "ziplineToken": "zipline-token",
            "endpoint": "https://old.example.com/upload",
            "headers": "Authorization: old-token",
            "formFields": "token=old-token",
        ])
        let (request, body) = try makeRequest(config)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(request.url?.absoluteString, "https://img.example.com/team/api/upload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "zipline-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-zipline-no-json"), "true")
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"test.png\""))
        XCTAssertFalse(text.contains("old-token"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertEqual(CustomHTTPUploader.responseURL(
            from: Data("https://img.example.com/image.png\n".utf8), path: nil
        )?.absoluteString, "https://img.example.com/image.png")
    }

    func testEasyImagesRequestSendsTokenInFormInsteadOfHeader() throws {
        let config = ProviderConfig(kind: .custom, fields: [
            "preset": "easyImages",
            "easyImagesURL": "https://img.example.com/gallery/api/index.php/",
            "easyImagesToken": "token==value",
            "headers": "Authorization: old-token",
        ])
        let (request, body) = try makeRequest(config)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(request.url?.absoluteString, "https://img.example.com/gallery/api/index.php")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(text.contains("name=\"token\"\r\n\r\ntoken==value\r\n"))
        XCTAssertTrue(text.contains("name=\"image\"; filename=\"test.png\""))
        XCTAssertEqual(CustomUploadPreset.easyImages.resolvedConfig(from: config).value("responsePath"), "url")
    }

    func testPresetRequiresItsOwnSiteAndToken() {
        for preset in [CustomUploadPreset.zipline, .easyImages] {
            let tokenKey = preset.tokenKey!
            var fields = ["preset": preset.rawValue, "endpoint": "https://old.example.com/upload"]
            XCTAssertNotNil(CustomHTTPUploader.validate(ProviderConfig(kind: .custom, fields: fields)))
            fields[tokenKey] = "token"
            XCTAssertNotNil(CustomHTTPUploader.validate(ProviderConfig(kind: .custom, fields: fields)))
            fields[preset.siteKey] = "https://img.example.com"
            XCTAssertNil(CustomHTTPUploader.validate(ProviderConfig(kind: .custom, fields: fields)))
            fields[tokenKey] = "token\nx-injected: value"
            XCTAssertNotNil(CustomHTTPUploader.validate(ProviderConfig(kind: .custom, fields: fields)))
        }
    }

    func testOtherAllowsEmptySavedFieldsButCannotUploadWithoutEndpoint() {
        let config = ProviderConfig(kind: .custom, fields: ["preset": "other"])

        XCTAssertNotNil(CustomHTTPUploader.validate(config))
        XCTAssertThrowsError(try makeRequest(config))
    }

    func testFormFieldsPreserveEqualsAndAllowEmptyValues() throws {
        let config = ProviderConfig(kind: .custom, fields: [
            "endpoint": "https://img.example.com/upload",
            "formFields": "token=a=b==\nfolder=Screenshots\nempty=",
            "headers": "Content-Type: invalid\nContent-Length: 1\nX-Custom: value",
        ])
        let (request, body) = try makeRequest(config)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)

        XCTAssertTrue(text.contains("name=\"token\"\r\n\r\na=b==\r\n"))
        XCTAssertTrue(text.contains("name=\"folder\"\r\n\r\nScreenshots\r\n"))
        XCTAssertTrue(text.contains("name=\"empty\"\r\n\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Custom"), "value")
    }

    func testRejectsMalformedFormFieldsAndUnsafeNames() {
        for formFields in ["missing-equals", "=token", "bad\"name=value", "bad\\name=value", "bad\tname=value"] {
            let config = ProviderConfig(kind: .custom, fields: [
                "endpoint": "https://img.example.com/upload", "formFields": formFields,
            ])
            XCTAssertNotNil(CustomHTTPUploader.validate(config), formFields)
        }
        let config = ProviderConfig(kind: .custom, fields: [
            "endpoint": "https://img.example.com/upload", "fileField": "file\r\nx-injected",
        ])
        XCTAssertNotNil(CustomHTTPUploader.validate(config))
    }

    private func makeRequest(_ config: ProviderConfig) throws -> (URLRequest, Data) {
        try CustomHTTPUploader.makeRequest(
            data: Data("image-data".utf8), fileName: "test.png", contentType: "image/png", config: config
        )
    }
}
