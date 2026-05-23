#if os(macOS)
import Foundation

@available(macOS 13.0, *)
public struct PermissionFlowButtonState: Equatable, Sendable {
    /// Localization key for the button title.
    public let titleKey: String
    /// SF Symbol name for the button icon.
    public let systemImage: String
    /// Whether the permission is currently granted.
    public let isGranted: Bool
    
    public init(titleKey: String, systemImage: String, isGranted: Bool) {
        self.titleKey = titleKey
        self.systemImage = systemImage
        self.isGranted = isGranted
    }
}

@available(macOS 13.0, *)
extension PermissionFlowButtonState {
    /// Creates button state from authorization state.
    public static func make(from state: PermissionAuthorizationState) -> Self {
        switch state {
        case .granted:
            .init(
                titleKey: "permission_flow.button.granted",
                systemImage: "checkmark.seal.fill",
                isGranted: true
            )
        case .notGranted:
            .init(
                titleKey: "permission_flow.button.grant",
                systemImage: "arrow.right.circle.fill",
                isGranted: false
            )
        case .unknown:
            .init(
                titleKey: "permission_flow.button.open",
                systemImage: "arrow.right.circle.fill",
                isGranted: false
            )
        case .checking:
            .init(
                titleKey: "permission_flow.button.checking",
                systemImage: "clock",
                isGranted: false
            )
        }
    }
}
#endif