import Foundation
import XCTest
@testable import capcap

final class DoubleTapCommandSequenceTests: XCTestCase {
    private let interval: TimeInterval = 0.5

    /// Press and release ⌘ once, far enough apart in time to be distinct presses.
    private func tapCommand(
        _ sequence: inout DoubleTapCommandSequence,
        at time: TimeInterval,
        option: Bool = false
    ) -> DoubleTapCommandSequence.Outcome {
        _ = sequence.handle(
            commandIsDown: false,
            optionIsDown: option,
            hasDisruptiveModifiers: false,
            at: time,
            interval: interval
        )
        return sequence.handle(
            commandIsDown: true,
            optionIsDown: option,
            hasDisruptiveModifiers: false,
            at: time,
            interval: interval
        )
    }

    func testTwoBareCommandPressesInsideWindowTriggerAScreenshot() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0), .armed)
        XCTAssertEqual(tapCommand(&sequence, at: 10.2), .doubleTap)
    }

    func testSecondPressAfterTheWindowOnlyArms() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0), .armed)
        XCTAssertEqual(tapCommand(&sequence, at: 10.6), .armed)
    }

    func testInterruptionBetweenPressesPreventsTheDoubleTap() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0), .armed)
        sequence.registerInterruption()
        XCTAssertEqual(tapCommand(&sequence, at: 10.2), .armed)
    }

    /// Regression test for the app-switch false positive: ⌘-Tab's Tab keyDown is
    /// consumed by the system app switcher and never reaches the monitor, so the
    /// sequence has to be reset when the frontmost app changes. Without the reset
    /// the single ⌘ press after switching looks like a second press.
    func testResetAfterAppSwitchCancelsThePendingFirstPress() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0), .armed)
        sequence.reset()
        XCTAssertEqual(tapCommand(&sequence, at: 10.2), .armed)
    }

    func testDisruptiveModifierInterruptsTheSequence() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0), .armed)
        _ = sequence.handle(
            commandIsDown: true,
            optionIsDown: false,
            hasDisruptiveModifiers: true,
            at: 10.1,
            interval: interval
        )
        XCTAssertEqual(tapCommand(&sequence, at: 10.2), .armed)
    }

    func testOptionPressPairTriggersTheCountdown() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0, option: true), .armed)
        XCTAssertEqual(tapCommand(&sequence, at: 10.2, option: true), .countdown)
    }

    func testMixedOptionStateIsTreatedAsAFreshFirstPress() {
        var sequence = DoubleTapCommandSequence()

        XCTAssertEqual(tapCommand(&sequence, at: 10.0), .armed)
        XCTAssertEqual(tapCommand(&sequence, at: 10.2, option: true), .armed)
    }
}
