import AppKit
import XCTest
@testable import capcap

@MainActor
final class OCRServiceTests: XCTestCase {
    func testPreCancelledRecognitionThrowsCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OCRService.recognizeResult(
                image: NSImage(), kind: .apple, config: OCRProviderConfig()
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testUndecodableImageThrowsImageError() async {
        do {
            _ = try await OCRService.recognizeResult(
                image: NSImage(), kind: .apple, config: OCRProviderConfig()
            )
            XCTFail("Expected image error")
        } catch OCRProviderError.image {
            // Expected: decoding failure must not become an empty result.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBlankBitmapReturnsEmptyText() async throws {
        let result = try await OCRService.recognizeResult(
            image: makeBitmap(text: ""), kind: .apple, config: OCRProviderConfig()
        )

        XCTAssertEqual(result.provider, .apple)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testTextBitmapReturnsRecognizedText() async throws {
        // Exercises the installed system recognizer, not a specific cold-start
        // duration or an exact transcription across macOS versions.
        let result = try await OCRService.recognizeResult(
            image: makeBitmap(text: "Hello World"), kind: .apple, config: OCRProviderConfig()
        )

        XCTAssertEqual(result.provider, .apple)
        XCTAssertFalse(result.text.isEmpty)
    }

    private func makeBitmap(text: String) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 640,
            pixelsHigh: 160,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 160).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 56),
            .foregroundColor: NSColor.black,
        ])
        let image = NSImage(size: NSSize(width: 640, height: 160))
        image.addRepresentation(bitmap)
        return image
    }
}
