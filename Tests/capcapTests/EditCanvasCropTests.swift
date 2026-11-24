import AppKit
import XCTest
@testable import capcap

@MainActor
final class EditCanvasCropTests: XCTestCase {
    func testCropKeepsAnnotationAndRetinaPixelsAligned() throws {
        let image = try makeImage()
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: image.size))
        canvas.loadPreviewImage(image)
        XCTAssertTrue(canvas.insertEmoji("🎯"))
        let original = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)

        XCTAssertTrue(canvas.cropPreviewImage(to: NSRect(x: 10, y: 20, width: 60, height: 80)))

        let cropped = try XCTUnwrap(canvas.previewImage)
        let pixels = try XCTUnwrap(cropped.cgImagePreservingBacking())
        let annotation = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)
        XCTAssertEqual(cropped.size, NSSize(width: 60, height: 80))
        XCTAssertEqual(canvas.bounds.size, cropped.size)
        XCTAssertEqual(pixels.width, 120)
        XCTAssertEqual(pixels.height, 160)
        XCTAssertEqual(annotation.rect, original.rect.offsetBy(dx: -10, dy: -20))
    }

    func testUndoRedoRestoresCropImageSizeAndAnnotation() throws {
        let image = try makeImage()
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: image.size))
        canvas.loadPreviewImage(image)
        XCTAssertTrue(canvas.insertEmoji("🎯"))
        let original = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)
        XCTAssertTrue(canvas.cropPreviewImage(to: NSRect(x: 10, y: 20, width: 60, height: 80)))
        let cropped = try XCTUnwrap(canvas.previewImage)

        XCTAssertTrue(canvas.undo())
        XCTAssertTrue(canvas.previewImage === image)
        XCTAssertEqual(canvas.bounds.size, image.size)
        XCTAssertEqual((canvas.selectedAnnotation as? EmojiAnnotation)?.rect, original.rect)

        XCTAssertTrue(canvas.redo())
        XCTAssertTrue(canvas.previewImage === cropped)
        XCTAssertEqual(canvas.bounds.size, cropped.size)
        XCTAssertEqual((canvas.selectedAnnotation as? EmojiAnnotation)?.rect,
                       original.rect.offsetBy(dx: -10, dy: -20))
    }

    func testRepeatedCropsUndoWithoutRewritingOlderAnnotationCoordinates() throws {
        let image = try makeImage()
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: image.size))
        canvas.loadPreviewImage(image)
        XCTAssertTrue(canvas.insertEmoji("🎯"))
        let original = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)
        XCTAssertTrue(canvas.cropPreviewImage(to: NSRect(x: 10, y: 20, width: 60, height: 80)))
        let firstCrop = try XCTUnwrap(canvas.previewImage)
        XCTAssertTrue(canvas.cropPreviewImage(to: NSRect(x: 5, y: 15, width: 50, height: 60)))
        XCTAssertEqual((canvas.selectedAnnotation as? EmojiAnnotation)?.rect,
                       original.rect.offsetBy(dx: -15, dy: -35))

        XCTAssertTrue(canvas.undo())
        XCTAssertTrue(canvas.previewImage === firstCrop)
        XCTAssertEqual((canvas.selectedAnnotation as? EmojiAnnotation)?.rect,
                       original.rect.offsetBy(dx: -10, dy: -20))
        XCTAssertTrue(canvas.undo())
        XCTAssertTrue(canvas.previewImage === image)
        XCTAssertEqual((canvas.selectedAnnotation as? EmojiAnnotation)?.rect, original.rect)
    }

    func testDisplayedCropMapsToSourceAtEveryRotationAndZoom() throws {
        let cases: [(ImageRotation, NSRect, NSRect)] = [
            (.none, NSRect(x: 0, y: 10, width: 80, height: 80), NSRect(x: 0, y: 10, width: 80, height: 80)),
            (.left, NSRect(x: 0, y: 10, width: 120, height: 50), NSRect(x: 10, y: 0, width: 50, height: 120)),
            (.upsideDown, NSRect(x: 0, y: 10, width: 80, height: 80), NSRect(x: 0, y: 30, width: 80, height: 80)),
            (.right, NSRect(x: 0, y: 10, width: 120, height: 50), NSRect(x: 20, y: 0, width: 50, height: 120)),
        ]
        for (rotation, displayedCrop, sourceCrop) in cases {
            let image = try makeImage()
            let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: image.size))
            canvas.loadPreviewImage(image)
            XCTAssertTrue(canvas.insertEmoji("🎯"))
            let original = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)
            for _ in 0..<rotation.rawValue {
                canvas.rotateImage(clockwise: false)
            }
            // 屏幕缩放不应改变裁剪所使用的图片逻辑坐标
            canvas.setPresentationScale(0.5)
            // 旋转会退出原有选择，重新选中后验证裁剪对当前标注的保留与平移
            XCTAssertTrue(canvas.selectAllAnnotations())

            XCTAssertTrue(canvas.cropPreviewImage(to: displayedCrop), "\(rotation)")

            XCTAssertEqual(canvas.imageRotation, rotation)
            XCTAssertEqual(canvas.previewImage?.size, sourceCrop.size)
            XCTAssertEqual(canvas.bounds.size, sourceCrop.size)
            XCTAssertEqual((canvas.selectedAnnotation as? EmojiAnnotation)?.rect,
                           original.rect.offsetBy(dx: -sourceCrop.minX, dy: -sourceCrop.minY))
        }
    }

    func testEmptyOutsideAndUnchangedCropsLeaveImageAndHistoryUntouched() throws {
        let image = try makeImage()
        let canvas = EditCanvasView(frame: NSRect(origin: .zero, size: image.size))
        XCTAssertFalse(canvas.cropPreviewImage(to: NSRect(x: 0, y: 0, width: 40, height: 40)))
        canvas.loadPreviewImage(image)

        XCTAssertFalse(canvas.cropPreviewImage(to: .zero))
        XCTAssertFalse(canvas.cropPreviewImage(to: NSRect(x: 200, y: 200, width: 40, height: 40)))
        XCTAssertTrue(canvas.cropPreviewImage(to: NSRect(origin: .zero, size: image.size)))

        XCTAssertTrue(canvas.previewImage === image)
        XCTAssertEqual(canvas.bounds.size, image.size)
        XCTAssertFalse(canvas.canUndo)
        XCTAssertFalse(canvas.canRedo)
    }

    private func makeImage() throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 160,
            pixelsHigh: 240,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 80, height: 120)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}
