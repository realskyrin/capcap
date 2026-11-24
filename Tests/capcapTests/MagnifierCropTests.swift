import AppKit
import XCTest
@testable import capcap

@MainActor
final class MagnifierCropTests: XCTestCase {
    func testRepeatedCropPreservesDefaultAndOutsideSourcePixels() throws {
        // 图像为画布的两倍，覆盖缩放下的取样坐标换算
        let image = NSImage(size: NSSize(width: 480, height: 480))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 480).fill()
        NSColor.blue.setFill()
        NSRect(x: 240, y: 0, width: 240, height: 480).fill()
        image.unlockFocus()

        for sourceCenter in [nil, NSPoint(x: 30, y: 120)] as [NSPoint?] {
            let original = MagnifierAnnotation(
                center: NSPoint(x: 180, y: 120), radius: 16,
                color: .black, lineWidth: 1, zoom: 2,
                sourceImage: image, sourceCenter: sourceCenter
            )
            let cropped = original.translatedForCrop(
                by: NSPoint(x: -100, y: -60),
                originalCanvasBounds: NSRect(x: 0, y: 0, width: 240, height: 240)
            ).translatedForCrop(
                by: NSPoint(x: -20, y: -30),
                originalCanvasBounds: NSRect(x: 0, y: 0, width: 140, height: 180)
            )

            XCTAssertTrue(cropped.sourceImage === image)
            XCTAssertEqual(cropped.center, NSPoint(x: 60, y: 30))
            XCTAssertEqual(cropped.sourceCanvasBounds, NSRect(x: -120, y: -90, width: 240, height: 240))
            XCTAssertEqual(cropped.sourceCenter, sourceCenter.map { NSPoint(x: $0.x - 120, y: $0.y - 90) })
            let color = try centerColor(
                of: cropped,
                bounds: NSRect(x: 0, y: 0, width: 120, height: 150)
            )
            // 显式取样点已在裁剪区外，镜片仍应显示原红色区域
            if sourceCenter == nil {
                XCTAssertGreaterThan(color.blueComponent, 0.9)
                XCTAssertLessThan(color.redComponent, 0.1)
            } else {
                XCTAssertGreaterThan(color.redComponent, 0.9)
                XCTAssertLessThan(color.blueComponent, 0.1)
            }
        }
    }

    func testEditingCroppedMagnifierKeepsSourceMappingAndMoveSemantics() throws {
        let cropped = MagnifierAnnotation(
            center: NSPoint(x: 100, y: 100), radius: 16,
            color: .black, lineWidth: 1, zoom: 2,
            sourceImage: NSImage(size: NSSize(width: 200, height: 200)),
            sourceCenter: NSPoint(x: 20, y: 40)
        ).translatedForCrop(
            by: NSPoint(x: -10, y: -30),
            originalCanvasBounds: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        let moved = try XCTUnwrap(cropped.translated(by: NSPoint(x: 5, y: 6)) as? MagnifierAnnotation)
        let dragged = cropped.translatedPreservingSourceFocus(by: NSPoint(x: 5, y: 6))
        let copies = [
            moved, dragged, cropped.withRadius(24), cropped.withZoom(3),
            cropped.withSourceCenter(nil),
            try XCTUnwrap(cropped.withColor(.green) as? MagnifierAnnotation),
            try XCTUnwrap(cropped.withLineWidth(4) as? MagnifierAnnotation),
        ]
        for copy in copies {
            XCTAssertEqual(copy.sourceCanvasBounds, cropped.sourceCanvasBounds)
            XCTAssertTrue(copy.sourceImage === cropped.sourceImage)
        }
        XCTAssertEqual(moved.center, NSPoint(x: 95, y: 76))
        XCTAssertEqual(moved.sourceCenter, cropped.sourceCenter)
        XCTAssertEqual(dragged.sourceCenter, cropped.sourceCenter)
        XCTAssertNil(cropped.withSourceCenter(nil).sourceCenter)
    }

    private func centerColor(of annotation: MagnifierAnnotation, bounds: NSRect) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.translateBy(x: 20 - annotation.center.x, y: 20 - annotation.center.y)
        annotation.draw(in: graphics.cgContext, bounds: bounds)
        graphics.flushGraphics()
        return try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
    }
}
