import AppKit
import Carbon
import XCTest
@testable import capcap

final class ScrollCaptureKeyStateTests: XCTestCase {
    func testLetterAndReturnFinishCapture() throws {
        var state = ScrollCaptureKeyState()
        for keyCode in [kVK_ANSI_A, kVK_Return, kVK_Space] {
            XCTAssertTrue(state.isFinishKey(try event(type: .keyDown, keyCode: keyCode)))
        }
    }

    func testEscapeIsReservedForCancellationWithAnyModifier() throws {
        var state = ScrollCaptureKeyState()
        for flags in [NSEvent.ModifierFlags(), .shift, .control, .option, .command, .capsLock] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let escape = try event(type: type, keyCode: kVK_Escape, flags: flags)
                XCTAssertFalse(state.isFinishKey(escape))
            }
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

    private func event(type: NSEvent.EventType, keyCode: Int,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                      timestamp: 1, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: UInt16(keyCode)))
    }
}
