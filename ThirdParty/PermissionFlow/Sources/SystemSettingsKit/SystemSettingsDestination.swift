import Foundation
#if os(iOS)
import UIKit
#endif

#if os(macOS)
/// Anchor points for navigating to specific sections within the Displays settings pane.
/// These anchors allow direct navigation to subsections of the macOS System Settings Displays panel.
@available(macOS 13.0, *)
public enum DisplaySettingsAnchor: String, CaseIterable, Sendable {
    /// Opens the Advanced section in Displays settings.
    case advancedSection
    /// Opens ambient light and True Tone related settings.
    case ambienceSection
    /// Opens display arrangement and positioning controls.
    case arrangementSection
    /// Opens display characteristics and calibration options.
    case characteristicSection
    /// Opens the main Displays section.
    case displaysSection
    /// Opens miscellaneous display settings.
    case miscellaneousSection
    /// Opens Night Shift settings.
    case nightShiftSection
    /// Opens color profile settings.
    case profileSection
    /// Opens resolution settings.
    case resolutionSection
    /// Opens Sidecar settings.
    case sidecarSection
}

/// Anchor points for navigating to specific sections within the Privacy & Security settings pane.
/// These anchors allow direct navigation to subsections of the macOS System Settings Privacy & Security panel.
@available(macOS 13.0, *)
public enum PrivacySecurityAnchor: String, CaseIterable, Sendable {
    /// Opens the Advanced section in Privacy & Security.
    case advanced = "Advanced"
    /// Opens FileVault settings.
    case fileVault = "FileVault"
    /// Opens the Location Access Report section.
    case locationAccessReport = "Location_Access_Report"
    /// Opens Lockdown Mode settings.
    case lockdownMode = "LockdownMode"
    /// Opens Accessibility privacy permissions.
    case privacyAccessibility = "Privacy_Accessibility"
    /// Opens Advertising privacy settings.
    case privacyAdvertising = "Privacy_Advertising"
    /// Opens Full Disk Access permissions.
    case privacyAllFiles = "Privacy_AllFiles"
    /// Opens Analytics privacy settings.
    case privacyAnalytics = "Privacy_Analytics"
    /// Opens app bundle access permissions.
    case privacyAppBundles = "Privacy_AppBundles"
    /// Opens audio capture permissions.
    case privacyAudioCapture = "Privacy_AudioCapture"
    /// Opens Automation permissions.
    case privacyAutomation = "Privacy_Automation"
    /// Opens Bluetooth permissions.
    case privacyBluetooth = "Privacy_Bluetooth"
    /// Opens Calendar permissions.
    case privacyCalendars = "Privacy_Calendars"
    /// Opens Camera permissions.
    case privacyCamera = "Privacy_Camera"
    /// Opens Contacts permissions.
    case privacyContacts = "Privacy_Contacts"
    /// Opens Developer Tools permissions.
    case privacyDevTools = "Privacy_DevTools"
    /// Opens Files and Folders permissions.
    case privacyFilesAndFolders = "Privacy_FilesAndFolders"
    /// Opens Focus permissions.
    case privacyFocus = "Privacy_Focus"
    /// Opens HomeKit permissions.
    case privacyHomeKit = "Privacy_HomeKit"
    /// Opens input and event monitoring permissions.
    case privacyListenEvent = "Privacy_ListenEvent"
    /// Opens Location Services permissions.
    case privacyLocationServices = "Privacy_LocationServices"
    /// Opens Media and Apple Music permissions.
    case privacyMedia = "Privacy_Media"
    /// Opens Microphone permissions.
    case privacyMicrophone = "Privacy_Microphone"
    /// Opens Motion and Fitness permissions.
    case privacyMotion = "Privacy_Motion"
    /// Opens nudity detection privacy settings.
    case privacyNudityDetection = "Privacy_NudityDetection"
    /// Opens passkey access permissions.
    case privacyPasskeyAccess = "Privacy_PasskeyAccess"
    /// Opens Photos permissions.
    case privacyPhotos = "Privacy_Photos"
    /// Opens Reminders permissions.
    case privacyReminders = "Privacy_Reminders"
    /// Opens Remote Desktop permissions.
    case privacyRemoteDesktop = "Privacy_RemoteDesktop"
    /// Opens Screen Recording permissions.
    case privacyScreenCapture = "Privacy_ScreenCapture"
    /// Opens Speech Recognition permissions.
    case privacySpeechRecognition = "Privacy_SpeechRecognition"
    /// Opens System Services privacy settings.
    case privacySystemServices = "Privacy_SystemServices"
    /// Opens the main Security section.
    case security = "Security"
    /// Opens Security Improvements recommendations.
    case securityImprovements = "SecurityImprovements"
}
#endif

