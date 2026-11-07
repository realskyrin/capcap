import XCTest
@testable import capcap

final class CopyToastSettingsTests: XCTestCase {
    func testShowCopyToastDefaultsOnAndPersistsExplicitValue() {
        let key = "showCopyToast"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // Defaults on, matching the pre-setting behavior.
        XCTAssertTrue(Defaults.showCopyToast)

        Defaults.showCopyToast = false
        XCTAssertFalse(Defaults.showCopyToast)

        Defaults.showCopyToast = true
        XCTAssertTrue(Defaults.showCopyToast)
    }
}
