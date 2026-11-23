import AppKit
import XCTest
@testable import capcap

final class SpotlightAnnotationTests: XCTestCase {
    func testSpotlightDimsOutsideAndPreservesHighlight() throws {
        let rep = try makeWhiteBitmap(width: 20, height: 20)
        let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        SpotlightAnnotation(rect: NSRect(x: 6, y: 6, width: 8, height: 8))
            .draw(
                in: graphicsContext.cgContext,
                bounds: NSRect(x: 0, y: 0, width: 20, height: 20)
            )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let outside = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        let inside = try XCTUnwrap(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))

        XCTAssertLessThan(outside.redComponent, 0.6)
        XCTAssertEqual(inside.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(inside.greenComponent, 1, accuracy: 0.02)
        XCTAssertEqual(inside.blueComponent, 1, accuracy: 0.02)
    }

    func testAdjustableDimmingChangesOnlyPixelsOutsideHighlight() throws {
        let bounds = NSRect(x: 0, y: 0, width: 20, height: 20)
        let highlight = NSRect(x: 6, y: 6, width: 8, height: 8)
        let dimmingLevels: [CGFloat] = [0, 0.2, 0.75]

        for alpha in dimmingLevels {
            let rep = try makeWhiteBitmap(width: 20, height: 20)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            SpotlightAnnotation.drawDimmingOverlay(
                highlightRects: [highlight],
                in: context.cgContext,
                bounds: bounds,
                dimmingAlpha: alpha
            )
            context.flushGraphics()

            let outside = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
            let inside = try XCTUnwrap(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(outside.redComponent, 1 - alpha, accuracy: 0.02)
            XCTAssertEqual(inside.redComponent, 1, accuracy: 0.02)
            XCTAssertEqual(inside.greenComponent, 1, accuracy: 0.02)
            XCTAssertEqual(inside.blueComponent, 1, accuracy: 0.02)
        }
    }

    func testSpotlightUsesSmallRoundedCorners() throws {
        let rep = try makeWhiteBitmap(width: 32, height: 32)
        let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        SpotlightAnnotation(rect: NSRect(x: 6, y: 6, width: 20, height: 20))
            .draw(
                in: graphicsContext.cgContext,
                bounds: NSRect(x: 0, y: 0, width: 32, height: 32)
            )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let roundedCorner = try XCTUnwrap(rep.colorAt(x: 6, y: 6)?.usingColorSpace(.deviceRGB))
        let highlightCenter = try XCTUnwrap(rep.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))

        XCTAssertLessThan(roundedCorner.redComponent, 0.8)
        XCTAssertEqual(highlightCenter.redComponent, 1, accuracy: 0.02)
    }

    func testMultipleSpotlightsShareOneDimmingLayer() throws {
        let rep = try makeWhiteBitmap(width: 30, height: 10)
        let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        SpotlightAnnotation.drawDimmingOverlay(
            highlightRects: [
                NSRect(x: 2, y: 2, width: 6, height: 6),
                NSRect(x: 22, y: 2, width: 6, height: 6),
            ],
            in: graphicsContext.cgContext,
            bounds: NSRect(x: 0, y: 0, width: 30, height: 10)
        )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let firstHighlight = try XCTUnwrap(rep.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        let secondHighlight = try XCTUnwrap(rep.colorAt(x: 25, y: 5)?.usingColorSpace(.deviceRGB))
        let dimmedGap = try XCTUnwrap(rep.colorAt(x: 15, y: 5)?.usingColorSpace(.deviceRGB))

        XCTAssertEqual(firstHighlight.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(secondHighlight.redComponent, 1, accuracy: 0.02)
        XCTAssertLessThan(dimmedGap.redComponent, 0.6)
    }

    func testSpotlightCanBeSelectedAndTranslated() throws {
        let annotation = SpotlightAnnotation(rect: NSRect(x: 10, y: 20, width: 80, height: 40))

        XCTAssertTrue(annotation.containsPoint(NSPoint(x: 30, y: 30)))
        XCTAssertFalse(annotation.containsPoint(NSPoint(x: 5, y: 5)))

        let translated = try XCTUnwrap(
            annotation.translated(by: NSPoint(x: 7, y: -3)) as? SpotlightAnnotation
        )
        XCTAssertEqual(translated.rect, NSRect(x: 17, y: 17, width: 80, height: 40))
    }

    func testSpotlightOutsideCanvasDimsEntireImage() throws {
        let rep = try makeWhiteBitmap(width: 20, height: 20)
        let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        SpotlightAnnotation(rect: NSRect(x: 30, y: 30, width: 8, height: 8))
            .draw(
                in: graphicsContext.cgContext,
                bounds: NSRect(x: 0, y: 0, width: 20, height: 20)
            )
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let center = try XCTUnwrap(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(center.redComponent, 0.6)
    }

    private func makeWhiteBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
