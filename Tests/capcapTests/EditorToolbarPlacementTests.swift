import AppKit
import XCTest
@testable import capcap

final class EditorToolbarPlacementTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 1_512, height: 982)
    private let toolbarSize = NSSize(width: 720, height: 44)
    private let sideToolbarSize = NSSize(width: 44, height: 300)

    func testScrollControlsStayInsideSelectionNearItsBottom() {
        let selection = NSRect(x: 200, y: 300, width: 800, height: 550)
        let frame = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 220, height: 44)
        )
        XCTAssertTrue(selection.contains(frame))
        XCTAssertEqual(frame.midX, selection.midX)
        XCTAssertEqual(frame.minY, selection.minY + 12)
    }

    func testSmallEdgeSelectionKeepsControlsOnScreen() {
        let frame = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            in: bounds, size: NSSize(width: 88, height: 44)
        )
        XCTAssertTrue(bounds.contains(frame))
        XCTAssertEqual(frame.minX, 8)
        XCTAssertFalse(frame.intersects(NSRect(x: 0, y: 0, width: 20, height: 20)))
    }

    func testScrollControlsUseTheSelectedDisplayCoordinates() {
        let display = NSRect(x: -1440, y: 200, width: 1440, height: 900)
        let selection = NSRect(x: -1200, y: 300, width: 600, height: 400)
        let frame = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: display, size: NSSize(width: 220, height: 44)
        )
        XCTAssertTrue(selection.contains(frame))
        XCTAssertEqual(frame.midX, selection.midX)
    }

    func testScrollHintStaysInsideALargeSelection() throws {
        let selection = NSRect(x: 200, y: 300, width: 800, height: 550)
        let controls = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 266, height: 64)
        )
        let hint = try XCTUnwrap(EditorToolbarPlacement.scrollCaptureHintRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 460, height: 34),
            avoiding: controls
        ))

        XCTAssertTrue(selection.contains(hint))
        XCTAssertEqual(hint.midX, selection.midX)
        XCTAssertEqual(hint.maxY, selection.maxY - 12)
        XCTAssertFalse(hint.intersects(controls.insetBy(dx: -8, dy: -8)))
    }

    func testShortSelectionMovesHintOutsideTheControlArea() throws {
        let selection = NSRect(x: 200, y: 300, width: 800, height: 100)
        let controls = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 266, height: 64)
        )
        let hint = try XCTUnwrap(EditorToolbarPlacement.scrollCaptureHintRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 460, height: 34),
            avoiding: controls
        ))

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(hint))
        XCTAssertGreaterThanOrEqual(hint.minY, selection.maxY + 8)
        XCTAssertFalse(hint.intersects(controls.insetBy(dx: -8, dy: -8)))
    }

    func testWideHintForNarrowTopLeftSelectionStaysOnScreen() throws {
        let selection = NSRect(x: 0, y: bounds.maxY - 100, width: 40, height: 100)
        let controls = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 266, height: 64)
        )
        let hintSize = NSSize(width: 420, height: 52)
        let hint = try XCTUnwrap(EditorToolbarPlacement.scrollCaptureHintRect(
            referenceRect: selection, in: bounds, size: hintSize, avoiding: controls
        ))

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(hint))
        XCTAssertEqual(hint.minX, 8)
        XCTAssertEqual(hint.size, hintSize)
        XCTAssertFalse(hint.intersects(controls.insetBy(dx: -8, dy: -8)))
    }

    func testScrollHintAndPreviewUseNegativeDisplayCoordinates() throws {
        let display = NSRect(x: -1440, y: 200, width: 1440, height: 900)
        let selection = NSRect(x: -1200, y: 600, width: 600, height: 400)
        let controls = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: display, size: NSSize(width: 266, height: 64)
        )
        let hint = try XCTUnwrap(EditorToolbarPlacement.scrollCaptureHintRect(
            referenceRect: selection, in: display, size: NSSize(width: 420, height: 34),
            avoiding: controls
        ))
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: display, size: NSSize(width: 128, height: 408),
            avoiding: [hint, controls]
        ))

        XCTAssertTrue(display.insetBy(dx: 8, dy: 8).contains(hint))
        XCTAssertTrue(display.insetBy(dx: 8, dy: 8).contains(preview))
        XCTAssertLessThan(hint.maxX, 0)
        XCTAssertLessThan(preview.maxX, 0)
        XCTAssertFalse(preview.intersects(hint.insetBy(dx: -8, dy: -8)))
        XCTAssertFalse(preview.intersects(controls.insetBy(dx: -8, dy: -8)))
    }

    func testScrollPreviewUsesOtherSideWhenHintBlocksThePreferredSide() throws {
        let selection = NSRect(x: 600, y: 300, width: 400, height: 550)
        let hint = NSRect(x: 990, y: 790, width: 300, height: 40)
        let controls = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 266, height: 64)
        )
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 128, height: 408),
            avoiding: [hint, controls]
        ))

        XCTAssertEqual(preview.maxX, selection.minX - 12)
        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(preview))
        XCTAssertFalse(preview.intersects(hint.insetBy(dx: -8, dy: -8)))
        XCTAssertFalse(preview.intersects(controls.insetBy(dx: -8, dy: -8)))
    }

    func testScrollPreviewFindsAnotherVisiblePositionAtTheScreenEdge() throws {
        let selection = NSRect(x: 1470, y: 400, width: 30, height: 100)
        let controls = EditorToolbarPlacement.scrollCaptureControlRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 266, height: 64)
        )
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: bounds, size: NSSize(width: 128, height: 408),
            avoiding: [controls]
        ))

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(preview))
        XCTAssertFalse(preview.intersects(controls.insetBy(dx: -8, dy: -8)))
        XCTAssertEqual(preview.size, NSSize(width: 128, height: 408))
    }

    func testScrollPreviewMovesInsideTheScreenWhenNeitherSideFits() throws {
        let display = NSRect(x: 0, y: 0, width: 320, height: 240)
        let selection = NSRect(x: 140, y: 100, width: 40, height: 40)
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: display, size: NSSize(width: 128, height: 200),
            avoiding: []
        ))

        XCTAssertTrue(display.insetBy(dx: 8, dy: 8).contains(preview))
        XCTAssertEqual(preview.size, NSSize(width: 128, height: 200))
    }

    func testScrollPreviewUsesVerticalSpaceBeforeShrinking() throws {
        let display = NSRect(x: 0, y: 0, width: 480, height: 600)
        let selection = NSRect(x: 160, y: 220, width: 160, height: 160)
        let obstacles = [
            NSRect(x: 8, y: 190, width: 160, height: 220),
            NSRect(x: 312, y: 190, width: 160, height: 220)
        ]
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: display, size: NSSize(width: 200, height: 160),
            avoiding: obstacles
        ))

        XCTAssertTrue(display.insetBy(dx: 8, dy: 8).contains(preview))
        XCTAssertEqual(preview.size, NSSize(width: 200, height: 160))
        XCTAssertTrue(preview.maxY <= 182 || preview.minY >= 418)
        for obstacle in obstacles {
            XCTAssertFalse(preview.intersects(obstacle.insetBy(dx: -8, dy: -8)))
        }
        let reordered = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: display, size: NSSize(width: 200, height: 160),
            avoiding: Array(obstacles.reversed())
        ))
        XCTAssertEqual(preview, reordered)
    }

    func testScrollPreviewShrinksProportionallyToTheRemainingSpace() throws {
        let display = NSRect(x: 0, y: 0, width: 320, height: 240)
        let obstacle = NSRect(x: 8, y: 88, width: 304, height: 64)
        let originalSize = NSSize(width: 128, height: 200)
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: NSRect(x: 140, y: 100, width: 40, height: 40),
            in: display, size: originalSize, avoiding: [obstacle]
        ))

        XCTAssertTrue(display.insetBy(dx: 8, dy: 8).contains(preview))
        XCTAssertFalse(preview.intersects(obstacle.insetBy(dx: -8, dy: -8)))
        XCTAssertLessThan(preview.height, originalSize.height)
        XCTAssertEqual(preview.width / preview.height, originalSize.width / originalSize.height, accuracy: 0.0001)
    }

    func testScrollPreviewPrefersFullSizeAboveSelectionBeforeCoveringIt() throws {
        let display = NSRect(x: 0, y: 0, width: 320, height: 600)
        let selection = NSRect(x: 8, y: 260, width: 304, height: 40)
        let preview = try XCTUnwrap(EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: selection, in: display, size: NSSize(width: 128, height: 200),
            avoiding: []
        ))

        XCTAssertEqual(preview.size, NSSize(width: 128, height: 200))
        XCTAssertFalse(preview.intersects(selection))
        XCTAssertTrue(display.insetBy(dx: 8, dy: 8).contains(preview))
    }

    func testScrollPreviewIsHiddenOnlyWhenObstaclesFillTheSafeArea() {
        let display = NSRect(x: 0, y: 0, width: 320, height: 240)
        let preview = EditorToolbarPlacement.scrollCapturePreviewRect(
            referenceRect: NSRect(x: 140, y: 100, width: 40, height: 40),
            in: display, size: NSSize(width: 128, height: 200), avoiding: [display]
        )

        XCTAssertNil(preview)
    }

    func testScrollEventAvoidsControlsCoveringTheSelectionCenter() {
        let selection = CGRect(x: 200, y: 300, width: 800, height: 100)
        let controls = CGRect(x: 490, y: 344, width: 220, height: 44)
        let point = EditWindowController.scrollCaptureEventPoint(in: selection, avoiding: controls)
        XCTAssertTrue(selection.contains(point))
        XCTAssertFalse(controls.contains(point))
        XCTAssertEqual(point.y, selection.midY)
    }

    func testScrollEventKeepsCenterWhenControlsAreAwayFromIt() {
        let selection = CGRect(x: -800, y: 100, width: 600, height: 500)
        XCTAssertEqual(EditWindowController.scrollCaptureEventPoint(in: selection, avoiding: nil),
                       CGPoint(x: selection.midX, y: selection.midY))
    }

    func testPrimaryToolbarReservesTopSafeInsetWhenSelectionFillsScreen() {
        let rect = EditorToolbarPlacement.primaryToolbarRect(
            referenceRect: bounds,
            in: bounds,
            size: toolbarSize,
            topSafeInset: 38
        )

        XCTAssertEqual(rect.maxY, bounds.maxY - 38 - 8, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, bounds.maxX - 8, accuracy: 0.001)
    }

    func testPrimaryToolbarRightAlignsWithSelection() {
        let selection = NSRect(x: 200, y: 300, width: 900, height: 500)
        let rect = EditorToolbarPlacement.primaryToolbarRect(
            referenceRect: selection,
            in: bounds,
            size: toolbarSize,
            topSafeInset: 38
        )

        XCTAssertEqual(rect.maxX, selection.maxX, accuracy: 0.001)
    }

    func testPrimaryToolbarKeepsEdgeMarginWithoutTopSafeInset() {
        let rect = EditorToolbarPlacement.primaryToolbarRect(
            referenceRect: bounds,
            in: bounds,
            size: toolbarSize,
            topSafeInset: 0
        )

        XCTAssertEqual(rect.maxY, bounds.maxY - 8, accuracy: 0.001)
    }

    func testPrimaryToolbarBelowSelectionIsUnaffectedByTopSafeInset() {
        let selection = NSRect(x: 200, y: 300, width: 900, height: 500)
        let rect = EditorToolbarPlacement.primaryToolbarRect(
            referenceRect: selection,
            in: bounds,
            size: toolbarSize,
            topSafeInset: 38
        )

        XCTAssertEqual(rect.maxY, selection.minY - 8, accuracy: 0.001)
    }

    func testSideToolbarBottomAlignsWithSelection() {
        let selection = NSRect(x: 200, y: 300, width: 900, height: 500)
        let rect = EditorToolbarPlacement.sideToolbarRect(
            referenceRect: selection,
            in: bounds,
            size: sideToolbarSize
        )

        XCTAssertEqual(rect.minX, selection.maxX + 8, accuracy: 0.001)
        XCTAssertEqual(rect.minY, selection.minY, accuracy: 0.001)
    }

    func testSideToolbarKeepsBottomScreenMargin() {
        let selection = NSRect(x: 200, y: 0, width: 900, height: 500)
        let rect = EditorToolbarPlacement.sideToolbarRect(
            referenceRect: selection,
            in: bounds,
            size: sideToolbarSize
        )

        XCTAssertEqual(rect.minY, bounds.minY + 8, accuracy: 0.001)
    }
}
