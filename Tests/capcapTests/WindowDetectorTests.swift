import CoreGraphics
import XCTest
@testable import capcap

final class WindowDetectorTests: XCTestCase {
    func testWindowAtSelectsPopupMenuAboveAppWindow() {
        let detector = WindowDetector()
        detector.apply([
            DetectedWindow(
                name: "Menu",
                windowID: 100,
                layer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                frame: CGRect(x: 80, y: 90, width: 240, height: 320)
            ),
            DetectedWindow(
                name: "Editor",
                windowID: 200,
                layer: 0,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400)
            )
        ])

        let detected = detector.windowAt(cgPoint: CGPoint(x: 90, y: 100))

        XCTAssertEqual(detected?.windowID, 100)
        XCTAssertTrue(detector.usesCompositedScreenBackdrop(forWindowID: 100))
    }

    func testWindowAtIgnoresCursorAboveAppWindow() {
        let detector = WindowDetector()
        detector.apply([
            DetectedWindow(
                name: "Cursor",
                windowID: 100,
                layer: Int(CGWindowLevelForKey(.cursorWindow)),
                frame: CGRect(x: 80, y: 90, width: 36, height: 51)
            ),
            DetectedWindow(
                name: "Editor",
                windowID: 200,
                layer: Int(CGWindowLevelForKey(.normalWindow)),
                frame: CGRect(x: 0, y: 0, width: 600, height: 400)
            )
        ])

        let detected = detector.windowAt(cgPoint: CGPoint(x: 90, y: 100))

        XCTAssertEqual(detected?.windowID, 200)
    }

    func testWindowAtDoesNotReturnOnlyTransientSurface() {
        let detector = WindowDetector()
        detector.apply([
            DetectedWindow(
                name: "Insertion Point",
                windowID: 300,
                layer: Int(CGWindowLevelForKey(.statusWindow)),
                frame: CGRect(x: 80, y: 90, width: 36, height: 51)
            )
        ])

        XCTAssertNil(detector.windowAt(cgPoint: CGPoint(x: 90, y: 100)))
    }

    func testFocusSensitiveWindowsCoverMenusAndFocusedLauncherPanels() {
        let launcher = WindowDetector.FocusOwner(pid: 42, isRegularApp: false)
        let regularApp = WindowDetector.FocusOwner(pid: 42, isRegularApp: true)
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let modalPanelLayer = Int(CGWindowLevelForKey(.modalPanelWindow))
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))

        // Popup menus close for any owner, focused or not
        XCTAssertTrue(WindowDetector.isFocusSensitive(layer: menuLayer, ownerPID: 7, focusOwner: nil))
        // Raycast-style launcher panel owned by the focused accessory app
        XCTAssertTrue(WindowDetector.isFocusSensitive(layer: modalPanelLayer, ownerPID: 42, focusOwner: launcher))
        XCTAssertTrue(WindowDetector.isFocusSensitive(layer: 0, ownerPID: 42, focusOwner: launcher))
        // A focused regular app's floating panel may hide on deactivation
        XCTAssertTrue(WindowDetector.isFocusSensitive(layer: modalPanelLayer, ownerPID: 42, focusOwner: regularApp))
        // Ordinary document windows and status items stay on screen
        XCTAssertFalse(WindowDetector.isFocusSensitive(layer: 0, ownerPID: 42, focusOwner: regularApp))
        XCTAssertFalse(WindowDetector.isFocusSensitive(layer: statusLayer, ownerPID: 42, focusOwner: launcher))
        // Panels of apps that do not own focus are left alone
        XCTAssertFalse(WindowDetector.isFocusSensitive(layer: modalPanelLayer, ownerPID: 7, focusOwner: launcher))
    }
}
