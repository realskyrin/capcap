import AppKit
import XCTest
@testable import capcap

@MainActor
final class SelectionViewModifierMoveTests: XCTestCase {
    private let enabledKey = "selectionMoveModifierEnabled"
    private let modifierKey = "selectionMoveModifier"
    private var previousEnabledValue: Any?
    private var previousModifierValue: Any?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousEnabledValue = UserDefaults.standard.object(forKey: enabledKey)
        previousModifierValue = UserDefaults.standard.object(forKey: modifierKey)
        Defaults.selectionMoveModifierEnabled = true
        Defaults.selectionMoveModifier = .command
    }

    override func tearDown() {
        restore(previousEnabledValue, forKey: enabledKey)
        restore(previousModifierValue, forKey: modifierKey)
        super.tearDown()
    }

    func testNoModifierLeavesEditorSelectionUnchanged() throws {
        let fixture = makeFixture()

        try drag(fixture.view, from: NSPoint(x: 80, y: 80), to: NSPoint(x: 110, y: 100))

        XCTAssertEqual(fixture.view.currentSelectionRect, fixture.initialRect)
        XCTAssertEqual(fixture.delegate.changeCount, 0)
    }

    func testCommandMovesSelectionAndContinuesAfterModifierRelease() throws {
        let fixture = makeFixture()

        try drag(
            fixture.view,
            from: NSPoint(x: 80, y: 80),
            to: NSPoint(x: 110, y: 100),
            downFlags: .command,
            dragFlags: []
        )

        XCTAssertEqual(
            fixture.view.currentSelectionRect,
            fixture.initialRect.offsetBy(dx: 30, dy: 20)
        )
        XCTAssertEqual(fixture.delegate.changeCount, 1)
        XCTAssertEqual(fixture.delegate.completionCount, 1)
    }

    func testOptionConfigurationRejectsCommandAndAcceptsOption() throws {
        Defaults.selectionMoveModifier = .option
        let fixture = makeFixture()

        try drag(
            fixture.view,
            from: NSPoint(x: 80, y: 80),
            to: NSPoint(x: 100, y: 90),
            downFlags: .command
        )
        XCTAssertEqual(fixture.view.currentSelectionRect, fixture.initialRect)

        try drag(
            fixture.view,
            from: NSPoint(x: 80, y: 80),
            to: NSPoint(x: 100, y: 90),
            downFlags: .option
        )
        XCTAssertEqual(
            fixture.view.currentSelectionRect,
            fixture.initialRect.offsetBy(dx: 20, dy: 10)
        )
    }

    func testModifierMoveClampsSelectionToScreenBounds() throws {
        let fixture = makeFixture()

        try drag(
            fixture.view,
            from: NSPoint(x: 80, y: 80),
            to: NSPoint(x: 500, y: 500),
            downFlags: .command
        )

        XCTAssertEqual(
            fixture.view.currentSelectionRect,
            NSRect(x: 200, y: 160, width: 100, height: 80)
        )
    }

    private func makeFixture() -> (view: SelectionView, delegate: SelectionDelegateSpy, initialRect: NSRect) {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let initialRect = NSRect(x: 50, y: 50, width: 100, height: 80)
        let delegate = SelectionDelegateSpy()
        view.delegate = delegate
        view.updateSelectionRect(initialRect)
        view.annotationToolActive = true
        view.selectionLocked = true
        view.selectionInteractionEnabled = true
        return (view, delegate, initialRect)
    }

    private func drag(
        _ view: SelectionView,
        from start: NSPoint,
        to end: NSPoint,
        downFlags: NSEvent.ModifierFlags = [],
        dragFlags: NSEvent.ModifierFlags? = nil
    ) throws {
        view.mouseDown(with: try mouseEvent(type: .leftMouseDown, point: start, flags: downFlags))
        view.mouseDragged(with: try mouseEvent(
            type: .leftMouseDragged,
            point: end,
            flags: dragFlags ?? downFlags
        ))
        view.mouseUp(with: try mouseEvent(type: .leftMouseUp, point: end, flags: dragFlags ?? downFlags))
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        point: NSPoint,
        flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private final class SelectionDelegateSpy: SelectionViewDelegate {
    private(set) var changeCount = 0
    private(set) var completionCount = 0

    func selectionDidStart() {}

    func selectionDidComplete(
        rect: NSRect,
        inView view: NSView,
        isWindowSelection: Bool,
        windowID: CGWindowID?
    ) {
        completionCount += 1
    }

    func selectionDidChange(rect: NSRect, inView view: NSView) {
        changeCount += 1
    }
}
