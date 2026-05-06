import Foundation

enum AppLanguage: String {
    case en = "en"
    case zh = "zh"
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("capcap.languageDidChange")
    static let historyCacheLimitDidChange = Notification.Name("capcap.historyCacheLimitDidChange")
    static let historyDidUpdate = Notification.Name("capcap.historyDidUpdate")
    static let hotkeyDidChange = Notification.Name("capcap.hotkeyDidChange")
}

enum L10n {
    static var lang: AppLanguage { Defaults.language }

    // Settings
    static var settingsTitle: String { lang == .zh ? "capcap 设置" : "capcap Settings" }
    static var showMenuBarIcon: String { lang == .zh ? "显示菜单栏图标" : "Show Menu Bar Icon" }
    static var permissionsHeader: String { lang == .zh ? "所需权限" : "Required Permissions" }
    static var accessibilityPermission: String { lang == .zh ? "辅助功能" : "Accessibility" }
    static var accessibilityDescription: String {
        lang == .zh
            ? "用于检测双击 ⌘ Command 键来触发截图"
            : "Needed to detect double-tap \u{2318} Command key globally to trigger screenshots."
    }
    static var screenRecordingPermission: String { lang == .zh ? "屏幕录制" : "Screen Recording" }
    static var screenRecordingDescription: String {
        lang == .zh
            ? "用于捕获屏幕内容进行截图"
            : "Needed to capture screen content for screenshots."
    }
    static var launchApp: String { lang == .zh ? "启动应用" : "Launch App" }
    static var launchAtLogin: String { lang == .zh ? "开机自动启动" : "Launch at Login" }
    static var demoMode: String { lang == .zh ? "演示模式" : "Demo Mode" }
    static var demoModeHint: String {
        lang == .zh
            ? "录屏软件可以录到选区遮罩与编辑器（仅影响外部录制）"
            : "Allow screen recorders to capture the selection overlay and editor"
    }
    static var historyCacheLabel: String { lang == .zh ? "历史缓存数量" : "History Cache Size" }
    static var historyCacheHint: String {
        lang == .zh
            ? "保留最近的截图数量，便于快速再次复制"
            : "Keep the most recent screenshots for quick re-copy"
    }

    // Screenshot shortcut
    static var shortcutHeader: String { lang == .zh ? "截图快捷键" : "Screenshot Shortcut" }
    static var shortcutHint: String {
        lang == .zh
            ? "默认双击 ⌘ 触发；自定义后双击 ⌘ 失效，可点恢复回到默认"
            : "Default: double-tap \u{2318}. Setting a custom shortcut disables double-tap."
    }
    static var shortcutDefaultDisplay: String { lang == .zh ? "双击 \u{2318}" : "Double-tap \u{2318}" }
    static var shortcutSet: String { lang == .zh ? "录制" : "Set" }
    static var shortcutCancel: String { lang == .zh ? "取消" : "Cancel" }
    static var shortcutWaiting: String { lang == .zh ? "等待按键…" : "Press keys…" }
    static var shortcutRestore: String { lang == .zh ? "恢复默认" : "Restore Default" }

    // Menu bar
    static var takeScreenshot: String { lang == .zh ? "截图" : "Take Screenshot" }
    static var settings: String { lang == .zh ? "设置..." : "Settings..." }
    static var quitApp: String { lang == .zh ? "退出 capcap" : "Quit capcap" }
    static var historyMenu: String { lang == .zh ? "历史" : "History" }
    static var historyEmpty: String { lang == .zh ? "暂无历史" : "No history yet" }
    static var historyClear: String { lang == .zh ? "清除历史" : "Clear History" }

    // Cursor chip
    static var dragToScreenshot: String { lang == .zh ? "点击窗口或拖动以截图" : "Click window or drag to screenshot" }

    // Toast
    static var copiedToClipboard: String { lang == .zh ? "已添加到剪贴板" : "Copied to clipboard" }
    static var mergedLongScreenshot: String { lang == .zh ? "已合并长截图" : "Long screenshot merged" }
    static func colorCopied(_ hex: String) -> String {
        lang == .zh ? "已复制颜色 \(hex)" : "Copied color \(hex)"
    }

