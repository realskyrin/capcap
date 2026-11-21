import CoreGraphics
import XCTest

@testable import capcap

final class ScrollCaptureChromeTests: XCTestCase {
    func testDetectsRetinaNativeTrackFromItsActualBoundary() {
        // Geometry and levels follow the native settings scrollbar: 15 pt
        // track, 8 pt thumb, opposite 19 px thumb / 52 px document movement.
        XCTAssertEqual(inset(frame(thumbTop: 110), frame(thumbTop: 129), shift: 52), 30)
    }

    func testDetectsLightTrackAndNonstandardWidthWithoutAssumingFifteenPoints() {
        XCTAssertEqual(inset(
            frame(thumbTop: 110, trackWidth: 36, light: true),
            frame(thumbTop: 169, trackWidth: 36, light: true), shift: 160
        ), 36)
    }

    func testAnUnmovingScrollbarDoesNotAuthorizeACrop() {
        XCTAssertEqual(inset(frame(thumbTop: 110), frame(thumbTop: 110), shift: 52), 0)
    }

    func testAStationaryDocumentBorderAndMarginArePreserved() {
        XCTAssertEqual(inset(frame(thumbTop: nil), frame(thumbTop: nil), shift: 160), 0)
    }

    func testRightAlignedDocumentTextIsPreserved() {
        XCTAssertEqual(inset(
            frame(thumbTop: nil, documentText: 0),
            frame(thumbTop: nil, documentText: 52), shift: 52
        ), 0)
    }

    func testRectangularContentMovingUpWithTheDocumentIsPreserved() {
        XCTAssertEqual(inset(frame(thumbTop: 220), frame(thumbTop: 168), shift: 52), 0)
    }

    func testSeveralRightHandCardsAreNotAThumb() {
        XCTAssertEqual(inset(
            frame(thumbTop: 110, secondThumb: true),
            frame(thumbTop: 129, secondThumb: true), shift: 52
        ), 0)
    }

    func testBorderlessOverlayHasNoProvenContentBoundary() {
        XCTAssertEqual(inset(
            frame(thumbTop: 110, border: false),
            frame(thumbTop: 129, border: false), shift: 52
        ), 0)
    }

    func testResizedOrReverseFramesDoNotAuthorizeACrop() {
        XCTAssertEqual(inset(frame(thumbTop: 110), frame(thumbTop: 129, width: 993), shift: 52), 0)
        XCTAssertEqual(inset(frame(thumbTop: 129), frame(thumbTop: 110), shift: -52), 0)
    }

    private func inset(_ previous: CGImage, _ current: CGImage, shift: Int) -> Int {
        ScrollCaptureChrome.contentRightInset(previous: previous, current: current, shift: shift, scale: 2)
    }

    /// A deterministic gray image, with a narrow track at the right edge and a
    /// flat thumb. This fixture has no implementation-derived detection logic.
    private func frame(
        thumbTop: Int?, trackWidth: Int = 30, light: Bool = false, border: Bool = true,
        secondThumb: Bool = false, documentText: Int? = nil, width: Int = 992
    ) -> CGImage {
        let height = 1016
        let edge = width - trackWidth
        let background: UInt8 = light ? 247 : 40
        let track: UInt8 = light ? 230 : 54
        let thumb: UInt8 = light ? 140 : 115
        var pixels = [UInt8](repeating: background, count: width * height)
        for y in 104..<height {
            for x in edge..<width {
                pixels[y * width + x] = border ? track : background
            }
            if border { pixels[y * width + edge] = light ? 198 : 71 }
            if let top = thumbTop {
                let inFirst = y >= top && y < top + 330
                let inSecond = secondThumb && y >= 650 && y < 800
                if inFirst || inSecond {
                    // Native-style inset on both sides of the track.
                    for x in (edge + trackWidth * 4 / 15)..<(edge + trackWidth * 4 / 5) {
                        pixels[y * width + x] = thumb
                    }
                }
            }
            if let offset = documentText, (y + offset) % 47 < 16 {
                for x in (edge + 8)..<(width - 6) where (x + y) % 8 < 4 {
                    pixels[y * width + x] = light ? 35 : 235
                }
            }
        }
        let data = Data(pixels) as CFData
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: data)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}