@available(macOS 13.0, iOS 16.0, *)
public struct SystemSettingsDestination: Hashable, Sendable {
    public let url: URL

    /// The pane or extension identifier used by System Settings when the
    /// destination is backed by a macOS deeplink.
    public let paneIdentifier: String?

    /// Optional anchor for a subsection inside a macOS pane.
    public let anchor: String?

    public init(url: URL, paneIdentifier: String? = nil, anchor: String? = nil) {
        self.url = url
        self.paneIdentifier = paneIdentifier
        self.anchor = anchor
    }
}

#if os(macOS)
@available(macOS 13.0, *)
public extension SystemSettingsDestination {
    init(paneIdentifier: String, anchor: String? = nil) {
        let encodedAnchor = anchor?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        let value = if let encodedAnchor, encodedAnchor.isEmpty == false {
            "x-apple.systempreferences:\(paneIdentifier)?\(encodedAnchor)"
        } else {
            "x-apple.systempreferences:\(paneIdentifier)"
        }

        self.init(
            url: URL(string: value)!,
            paneIdentifier: paneIdentifier,
            anchor: anchor
        )
    }
}

@available(macOS 13.0, *)
public extension SystemSettingsDestination {
    /// Privacy & Security home page.
    static func privacy() -> Self {
        Self(paneIdentifier: "com.apple.settings.PrivacySecurity.extension")
    }

    /// Convenience helper for the Privacy & Security extension anchors.
    /// Example anchors include `Privacy_Advertising` and `Privacy_AllFiles`.
    static func privacy(anchor: String) -> Self {
        Self(
            paneIdentifier: "com.apple.settings.PrivacySecurity.extension",
            anchor: anchor
        )
    }

    /// Convenience helper for typed Privacy & Security anchors.
    static func privacy(anchor: PrivacySecurityAnchor) -> Self {
        Self(
            paneIdentifier: "com.apple.settings.PrivacySecurity.extension",
            anchor: anchor.rawValue
        )
    }

    /// Wallpaper settings.
    static let wallpaper = Self(paneIdentifier: "com.apple.Wallpaper-Settings.extension")

    /// Displays settings.
    static let displays = Self(paneIdentifier: "com.apple.Displays-Settings.extension")

    /// Displays settings subsection.
    static func displays(anchor: DisplaySettingsAnchor) -> Self {
        Self(
            paneIdentifier: "com.apple.Displays-Settings.extension",
            anchor: anchor.rawValue
        )
    }

    /// Bluetooth settings.
    static let bluetooth = Self(paneIdentifier: "com.apple.BluetoothSettings")

    /// Login items settings.
    static let loginItems = Self(paneIdentifier: "com.apple.LoginItems-Settings.extension")
}
#elseif os(iOS)
@available(iOS 16.0, *)
public extension SystemSettingsDestination {
    /// Opens the current app's Settings screen on iOS.
    static let appSettings = Self(url: URL(string: UIApplication.openSettingsURLString)!)

    /// Opens the current app's notification settings screen on iOS.
    static let notificationSettings = Self(url: URL(string: UIApplication.openNotificationSettingsURLString)!)
}
#endif