    // Toolbar tooltips
    static var tipRectangle: String { lang == .zh ? "矩形" : "Rectangle" }
    static var tipEllipse: String { lang == .zh ? "椭圆" : "Ellipse" }
    static var tipArrow: String { lang == .zh ? "箭头" : "Arrow" }
    static var tipPen: String { lang == .zh ? "画笔" : "Pen" }
    static var tipMarker: String { lang == .zh ? "高亮笔" : "Marker" }
    static var tipMosaic: String { lang == .zh ? "马赛克" : "Mosaic" }
    static var tipNumbered: String { lang == .zh ? "序号" : "Numbered" }
    static var tipText: String { lang == .zh ? "文字" : "Text" }
    static var tipColorPicker: String { lang == .zh ? "取色器" : "Color Picker" }
    static var tipUndo: String { lang == .zh ? "撤销" : "Undo" }
    static var tipRedo: String { lang == .zh ? "恢复撤销" : "Redo" }
    static var tipMoveSelection: String { lang == .zh ? "移动选区" : "Move Selection" }
    static var tipScrollCapture: String { lang == .zh ? "长截图" : "Scroll Capture" }
    static var tipBeautify: String { lang == .zh ? "美化" : "Beautify" }
    static var tipSave: String { lang == .zh ? "保存" : "Save" }
    static var tipPin: String { lang == .zh ? "钉在屏幕" : "Pin to Screen" }
    static var tipCancel: String { lang == .zh ? "取消" : "Cancel" }
    static var tipConfirm: String { lang == .zh ? "确认" : "Confirm" }

    // Beautify
    static var beautify: String { lang == .zh ? "美化" : "Beautify" }
    static var beautifyPresetPeachBlue: String { lang == .zh ? "粉蓝" : "Peach Blue" }
    static var beautifyPresetMintTeal: String { lang == .zh ? "薄荷青" : "Mint Teal" }
    static var beautifyPresetPeachPink: String { lang == .zh ? "桃粉" : "Peach Pink" }
    static var beautifyPresetBluePurple: String { lang == .zh ? "蓝紫梦" : "Blue Purple" }
    static var beautifyPresetWarmOrange: String { lang == .zh ? "暖橘黄" : "Warm Orange" }
    static var beautifyPresetTealPink: String { lang == .zh ? "青粉" : "Teal Pink" }
    static var beautifyPresetDeepPurple: String { lang == .zh ? "深邃紫" : "Deep Purple" }
    static var beautifyPresetNeutralGray: String { lang == .zh ? "中性灰" : "Neutral Gray" }
    static var beautifyPresetWallpaper: String { lang == .zh ? "壁纸" : "Wallpaper" }

    // Language
    static var languageHeader: String { lang == .zh ? "语言" : "Language" }

    // Settings sidebar tabs
    static var settingsTabGeneral: String { lang == .zh ? "通用" : "General" }
    static var settingsTabShortcuts: String { lang == .zh ? "快捷键" : "Shortcuts" }
    static var settingsTabPermissions: String { lang == .zh ? "权限" : "Permissions" }
    static var settingsTabUpload: String { lang == .zh ? "图床" : "Upload" }
    static var settingsQuit: String { lang == .zh ? "退出应用" : "Quit App" }

    // Quit confirmation dialog
    static var quitConfirmTitle: String { lang == .zh ? "退出 capcap?" : "Quit capcap?" }
    static var quitConfirmMessage: String {
        lang == .zh
            ? "退出后菜单栏图标和截图快捷键将不再可用，需要重新启动 capcap。"
            : "Quitting removes the menu bar icon and disables the screenshot shortcut until you launch capcap again."
    }
    static var quitConfirmAction: String { lang == .zh ? "退出" : "Quit" }
    static var quitConfirmCancel: String { lang == .zh ? "取消" : "Cancel" }

    // Upload — toolbar / toast / progress
    static var tipUpload: String { lang == .zh ? "上传到图床" : "Upload to image host" }
    static var uploadingTitle: String { lang == .zh ? "上传中" : "Uploading" }
    static var uploadCopied: String { lang == .zh ? "已复制图床链接" : "Image URL copied" }
    static var uploadNoProvider: String {
        lang == .zh ? "请先在设置中配置图床" : "Configure an uploader in Settings first"
    }
    static var uploadFailedPrefix: String { lang == .zh ? "上传失败: " : "Upload failed: " }

    // Upload — settings tab
    static var uploadDefaultProvider: String { lang == .zh ? "默认图床" : "Default Uploader" }
    static var uploadDefaultNone: String { lang == .zh ? "未启用" : "Disabled" }
    static var uploadFieldsHint: String {
        lang == .zh
            ? "字段留空即停用对应图床。"
            : "Leave fields empty to disable a provider."
    }
    static var uploadSetDefaultButton: String { lang == .zh ? "设为默认" : "Set Default" }
    static var uploadSaveButton: String { lang == .zh ? "保存" : "Save" }
    static var uploadClearButton: String { lang == .zh ? "清空" : "Clear" }
    static var uploadSavedToast: String { lang == .zh ? "已保存配置" : "Config saved" }
    static var uploadCurrentDefault: String { lang == .zh ? "当前默认" : "Current default" }
}

