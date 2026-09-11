import Foundation
import XCTest
@testable import capcap

final class UpdateCheckerPreferencesTests: XCTestCase {
    private let enabledKey = "automaticUpdateChecksEnabled"
    private let triggerDayKey = "automaticUpdateCheckShortcutTriggerDay"
    private let triggerCountKey = "automaticUpdateCheckShortcutTriggerCount"
    private let throttleKey = "lastUpdateCheckAt"
    private var previousValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [enabledKey, triggerDayKey, triggerCountKey, throttleKey] {
            previousValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in [enabledKey, triggerDayKey, triggerCountKey, throttleKey] {
            if let value = previousValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testAutomaticUpdateChecksDefaultToEnabled() {
        XCTAssertTrue(Defaults.automaticUpdateChecksEnabled)
    }

    func testDisabledAutomaticUpdateChecksDoNotAdvanceShortcutGate() {
        Defaults.automaticUpdateChecksEnabled = false
        UserDefaults.standard.set("sentinel-day", forKey: triggerDayKey)
        UserDefaults.standard.set(7, forKey: triggerCountKey)
        UserDefaults.standard.set(Date(), forKey: throttleKey)

        UpdateChecker.shared.checkFromScreenshotShortcutIfDue()

        XCTAssertEqual(UserDefaults.standard.string(forKey: triggerDayKey), "sentinel-day")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: triggerCountKey), 7)
    }
}
