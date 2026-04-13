import Foundation

enum AppLanguage: String {
    case en = "en"
    case zh = "zh"
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("capcap.languageDidChange")
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

    // Menu bar
    static var takeScreenshot: String { lang == .zh ? "截图" : "Take Screenshot" }
    static var settings: String { lang == .zh ? "设置..." : "Settings..." }
    static var quitApp: String { lang == .zh ? "退出 capcap" : "Quit capcap" }

    // Cursor chip
    static var dragToScreenshot: String { lang == .zh ? "点击窗口或拖动以截图" : "Click window or drag to screenshot" }

    // Toast
    static var copiedToClipboard: String { lang == .zh ? "已添加到剪贴板" : "Copied to clipboard" }
    static var mergedLongScreenshot: String { lang == .zh ? "已合并长截图" : "Long screenshot merged" }

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
