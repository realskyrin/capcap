import CoreGraphics
import XCTest
@testable import capcap

final class WindowDetectorTests: XCTestCase {
    func testWindowAtSelectsSystemApplicationsPanelAboveAppWindow() {
        let detector = WindowDetector()
        detector.apply([
            DetectedWindow(
                name: "Siri",
                windowID: 100,
                layer: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1,
                frame: CGRect(x: 1265, y: 338, width: 844, height: 577)
            ),
            DetectedWindow(
                name: "Editor",
                windowID: 200,
                layer: Int(CGWindowLevelForKey(.normalWindow)),
                frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
            )
        ])

        let detected = detector.windowAt(cgPoint: CGPoint(x: 1500, y: 500))

        XCTAssertEqual(detected?.windowID, 100)
        XCTAssertEqual(detected?.frame, CGRect(x: 1265, y: 338, width: 844, height: 577))
        XCTAssertTrue(detector.usesCompositedScreenBackdrop(forWindowID: 100))
    }

    func testSystemApplicationsPanelIsFocusSensitiveWithoutForegroundOwnership() {
        let panelLayer = Int(CGWindowLevelForKey(.mainMenuWindow)) - 1
        let foregroundApp = WindowDetector.FocusOwner(pid: 42, isRegularApp: true)

        // 系统应用面板可由 Siri 承载，而前台应用仍是其他进程
        XCTAssertTrue(WindowDetector.isFocusSensitive(
            layer: panelLayer, ownerPID: 7, focusOwner: foregroundApp
        ))
        XCTAssertTrue(WindowDetector.isFocusSensitive(
            layer: panelLayer, ownerPID: 7, focusOwner: nil
        ))
    }

    func testWindowAtStillIgnoresSystemChromeAboveAppWindow() {
        let detector = WindowDetector()
        for key in [CGWindowLevelKey.dockWindow, .mainMenuWindow, .statusWindow, .cursorWindow] {
            detector.apply([
                DetectedWindow(
                    name: "System chrome",
                    windowID: 100,
                    layer: Int(CGWindowLevelForKey(key)),
                    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
                ),
                DetectedWindow(
                    name: "Editor",
                    windowID: 200,
                    layer: Int(CGWindowLevelForKey(.normalWindow)),
                    frame: CGRect(x: 100, y: 100, width: 600, height: 400)
                )
            ])

            XCTAssertEqual(detector.windowAt(cgPoint: CGPoint(x: 200, y: 200))?.windowID, 200)
        }
    }

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
