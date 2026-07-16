import AppKit

final class ColorPickerRunner {
    static let shared = ColorPickerRunner()

    private var activeColorSampler: NSColorSampler?

    private init() {}

    func cancel() {
        guard activeColorSampler != nil else { return }
        activeColorSampler = nil
        Self.postEscapeKeyEvent()
    }

    @discardableResult
    func run(
        on screen: NSScreen? = nil,
        onPicked: ((NSColor, String) -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) -> Bool {
        guard activeColorSampler == nil else { return false }

        let sampler = NSColorSampler()
        activeColorSampler = sampler
        sampler.show { [weak self, weak sampler] picked in
            guard let self, self.activeColorSampler === sampler else { return }
            self.activeColorSampler = nil
            guard let picked else {
                onFinished?()
                return
            }

            let result = Self.pickResult(from: picked)
            ClipboardManager.copyColorToClipboard(hex: result.hex)

            if Defaults.historyCacheEnabled {
                HistoryManager.shared.addColor(hex: result.hex)
                Defaults.lastPickedColorHex = result.hex
            }

            onPicked?(result.color, result.hex)
            ToastWindow.show(message: L10n.colorCopied(result.hex), on: screen ?? Self.currentScreen())
            onFinished?()
        }
        return true
    }

    private static func pickResult(from color: NSColor) -> (color: NSColor, hex: String) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(max(0, min(1, rgb.redComponent)) * 255))
        let g = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
        let swatchColor = NSColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
        return (swatchColor, String(format: "#%02X%02X%02X", r, g, b))
    }

    private static func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private static func postEscapeKeyEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let escapeKeyCode = CGKeyCode(53)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
