import AppKit

enum AppPermissions {
    static var allRequiredGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }
}
