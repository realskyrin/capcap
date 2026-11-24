import AppKit
import Carbon
import XCTest
@testable import capcap

final class ScrollCaptureKeyStateTests: XCTestCase {
    func testLetterEscapeAndReturnFinishCapture() throws {
        var state = ScrollCaptureKeyState()
        for keyCode in [kVK_ANSI_A, kVK_Escape, kVK_Return] {
            XCTAssertTrue(state.isFinishKey(try event(type: .keyDown, keyCode: keyCode)))
        }
    }

    func testReleasingTheShortcutModifierDoesNotFinishCapture() throws {
        var state = ScrollCaptureKeyState(modifiers: .command)
        XCTAssertFalse(state.isFinishKey(try event(type: .flagsChanged, keyCode: kVK_Command)))
    }

    func testNewModifierPressFinishesButReleaseDoesNot() throws {
        var state = ScrollCaptureKeyState()
        XCTAssertTrue(state.isFinishKey(try event(type: .flagsChanged, keyCode: kVK_Shift, flags: .shift)))
        XCTAssertFalse(state.isFinishKey(try event(type: .flagsChanged, keyCode: kVK_Shift)))
        XCTAssertTrue(state.isFinishKey(try event(type: .flagsChanged, keyCode: kVK_Command, flags: .command)))
    }

    func testCapsLockCanFinishWhenToggledOff() throws {
        var state = ScrollCaptureKeyState(modifiers: .capsLock)
        XCTAssertTrue(state.isFinishKey(try event(type: .flagsChanged, keyCode: kVK_CapsLock)))
    }

    func testKeyReleaseIsNotAnotherFinishRequest() throws {
        var state = ScrollCaptureKeyState()
        XCTAssertFalse(state.isFinishKey(try event(type: .keyUp, keyCode: kVK_ANSI_A)))
    }

    func testSpaceIsReservedForSwitchingInBothDirections() throws {
        var state = ScrollCaptureKeyState()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let space = try event(type: type, keyCode: kVK_Space)
            XCTAssertTrue(ScrollCaptureKeyState.isModeSwitchKey(space))
            XCTAssertFalse(state.isFinishKey(space))
        }
    }

    func testCapsLockDoesNotChangeTheSpaceShortcut() throws {
        let space = try event(type: .keyDown, keyCode: kVK_Space, flags: .capsLock)
        XCTAssertTrue(ScrollCaptureKeyState.isModeSwitchKey(space))
    }

    func testModifiedSpaceKeepsTheExistingFinishBehavior() throws {
        var state = ScrollCaptureKeyState()
        for modifier in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let space = try event(type: .keyDown, keyCode: kVK_Space, flags: modifier)
            XCTAssertFalse(ScrollCaptureKeyState.isModeSwitchKey(space))
            XCTAssertTrue(state.isFinishKey(space))
        }
    }

    private func event(type: NSEvent.EventType, keyCode: Int,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                      timestamp: 1, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: UInt16(keyCode)))
    }
}
