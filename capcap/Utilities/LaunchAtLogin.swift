import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return true }
                try service.register()
            } else {
                try service.unregister()
            }
            return true
        } catch {
            NSLog("[capcap] LaunchAtLogin toggle failed: \(error.localizedDescription)")
            return false
        }
    }
}
