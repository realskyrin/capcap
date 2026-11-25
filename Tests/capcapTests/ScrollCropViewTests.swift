import AppKit
import XCTest
@testable import capcap

@MainActor
final class ScrollCropViewTests: XCTestCase {
    func testHoveringEachHandleUpdatesCursorBeforeMouseDown() throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        let view = try makePaddedView(size: NSSize(width: 200, height: 400))
        let window = makeWindow(for: view)
        defer { window.orderOut(nil) }

        for (index, handle) in SelectionView.HandlePosition.allCases.enumerated() {
            let rect = view.handleRects[index]
            for type in [NSEvent.EventType.mouseEntered, .cursorUpdate] {
                let event = try XCTUnwrap(NSEvent.enterExitEvent(
                    with: type,
                    location: view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
                ))
                NSCursor.arrow.set()
                if type == .mouseEntered {
                    view.mouseEntered(with: event)
                } else {
                    view.cursorUpdate(with: event)
                }
                XCTAssertEqual(NSCursor.current, SelectionView.cursorForHandle(handle),
                               "悬停在 \(handle) 时不应等待点击才改变光标")
            }
        }
    }

    func testCropUsesScreenshotGreenHandlesAndContinuousBorder() throws {
        let view = try makePaddedView(size: NSSize(width: 100, height: 200))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 124, pixelsHigh: 224,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(view.bounds)
        view.draw(view.bounds)
        graphics.flushGraphics()

        let green = try XCTUnwrap(SelectionView.selectionColor.usingColorSpace(.deviceRGB))
        // 连续取边框上的像素可区分实线与虚线，同时确认控制点不再有白色圆心
        let points = (32..<52).map { NSPoint(x: $0, y: 12) }
            + view.handleRects.map { NSPoint(x: $0.midX, y: $0.midY) }
        for point in points {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: 223 - Int(point.y))?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, green.redComponent, accuracy: 0.02)
            XCTAssertEqual(color.greenComponent, green.greenComponent, accuracy: 0.02)
            XCTAssertEqual(color.blueComponent, green.blueComponent, accuracy: 0.02)
            XCTAssertGreaterThan(color.alphaComponent, 0.98)
        }
        let outsideImage = try XCTUnwrap(bitmap.colorAt(x: 4, y: 100))
        XCTAssertEqual(outsideImage.alphaComponent, 0, accuracy: 0.001)
    }

    func testEveryHandleResizesItsOwnEdgesWithoutInitialJump() throws {
        _ = NSApplication.shared
        let cases: [(SelectionView.HandlePosition, NSPoint, NSRect)] = [
            (.topLeft, NSPoint(x: 20, y: -30), NSRect(x: 10, y: 0, width: 90, height: 185)),
            (.topRight, NSPoint(x: -20, y: -30), NSRect(x: 0, y: 0, width: 90, height: 185)),
            (.bottomLeft, NSPoint(x: 20, y: 30), NSRect(x: 10, y: 15, width: 90, height: 185)),
            (.bottomRight, NSPoint(x: -20, y: 30), NSRect(x: 0, y: 15, width: 90, height: 185)),
            (.topCenter, NSPoint(x: 0, y: -30), NSRect(x: 0, y: 0, width: 100, height: 185)),
            (.bottomCenter, NSPoint(x: 0, y: 30), NSRect(x: 0, y: 15, width: 100, height: 185)),
            (.leftCenter, NSPoint(x: 20, y: 0), NSRect(x: 10, y: 0, width: 90, height: 200)),
            (.rightCenter, NSPoint(x: -20, y: 0), NSRect(x: 0, y: 0, width: 90, height: 200)),
        ]
        for (handle, delta, expected) in cases {
            let view = try makePaddedView(size: NSSize(width: 200, height: 400))
            let window = makeWindow(for: view)
            defer { window.orderOut(nil) }
            try drag(handle, on: view, by: delta, window: window)
            assertRect(view.cropRect, equals: expected)
        }
    }

    func testFourEdgesAlignToRetinaSourcePixels() throws {
        _ = NSApplication.shared
        let view = try makePaddedView(size: NSSize(width: 100, height: 200))
        let window = makeWindow(for: view)
        defer { window.orderOut(nil) }
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.isFlipped)
        try drag(.leftCenter, on: view, by: NSPoint(x: 5.3, y: 0), window: window)
        try drag(.rightCenter, on: view, by: NSPoint(x: -7.3, y: 0), window: window)
        try drag(.bottomCenter, on: view, by: NSPoint(x: 0, y: 9.3), window: window)
        try drag(.topCenter, on: view, by: NSPoint(x: 0, y: -11.3), window: window)
        assertRect(view.cropRect, equals: NSRect(x: 5.5, y: 9.5, width: 87, height: 179))
    }

    func testAllEightHandleCentersStayOnSelectionBoundaryAndInsideOverlay() throws {
        _ = NSApplication.shared
        let view = try makePaddedView(size: NSSize(width: 200, height: 400))
        let window = makeWindow(for: view)
        defer { window.orderOut(nil) }
        XCTAssertEqual(view.handleRects.count, 8)
        assertHandles(on: view.imageRect, view: view)
        XCTAssertLessThan(view.handleRects[0].minX, view.imageRect.minX)
        XCTAssertGreaterThan(view.handleRects[0].maxY, view.imageRect.maxY)
        try drag(.bottomLeft, on: view, by: NSPoint(x: 20, y: 30), window: window)
        assertHandles(on: NSRect(x: 32, y: 42, width: 180, height: 370), view: view)

        view.imageRect = NSRect(x: 12, y: 12, width: 1, height: 2)
        assertHandles(on: NSRect(x: 12.1, y: 12.15, width: 0.9, height: 1.85), view: view)
        let unchanged = view.cropRect
        try drag(.topRight, on: view, by: .zero, window: window)
        assertRect(view.cropRect, equals: unchanged)
    }

    func testRotatedCropPreservesBothAxesWhenOverlayResizes() throws {
        _ = NSApplication.shared
        let view = try makePaddedView(size: NSSize(width: 400, height: 200), rotation: .left)
        let window = makeWindow(for: view)
        defer { window.orderOut(nil) }
        assertRect(view.cropRect, equals: NSRect(x: 0, y: 0, width: 200, height: 100))
        try drag(.bottomLeft, on: view, by: NSPoint(x: 51.3, y: 25.3), window: window)
        try drag(.topRight, on: view, by: NSPoint(x: -49.3, y: -23.3), window: window)
        assertRect(view.cropRect, equals: NSRect(x: 25.5, y: 12.5, width: 150, height: 76))
        let crop = view.cropRect
        view.setFrameSize(NSSize(width: 200, height: 400))
        assertRect(view.cropRect, equals: crop)
        XCTAssertEqual(view.imageRect, NSRect(x: 12, y: 12, width: 400, height: 200))
        view.imageRect = NSRect(x: 12, y: 12, width: 176, height: 376)
        assertRect(view.cropRect, equals: crop)
        assertHandles(on: NSRect(x: 34.572, y: 59.564, width: 131.736, height: 284.632), view: view)
    }

    func testDefaultImageRectTracksOverlayResizeWithoutChangingCrop() throws {
        _ = NSApplication.shared
        let view = ScrollCropView(frame: NSRect(x: 0, y: 0, width: 100, height: 200), image: try makeImage())
        let window = makeWindow(for: view)
        defer { window.orderOut(nil) }
        try drag(.bottomLeft, on: view, by: NSPoint(x: 10, y: 20), window: window)
        let crop = view.cropRect

        view.setFrameSize(NSSize(width: 200, height: 400))

        XCTAssertEqual(view.imageRect, view.bounds)
        assertRect(view.cropRect, equals: crop)
    }

    func testCornersCannotInvertOrEscapeImageBounds() throws {
        _ = NSApplication.shared
        let cases: [(SelectionView.HandlePosition, NSPoint)] = [
            (.topLeft, NSPoint(x: 1_000, y: -1_000)),
            (.topRight, NSPoint(x: -1_000, y: -1_000)),
            (.bottomLeft, NSPoint(x: 1_000, y: 1_000)),
            (.bottomRight, NSPoint(x: -1_000, y: 1_000)),
        ]
        for (handle, delta) in cases {
            let view = try makePaddedView(size: NSSize(width: 100, height: 200))
            let window = makeWindow(for: view)
            defer { window.orderOut(nil) }
            try drag(handle, on: view, by: delta, window: window)
            XCTAssertGreaterThanOrEqual(view.cropRect.width, 0.5)
            XCTAssertGreaterThanOrEqual(view.cropRect.height, 0.5)
            XCTAssertGreaterThanOrEqual(view.cropRect.minX, 0)
            XCTAssertGreaterThanOrEqual(view.cropRect.minY, 0)
            XCTAssertLessThanOrEqual(view.cropRect.maxX, 100)
            XCTAssertLessThanOrEqual(view.cropRect.maxY, 200)
            for rect in view.handleRects {
                XCTAssertTrue(view.bounds.contains(rect))
            }
        }
    }

    private func assertHandles(on rect: NSRect, view: ScrollCropView,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(view.handleRects.count, 8, file: file, line: line)
        let centers = SelectionView.handlePositions(for: rect)
        for (index, handle) in view.handleRects.enumerated() {
            XCTAssertGreaterThan(handle.width, 0, file: file, line: line)
            XCTAssertGreaterThan(handle.height, 0, file: file, line: line)
            XCTAssertEqual(handle.midX, centers[index].x, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(handle.midY, centers[index].y, accuracy: 0.0001, file: file, line: line)
            XCTAssertTrue(view.bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(handle), file: file, line: line)
        }
    }

    private func makePaddedView(size: NSSize, rotation: ImageRotation = .none) throws -> ScrollCropView {
        ScrollCropView(
            frame: NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 24),
            image: try makeImage(),
            rotation: rotation,
            imageRect: NSRect(x: 12, y: 12, width: size.width, height: size.height)
        )
    }

    private func assertRect(_ actual: NSRect, equals expected: NSRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

    private func makeImage() throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 100, height: 200)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeWindow(for view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = view
        return window
    }

    private func drag(_ handle: SelectionView.HandlePosition, on view: ScrollCropView,
                      by delta: NSPoint, window: NSWindow) throws {
        let index = try XCTUnwrap(SelectionView.HandlePosition.allCases.firstIndex(of: handle))
        let rect = view.handleRects[index]
        let start = NSPoint(x: rect.midX, y: rect.midY)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let original = view.cropRect
        view.mouseDown(with: event(.leftMouseDown, at: start))
        view.mouseDragged(with: event(.leftMouseDragged, at: start))
        assertRect(view.cropRect, equals: original)
        view.mouseDragged(with: event(.leftMouseDragged, at: end))
        view.mouseUp(with: event(.leftMouseUp, at: end))
    }
}
