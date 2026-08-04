import AppKit
import XCTest
@testable import capcap

@MainActor
final class EditCanvasCursorTests: XCTestCase {
    func testDrawingToolsHideCursorFromMouseDownUntilMouseUp() throws {
        _ = NSApplication.shared
        let tools: [EditTool] = [.line, .ellipse, .rectangle, .arrow, .pen, .marker]

        for tool in tools {
            let canvas = EditCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            let window = NSWindow(
                contentRect: canvas.bounds,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = canvas
            canvas.activeTool = tool

            canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown))
            XCTAssertTrue(canvas.isCursorHiddenForDrawing, "Expected \(tool) to hide the cursor")

            canvas.mouseUp(with: try mouseEvent(type: .leftMouseUp))
            XCTAssertFalse(canvas.isCursorHiddenForDrawing, "Expected \(tool) to restore the cursor")
        }
    }

    func testSwitchingToolsRestoresCursorDuringDrawing() throws {
        _ = NSApplication.shared
        let canvas = EditCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(
            contentRect: canvas.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        canvas.activeTool = .arrow
        canvas.mouseDown(with: try mouseEvent(type: .leftMouseDown))
        XCTAssertTrue(canvas.isCursorHiddenForDrawing)

        canvas.activeTool = .none

        XCTAssertFalse(canvas.isCursorHiddenForDrawing)
    }

    private func mouseEvent(type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 120, y: 100),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
