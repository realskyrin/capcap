#if os(macOS)
import AppKit
import SwiftUI

@available(macOS 13.0, *)
public struct PermissionFlowButton: View {
    @Environment(\.locale) var locale
    @StateObject private var controller: PermissionFlowController
    @State private var buttonState: PermissionFlowButtonState
    private let pane: PermissionFlowPane
    private let suggestedAppURLs: [URL]
    private let title: LocalizedStringResource?

    public init(
        title: LocalizedStringResource? = nil,
        pane: PermissionFlowPane,
        suggestedAppURLs: [URL] = [],
        configuration: PermissionFlowConfiguration = .init()
    ) {
        _controller = StateObject(wrappedValue: PermissionFlowController(configuration: configuration))
        self.pane = pane
        self.suggestedAppURLs = suggestedAppURLs
        self.title = title
        
        // Initialize with checking state, will be updated on appear
        _buttonState = State(initialValue: PermissionFlowButtonState.make(from: .checking))
    }

    public var body: some View {
        Button {
            controller.setLocaleIdentifier(locale.identifier)
            controller.authorize(
                pane: pane,
                suggestedAppURLs: suggestedAppURLs,
                sourceFrameInScreen: clickSourceFrameInScreen()
            )
        } label: {
            Label {
                Text(title ?? LocalizedStringResource(String.LocalizationValue(buttonState.titleKey), locale: locale, bundle: .module))
            } icon: {
                Image(systemName: buttonState.systemImage)
                    .foregroundColor(buttonState.isGranted ? .green : .primary)
            }
        }
        .onAppear(perform: refreshAuthorizationStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAuthorizationStatus()
        }
    }

    /// Uses the exact click location as the launch point so the panel appears
    /// to fly out from where the user pressed the button.
    private func clickSourceFrameInScreen() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
    }

    private func refreshAuthorizationStatus() {
        let provider = PermissionStatusRegistry.provider(for: pane)
        let authState = provider.authorizationState()
        buttonState = PermissionFlowButtonState.make(from: authState)
    }
}
#endif
