#if os(macOS)
import Foundation
import SystemSettingsKit

@available(macOS 13.0, *)
public enum PermissionFlowPane: String, CaseIterable, Codable, Sendable {
    /// App Management permissions list.
    case appManagement
    /// Accessibility permissions list.
    case accessibility
    /// Bluetooth permissions list.
    case bluetooth
    /// Developer Tools permissions list.
    case developerTools
    /// Full Disk Access permissions list.
    case fullDiskAccess
    /// Input Monitoring permissions list.
    case inputMonitoring
    /// Media & Apple Music permissions list.
    case mediaAppleMusic
    /// Screen Recording permissions list.
    case screenRecording

    /// The matching typed Privacy & Security anchor in SystemSettingsKit.
    public var privacyAnchor: PrivacySecurityAnchor {
        switch self {
        case .appManagement: .privacyAppBundles
        case .accessibility: .privacyAccessibility
        case .bluetooth: .privacyBluetooth
        case .developerTools: .privacyDevTools
        case .fullDiskAccess: .privacyAllFiles
        case .inputMonitoring: .privacyListenEvent
        case .mediaAppleMusic: .privacyMedia
        case .screenRecording: .privacyScreenCapture
        }
    }

    /// Deep link to the corresponding page inside System Settings.
    public var settingsURL: URL {
        SystemSettingsDestination.privacy(anchor: privacyAnchor).url
    }

    /// Returns the localized permission name for the requested locale.
    func localizedTitle(localeIdentifier: String?) -> String {
        switch self {
        case .appManagement:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.app_management",
                defaultValue: "App Management",
                localeIdentifier: localeIdentifier
            )
        case .accessibility:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.accessibility",
                defaultValue: "Accessibility",
                localeIdentifier: localeIdentifier
            )
        case .bluetooth:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.bluetooth",
                defaultValue: "Bluetooth",
                localeIdentifier: localeIdentifier
            )
        case .developerTools:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.developer_tools",
                defaultValue: "Developer Tools",
                localeIdentifier: localeIdentifier
            )
        case .fullDiskAccess:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.full_disk_access",
                defaultValue: "Full Disk Access",
                localeIdentifier: localeIdentifier
            )
        case .inputMonitoring:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.input_monitoring",
                defaultValue: "Input Monitoring",
                localeIdentifier: localeIdentifier
            )
        case .mediaAppleMusic:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.media_apple_music",
                defaultValue: "Media & Apple Music",
                localeIdentifier: localeIdentifier
            )
        case .screenRecording:
            return PermissionFlowLocalizer.string(
                "permission_flow.pane.screen_recording",
                defaultValue: "Screen Recording",
                localeIdentifier: localeIdentifier
            )
        }
    }
}
#endif
