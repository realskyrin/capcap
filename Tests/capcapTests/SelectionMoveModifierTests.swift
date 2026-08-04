import AppKit
import XCTest
@testable import capcap

final class SelectionMoveModifierTests: XCTestCase {
    private let enabledKey = "selectionMoveModifierEnabled"
    private let modifierKey = "selectionMoveModifier"
    private var previousEnabledValue: Any?
    private var previousModifierValue: Any?

    override func setUp() {
        super.setUp()
        previousEnabledValue = UserDefaults.standard.object(forKey: enabledKey)
        previousModifierValue = UserDefaults.standard.object(forKey: modifierKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: modifierKey)
    }

    override func tearDown() {
        restore(previousEnabledValue, forKey: enabledKey)
        restore(previousModifierValue, forKey: modifierKey)
        super.tearDown()
    }

    func testDefaultsToEnabledCommandModifier() {
        XCTAssertTrue(Defaults.selectionMoveModifierEnabled)
        XCTAssertEqual(Defaults.selectionMoveModifier, .command)
    }

    func testInvalidStoredModifierNormalizesToCommand() {
        UserDefaults.standard.set("capsLock", forKey: modifierKey)

        XCTAssertEqual(Defaults.selectionMoveModifier, .command)
    }

    func testAllModifiersMatchWithOrWithoutExtraModifiers() {
        for modifier in SelectionMoveModifier.allCases {
            Defaults.selectionMoveModifier = modifier
            let expectedFlag = flag(for: modifier)

            XCTAssertTrue(Defaults.matchesSelectionMoveModifier(expectedFlag))
            XCTAssertTrue(Defaults.matchesSelectionMoveModifier([expectedFlag, .capsLock]))
        }
    }

    func testDisabledSettingNeverMatches() {
        Defaults.selectionMoveModifier = .command
        Defaults.selectionMoveModifierEnabled = false

        XCTAssertFalse(Defaults.matchesSelectionMoveModifier(.command))
    }

    private func flag(for modifier: SelectionMoveModifier) -> NSEvent.ModifierFlags {
        switch modifier {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
