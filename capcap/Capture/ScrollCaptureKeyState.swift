import AppKit
import Carbon

struct ScrollCaptureKeyState {
    private var modifiers: NSEvent.ModifierFlags

    init(modifiers: NSEvent.ModifierFlags = []) {
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
    }

    static func isModeSwitchKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        // 只保留无组合键的空格；大写锁定不影响模式切换
        return Int(event.keyCode) == kVK_Space
            && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    mutating func isFinishKey(_ event: NSEvent) -> Bool {
        if event.type == .keyDown { return !Self.isModeSwitchKey(event) }
        guard event.type == .flagsChanged else { return false }
        let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { modifiers = current }
        // 启动快捷键的释放不能结束截图；新按下的修饰键仍可结束
        return Int(event.keyCode) == kVK_CapsLock || !current.subtracting(modifiers).isEmpty
    }
}
