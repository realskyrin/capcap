import AppKit

enum DisplayCapabilities {
    static var supportsHistoryPanelNotch: Bool {
        NSScreen.screens.contains(where: screenSupportsHistoryPanelNotch)
    }

    private static func screenSupportsHistoryPanelNotch(_ screen: NSScreen) -> Bool {
        guard screen.safeAreaInsets.top > 0 else { return false }

        let leftArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightArea = screen.auxiliaryTopRightArea ?? .zero
        return !leftArea.isEmpty && !rightArea.isEmpty
    }
}
