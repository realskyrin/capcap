import AppKit
import XCTest
@testable import capcap

@MainActor
final class ScrollCaptureCropAnnotationTests: XCTestCase {
    func testTopTrimKeepsMagnifiedPixelsAtTheSameDocumentLocation() throws {
        let original = try makeImage(height: 200, greenBand: 50..<70, backingScale: 2)
        let canvas = try makeCanvas(
            image: original,
            center: NSPoint(x: 60, y: 60)
        )
        let cropRect = NSRect(x: 0, y: 0, width: 120, height: 140)
        let cropped = try crop(original, to: cropRect)

        canvas.trimScrollCapture(to: cropped, imageRect: cropRect)

        let lens = try XCTUnwrap(canvas.selectedAnnotation as? MagnifierAnnotation)
        XCTAssertEqual(lens.center, NSPoint(x: 60, y: 60))
        XCTAssertNil(lens.sourceCenter)
        XCTAssertTrue(lens.sourceImage === cropped)
        try assertGreenLens(in: canvas, at: lens.center)
    }

    func testTrimMovesDetachedSourceWithTheDocument() throws {
        let original = try makeImage(height: 200, greenBand: 50..<70)
        let canvas = try makeCanvas(
            image: original,
            center: NSPoint(x: 90, y: 120),
            sourceCenter: NSPoint(x: 30, y: 60)
        )
        let cropRect = NSRect(x: 0, y: 40, width: 120, height: 140)
        let cropped = try crop(original, to: cropRect)

        canvas.trimScrollCapture(to: cropped, imageRect: cropRect)

        let lens = try XCTUnwrap(canvas.selectedAnnotation as? MagnifierAnnotation)
        XCTAssertEqual(lens.center, NSPoint(x: 90, y: 80))
        XCTAssertEqual(lens.sourceCenter, NSPoint(x: 30, y: 20))
        XCTAssertTrue(lens.sourceImage === cropped)
        try assertGreenLens(in: canvas, at: lens.center)
    }

    func testTrimUndoRedoRestoresBitmapAndBothMagnifierCoordinates() throws {
        let original = try makeImage(height: 200, greenBand: 50..<70)
        let canvas = try makeCanvas(
            image: original,
            center: NSPoint(x: 90, y: 120),
            sourceCenter: NSPoint(x: 30, y: 60)
        )
        let cropRect = NSRect(x: 0, y: 40, width: 120, height: 140)
        let cropped = try crop(original, to: cropRect)
        canvas.trimScrollCapture(to: cropped, imageRect: cropRect)

        XCTAssertTrue(canvas.undo())
        let restored = try XCTUnwrap(canvas.selectedAnnotation as? MagnifierAnnotation)
        XCTAssertTrue(canvas.previewImage === original)
        XCTAssertEqual(canvas.bounds.size, original.size)
        XCTAssertTrue(restored.sourceImage === original)
        XCTAssertEqual(restored.center, NSPoint(x: 90, y: 120))
        XCTAssertEqual(restored.sourceCenter, NSPoint(x: 30, y: 60))
        try assertGreenLens(in: canvas, at: restored.center)

        XCTAssertTrue(canvas.redo())
        let redone = try XCTUnwrap(canvas.selectedAnnotation as? MagnifierAnnotation)
        XCTAssertTrue(canvas.previewImage === cropped)
        XCTAssertEqual(canvas.bounds.size, cropped.size)
        XCTAssertTrue(redone.sourceImage === cropped)
        XCTAssertEqual(redone.center, NSPoint(x: 90, y: 80))
        XCTAssertEqual(redone.sourceCenter, NSPoint(x: 30, y: 20))
        try assertGreenLens(in: canvas, at: redone.center)
    }

    func testLoadingLongCaptureRemapsMagnifierAndItsHistory() throws {
        let original = try makeImage(height: 200, greenBand: 50..<70)
        let canvas = try makeCanvas(
            image: original,
            center: NSPoint(x: 90, y: 120),
            sourceCenter: NSPoint(x: 30, y: 60)
        )
        canvas.mutateSelectedAnnotationAtomic { annotation in
            guard let lens = annotation as? MagnifierAnnotation else { return annotation }
            return lens.withZoom(3)
        }
        let longImage = try makeImage(height: 400, greenBand: 250..<270)

        canvas.loadScrollCaptureImage(longImage)

        for (index, expectedZoom) in [CGFloat(3), 2, 3].enumerated() {
            let lens = try XCTUnwrap(canvas.selectedAnnotation as? MagnifierAnnotation)
            XCTAssertEqual(lens.zoom, expectedZoom)
            XCTAssertEqual(lens.center, NSPoint(x: 90, y: 320))
            XCTAssertEqual(lens.sourceCenter, NSPoint(x: 30, y: 260))
            XCTAssertTrue(lens.sourceImage === longImage)
            XCTAssertEqual(canvas.bounds.size, longImage.size)
            try assertGreenLens(in: canvas, at: lens.center)
            if index == 0 {
                XCTAssertTrue(canvas.undo())
            } else if index == 1 {
                XCTAssertTrue(canvas.redo())
            }
        }
    }

    private func makeCanvas(
        image: NSImage,
        center: NSPoint,
        sourceCenter: NSPoint? = nil
    ) throws -> EditCanvasView {
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: image.size))
        canvas.loadPreviewImage(image)
        XCTAssertTrue(canvas.insertEmoji("🎯"))
        canvas.mutateSelectedAnnotationAtomic { _ in
            MagnifierAnnotation(
                center: center, radius: 18, color: .black, lineWidth: 1,
                zoom: 2, sourceImage: image, sourceCenter: sourceCenter
            )
        }
        return canvas
    }

    private func makeImage(
        height: Int,
        greenBand: Range<Int>,
        backingScale: Int = 1
    ) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 120 * backingScale,
            pixelsHigh: height * backingScale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 120, height: height)
        for y in 0..<bitmap.pixelsHigh {
            let canvasY = height - 1 - y / backingScale
            let color = greenBand.contains(canvasY) ? NSColor.green : NSColor.red
            for x in 0..<bitmap.pixelsWide {
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func crop(_ image: NSImage, to rect: NSRect) throws -> NSImage {
        let cgImage = try XCTUnwrap(image.cgImagePreservingBacking())
        let scale = CGFloat(cgImage.height) / image.size.height
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: rect.minX * scale,
            y: (image.size.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )))
        return NSImage(cgImage: cropped, size: rect.size)
    }

    private func assertGreenLens(
        in canvas: EditCanvasView,
        at point: NSPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let image = try XCTUnwrap(canvas.compositeImage(fallbackBaseImage: nil), file: file, line: line)
        let cgImage = try XCTUnwrap(image.cgImagePreservingBacking(), file: file, line: line)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let x = Int(point.x * CGFloat(cgImage.width) / image.size.width)
        let y = Int((image.size.height - point.y) * CGFloat(cgImage.height) / image.size.height)
        let color = try XCTUnwrap(
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            file: file, line: line
        )
        XCTAssertGreaterThan(color.greenComponent, 0.9, file: file, line: line)
        XCTAssertLessThan(color.redComponent, 0.1, file: file, line: line)
    }
}
