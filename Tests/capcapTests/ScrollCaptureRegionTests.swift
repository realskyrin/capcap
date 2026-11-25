import AppKit
import XCTest
@testable import capcap

final class ScrollCaptureRegionTests: XCTestCase {
    func testSmallSelectionUsesVerticalContextWithoutChangingWidth() {
        let selection = CGRect(x: 220, y: 330, width: 173, height: 71)
        let result = ScrollCapturer.matchingRect(for: selection,
                                                sourceBounds: CGRect(x: 100, y: 100, width: 900, height: 800),
                                                displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(result, CGRect(x: 220, y: 165.5, width: 173, height: 400))
        XCTAssertTrue(result.contains(selection))
    }

    func testContextIsClampedToWindowAndCurrentDisplay() {
        let display = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let source = CGRect(x: -1600, y: -300, width: 1000, height: 1500)
        for top in [-195.0, 620.0] {
            let selection = CGRect(x: -1400, y: top, width: 173, height: 71)
            let result = ScrollCapturer.matchingRect(for: selection, sourceBounds: source, displayBounds: display)
            XCTAssertTrue(display.contains(result))
            XCTAssertTrue(source.contains(result))
            XCTAssertTrue(result.contains(selection))
            XCTAssertEqual(result.height, 400)
        }
    }

    func testShortWindowOnlyUsesItsAvailableHeight() {
        let source = CGRect(x: 100, y: 100, width: 400, height: 200)
        let result = ScrollCapturer.matchingRect(for: CGRect(x: 200, y: 150, width: 100, height: 71),
                                                sourceBounds: source, displayBounds: source)
        XCTAssertEqual(result, CGRect(x: 200, y: 100, width: 100, height: 200))
    }

    func testUncertainSourceAndLargeSelectionsKeepOriginalBounds() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let source = CGRect(x: 100, y: 100, width: 900, height: 600)
        for selection in [CGRect(x: 200, y: 200, width: 173, height: 450),
                          CGRect(x: 50, y: 200, width: 173, height: 71),
                          CGRect(x: 200, y: 650, width: 173, height: 71)] {
            XCTAssertEqual(ScrollCapturer.matchingRect(for: selection, sourceBounds: source,
                                                       displayBounds: display), selection)
            XCTAssertEqual(ScrollCapturer.matchingRect(for: selection, sourceBounds: nil,
                                                       displayBounds: display), selection)
        }
    }

    func testCropPreservesSelectedRowsAndAccumulatedScrollAtBothScales() throws {
        let selection = CGRect(x: 40, y: 164, width: 173, height: 71)
        let context = CGRect(x: 40, y: 0, width: 173, height: 400)
        for scale in [1, 2] {
            let source = try rowImage(width: 173 * scale, height: 700 * scale,
                                      size: NSSize(width: 173, height: 700))
            let cropped = try XCTUnwrap(ScrollCapturer.selectedImage(from: source, selection: selection,
                                                                    matchingRect: context))
            let backing = try XCTUnwrap(cropped.cgImagePreservingBacking())
            let expected = try XCTUnwrap(source.cgImagePreservingBacking()?.cropping(
                to: CGRect(x: 0, y: 164 * scale, width: 173 * scale, height: 371 * scale)))
            XCTAssertEqual(cropped.size, NSSize(width: 173, height: 371))
            XCTAssertEqual(backing.width, 173 * scale)
            XCTAssertEqual(backing.height, 371 * scale)
            XCTAssertEqual(try rows(backing), try rows(expected))
        }
    }

    func testFractionalSelectionKeepsOriginalRoundedPixelHeight() throws {
        let selection = CGRect(x: 10, y: 164.667969, width: 173.328125, height: 70.664062)
        let context = CGRect(x: 10, y: 0, width: selection.width, height: 400)
        for growth in [0, 132, 1001] {
            let source = try rowImage(width: 347, height: 800 + growth,
                                      size: NSSize(width: selection.width, height: 400 + CGFloat(growth) / 2))
            let output = try XCTUnwrap(ScrollCapturer.selectedImage(from: source, selection: selection,
                                                                   matchingRect: context))
            XCTAssertEqual(try XCTUnwrap(output.cgImagePreservingBacking()).height, 142 + growth)
            XCTAssertEqual(output.size.height, selection.height + CGFloat(growth) / 2, accuracy: 0.000001)
        }
    }

    func testThumbnailUsesItsOwnBackingRatio() throws {
        let source = try rowImage(width: 86, height: 350, size: NSSize(width: 173, height: 700))
        let output = try XCTUnwrap(ScrollCapturer.selectedImage(
            from: source, selection: CGRect(x: 40, y: 164, width: 173, height: 71),
            matchingRect: CGRect(x: 40, y: 0, width: 173, height: 400)))
        let backing = try XCTUnwrap(output.cgImagePreservingBacking())
        XCTAssertEqual(output.size, NSSize(width: 173, height: 371))
        XCTAssertEqual(backing.width, 86)
        XCTAssertEqual(backing.height, 186)
        let expected = try XCTUnwrap(source.cgImagePreservingBacking()?.cropping(
            to: CGRect(x: 0, y: 82, width: 86, height: 186)))
        XCTAssertEqual(try rows(backing), try rows(expected))
    }

    private func rowImage(width: Int, height: Int, size: NSSize) throws -> NSImage {
        let bytes = (0..<height).flatMap { row in [UInt8](repeating: UInt8(row % 251), count: width) }
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                        provider: XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)),
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: size)
    }

    private func rows(_ image: CGImage) throws -> Data {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return (0..<image.height).reduce(into: Data()) { result, row in
            result.append(data.subdata(in: (row * image.bytesPerRow)..<(row * image.bytesPerRow + image.width)))
        }
    }
}