struct Defaults {
    private static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static var doubleTapInterval: TimeInterval {
        get {
            let val = defaults.double(forKey: "doubleTapInterval")
            return val > 0 ? val : 0.3
        }
        set {
            defaults.set(newValue, forKey: "doubleTapInterval")
        }
    }

    // Custom screenshot hotkey. keyCode == 0 means "no custom hotkey" (fall back to double-tap ⌘).
    // Modifiers are stored using Carbon flags (cmdKey | shiftKey | optionKey | controlKey).

    static var screenshotHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "screenshotHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "screenshotHotkeyKeyCode") }
    }

    static var screenshotHotkeyModifiers: Int {
        get { defaults.integer(forKey: "screenshotHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "screenshotHotkeyModifiers") }
    }

    static var hasCustomScreenshotHotkey: Bool {
        screenshotHotkeyKeyCode != 0
    }

    static func clearScreenshotHotkey() {
        defaults.removeObject(forKey: "screenshotHotkeyKeyCode")
        defaults.removeObject(forKey: "screenshotHotkeyModifiers")
    }

    static var penColor: Int {
        get {
            let val = defaults.integer(forKey: "penColor")
            return val == 0 ? 0xFF0000 : val
        }
        set {
            defaults.set(newValue, forKey: "penColor")
        }
    }

    static var penWidth: Double {
        get {
            let val = defaults.double(forKey: "penWidth")
            return val > 0 ? val : 3.0
        }
        set {
            defaults.set(newValue, forKey: "penWidth")
        }
    }

    static var mosaicBlockSize: Double {
        get {
            let val = defaults.double(forKey: "mosaicBlockSize")
            return val > 0 ? val : 12.0
        }
        set {
            defaults.set(newValue, forKey: "mosaicBlockSize")
        }
    }

    static let textFontSizeMin: Double = 10
    static let textFontSizeMax: Double = 100

    static var lastTextFontSize: Double {
        get {
            if defaults.object(forKey: "lastTextFontSize") == nil {
                return 20
            }
            let val = defaults.double(forKey: "lastTextFontSize")
            return min(max(val, textFontSizeMin), textFontSizeMax)
        }
        set {
            defaults.set(min(max(newValue, textFontSizeMin), textFontSizeMax), forKey: "lastTextFontSize")
        }
    }

    static var lastBeautifyPresetID: String? {
        get { defaults.string(forKey: "lastBeautifyPresetID") }
        set { defaults.set(newValue, forKey: "lastBeautifyPresetID") }
    }

    static var lastBeautifyPadding: Double {
        get {
            if defaults.object(forKey: "lastBeautifyPadding") == nil {
                return 24
            }
            let val = defaults.double(forKey: "lastBeautifyPadding")
            return min(max(val, 8), 56)
        }
        set {
            defaults.set(min(max(newValue, 8), 56), forKey: "lastBeautifyPadding")
        }
    }

    static let historyCacheMin: Int = 5
    static let historyCacheMax: Int = 20

    static var historyCacheLimit: Int {
        get {
            if defaults.object(forKey: "historyCacheLimit") == nil {
                return 10
            }
            let val = defaults.integer(forKey: "historyCacheLimit")
            return min(max(val, historyCacheMin), historyCacheMax)
        }
        set {
            let clamped = min(max(newValue, historyCacheMin), historyCacheMax)
            defaults.set(clamped, forKey: "historyCacheLimit")
            NotificationCenter.default.post(name: .historyCacheLimitDidChange, object: nil)
        }
    }

    static var demoMode: Bool {
        get { defaults.bool(forKey: "demoMode") }
        set { defaults.set(newValue, forKey: "demoMode") }
    }

    static var showMenuBar: Bool {
        get {
            if defaults.object(forKey: "showMenuBar") == nil {
                return true
            }
            return defaults.bool(forKey: "showMenuBar")
        }
        set {
            defaults.set(newValue, forKey: "showMenuBar")
        }
    }

    static var language: AppLanguage {
        get {
            AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .zh
        }
        set {
            let old = language
            defaults.set(newValue.rawValue, forKey: "appLanguage")
            if newValue != old {
                NotificationCenter.default.post(name: .languageDidChange, object: nil)
            }
        }
    }
}
