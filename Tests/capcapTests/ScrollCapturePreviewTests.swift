import AppKit
import XCTest

@testable import capcap

@MainActor
final class ScrollCapturePreviewTests: XCTestCase {
    func testFullWidthSelectionKeepsPreviewInsideTheScreen() {
        let screen = NSRect(x: 0, y: 25, width: 1512, height: 937)
        let preview = EditWindowController.scrollPreviewFrame(
            anchorRect: NSRect(x: 0, y: 0, width: 1512, height: 982), screenFrame: screen
        )
        XCTAssertTrue(screen.contains(preview))
        XCTAssertEqual(preview.width, 128)
        XCTAssertEqual(preview.height, 408)
    }

    func testPreviewPrefersTheFreeSpaceBesideTheSelection() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let leftSelection = NSRect(x: 100, y: 100, width: 700, height: 600)
        let rightSelection = NSRect(x: 1000, y: 100, width: 400, height: 600)
        XCTAssertGreaterThan(EditWindowController.scrollPreviewFrame(
            anchorRect: leftSelection, screenFrame: screen
        ).minX, leftSelection.maxX)
        XCTAssertLessThan(EditWindowController.scrollPreviewFrame(
            anchorRect: rightSelection, screenFrame: screen
        ).maxX, rightSelection.minX)
    }

    func testPreviewUsesTheCaptureScreenWithANegativeOrigin() {
        let screen = NSRect(x: -1920, y: 80, width: 1920, height: 1040)
        let preview = EditWindowController.scrollPreviewFrame(anchorRect: screen, screenFrame: screen)
        XCTAssertTrue(screen.contains(preview))
        XCTAssertLessThan(preview.maxX, 0)
    }

    func testShortScreenStillContainsTheWholePreview() {
        let screen = NSRect(x: 50, y: 40, width: 240, height: 200)
        let preview = EditWindowController.scrollPreviewFrame(anchorRect: screen, screenFrame: screen)
        XCTAssertTrue(screen.contains(preview))
        XCTAssertGreaterThan(preview.height, 0)
        XCTAssertLessThan(preview.height, 408)
    }

    func testPreviewAndStopControlAreExcludedEvenWhenTheyOverlapTheCapture() {
        _ = NSApplication.shared
        let panels = (0..<4).map { _ in
            NSPanel(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
                    styleMask: .borderless, backing: .buffered, defer: false)
        }
        let excluded = EditWindowController.scrollCaptureExcludedWindowNumbers(
            selectionWindow: panels[0], hintWindow: panels[1],
            previewWindow: panels[2], controlWindow: panels[3]
        )
        XCTAssertEqual(Set(excluded), Set(panels.map { CGWindowID($0.windowNumber) }))
        XCTAssertTrue(excluded.allSatisfy { $0 > 0 })
    }
}
