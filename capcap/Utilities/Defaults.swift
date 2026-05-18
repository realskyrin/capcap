import Foundation

/// A language the app's UI can be displayed in. Raw values double as the
/// `appLanguage` UserDefaults value (kept stable for backward compatibility).
enum AppLanguage: String, CaseIterable {
    case zh
    case en
    case ja
    case ko
    case fr
    case ru

    /// Folder name (without extension) of the matching `.lproj` bundle inside
    /// `capcap.app/Contents/Resources/`.
    var lprojName: String {
        switch self {
        case .zh: return "zh-Hans"
        default:  return rawValue
        }
    }

    /// Native language name shown in the in-app language picker.
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .ru: return "Русский"
        }
    }

    /// Best-effort match of the system's preferred languages to a supported
    /// app language — used on first launch before the user picks explicitly.
    static var systemDefault: AppLanguage {
        for code in Locale.preferredLanguages {
            let lower = code.lowercased()
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("fr") { return .fr }
            if lower.hasPrefix("ru") { return .ru }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("capcap.languageDidChange")
    static let historyCacheLimitDidChange = Notification.Name("capcap.historyCacheLimitDidChange")
    static let historyDidUpdate = Notification.Name("capcap.historyDidUpdate")
    static let hotkeyDidChange = Notification.Name("capcap.hotkeyDidChange")
    static let translationConfigDidChange = Notification.Name("capcap.translationConfigDidChange")
}

/// Centralized accessor for every user-facing string. Each property resolves a
/// key from the current language's `Localizable.strings`; the translations
/// themselves live in `Resources/<lang>.lproj/Localizable.strings`.
enum L10n {
    static var lang: AppLanguage { Defaults.language }

    private static func s(_ key: String) -> String { Localizer.string(key) }

    // Settings
    static var settingsTitle: String { s("settingsTitle") }
    static var showMenuBarIcon: String { s("showMenuBarIcon") }
    static var permissionsHeader: String { s("permissionsHeader") }
    static var accessibilityPermission: String { s("accessibilityPermission") }
    static var accessibilityDescription: String { s("accessibilityDescription") }
    static var screenRecordingPermission: String { s("screenRecordingPermission") }
    static var screenRecordingDescription: String { s("screenRecordingDescription") }
    static var launchApp: String { s("launchApp") }
    static var launchAtLogin: String { s("launchAtLogin") }
    static var demoMode: String { s("demoMode") }
    static var demoModeHint: String { s("demoModeHint") }
    static var historyCacheLabel: String { s("historyCacheLabel") }
    static var historyCacheHint: String { s("historyCacheHint") }
    static var countdownLabel: String { s("countdownLabel") }
    static var countdownHint: String { s("countdownHint") }
    static var countdownSecondsSuffix: String { s("countdownSecondsSuffix") }

    // Screenshot shortcut
    static var shortcutHeader: String { s("shortcutHeader") }
    static var shortcutHint: String { s("shortcutHint") }
    static var shortcutDefaultDisplay: String { s("shortcutDefaultDisplay") }
    static var shortcutSet: String { s("shortcutSet") }
    static var shortcutCancel: String { s("shortcutCancel") }
    static var shortcutWaiting: String { s("shortcutWaiting") }
    static var shortcutRestore: String { s("shortcutRestore") }

    // Pin-image shortcut
    static var pinShortcutHeader: String { s("pinShortcutHeader") }
    static var pinShortcutHint: String { s("pinShortcutHint") }
    static var pinShortcutDefaultDisplay: String { s("pinShortcutDefaultDisplay") }
    static var pinShortcutClear: String { s("pinShortcutClear") }
    static var pinNoImage: String { s("pinNoImage") }
    static var pinFromFinderHint: String { s("pinFromFinderHint") }
    static var pinFromClipboardHint: String { s("pinFromClipboardHint") }

    // Menu bar
    static var takeScreenshot: String { s("takeScreenshot") }
    static var settings: String { s("settings") }
    static var quitApp: String { s("quitApp") }
    static var historyMenu: String { s("historyMenu") }
    static var historyEmpty: String { s("historyEmpty") }
    static var historyClear: String { s("historyClear") }

    // Cursor chip
    static var dragToScreenshot: String { s("dragToScreenshot") }

    // Toast
    static var copiedToClipboard: String { s("copiedToClipboard") }
    static var mergedLongScreenshot: String { s("mergedLongScreenshot") }
    static var autoScrollPermissionNeeded: String { s("autoScrollPermissionNeeded") }
    static var cropLongScreenshotHint: String { s("cropLongScreenshotHint") }
    static var scrollCaptureHint: String { s("scrollCaptureHint") }
    static var cancelFinderSelectionHint: String { s("cancelFinderSelectionHint") }
    static var cancelClipboardEditHint: String { s("cancelClipboardEditHint") }
    static func colorCopied(_ hex: String) -> String {
        String(format: s("colorCopied"), hex)
    }

    // Toolbar tooltips
    static var tipRectangle: String { s("tipRectangle") }
    static var tipEllipse: String { s("tipEllipse") }
    static var tipArrow: String { s("tipArrow") }
    static var tipPen: String { s("tipPen") }
    static var tipMarker: String { s("tipMarker") }
    static var tipMosaic: String { s("tipMosaic") }
    static var tipNumbered: String { s("tipNumbered") }
    static var tipText: String { s("tipText") }
    static var tipColorPicker: String { s("tipColorPicker") }
    static var tipUndo: String { s("tipUndo") }
    static var tipRedo: String { s("tipRedo") }
    static var tipMoveSelection: String { s("tipMoveSelection") }
    static var tipScrollCapture: String { s("tipScrollCapture") }
    static var tipBeautify: String { s("tipBeautify") }
    static var tipOCR: String { s("tipOCR") }
    static var tipSave: String { s("tipSave") }
    static var tipPin: String { s("tipPin") }
    static var tipCancel: String { s("tipCancel") }
    static var tipConfirm: String { s("tipConfirm") }

    // Beautify
    static var beautify: String { s("beautify") }
    static var beautifyPresetPeachBlue: String { s("beautifyPresetPeachBlue") }
    static var beautifyPresetMintTeal: String { s("beautifyPresetMintTeal") }
    static var beautifyPresetPeachPink: String { s("beautifyPresetPeachPink") }
    static var beautifyPresetBluePurple: String { s("beautifyPresetBluePurple") }
    static var beautifyPresetWarmOrange: String { s("beautifyPresetWarmOrange") }
    static var beautifyPresetTealPink: String { s("beautifyPresetTealPink") }
    static var beautifyPresetDeepPurple: String { s("beautifyPresetDeepPurple") }
    static var beautifyPresetNeutralGray: String { s("beautifyPresetNeutralGray") }
    static var beautifyPresetWallpaper: String { s("beautifyPresetWallpaper") }

    // Language
    static var languageHeader: String { s("languageHeader") }

    // Settings sidebar tabs
    static var settingsTabGeneral: String { s("settingsTabGeneral") }
    static var settingsTabShortcuts: String { s("settingsTabShortcuts") }
    static var settingsTabPermissions: String { s("settingsTabPermissions") }
    static var settingsTabUpload: String { s("settingsTabUpload") }
    static var settingsTabAbout: String { s("settingsTabAbout") }
    static var settingsTabTranslation: String { s("settingsTabTranslation") }
    static var settingsQuit: String { s("settingsQuit") }

    // About pane
    static var aboutTagline: String { s("aboutTagline") }
    static var aboutLicense: String { s("aboutLicense") }
    static var aboutSourceCode: String { s("aboutSourceCode") }
    static var aboutFeatureRequest: String { s("aboutFeatureRequest") }
    static var aboutBugReport: String { s("aboutBugReport") }
    static var aboutUpdateTitle: String { s("aboutUpdateTitle") }

    // Error log — About pane
    static var aboutErrorLog: String { s("aboutErrorLog") }
    static var aboutErrorLogNoCrash: String { s("aboutErrorLogNoCrash") }
    static func aboutErrorLogLastCrash(_ date: String) -> String {
        String(format: s("aboutErrorLogLastCrash"), date)
    }
    static var aboutErrorLogCopy: String { s("aboutErrorLogCopy") }
    static var aboutErrorLogCopied: String { s("aboutErrorLogCopied") }
    static var aboutErrorLogReveal: String { s("aboutErrorLogReveal") }
    static var aboutErrorLogEmptyBody: String { s("aboutErrorLogEmptyBody") }

    // Updates — About pane
    static var checkForUpdates: String { s("checkForUpdates") }
    static var updateChecking: String { s("updateChecking") }
    static var updateUpToDateStatus: String { s("updateUpToDateStatus") }
    static func updateNewVersionStatus(_ v: String) -> String {
        String(format: s("updateNewVersionStatus"), v)
    }
    static var updateFailedStatus: String { s("updateFailedStatus") }
    static var updateDownloadButton: String { s("updateDownloadButton") }
    static var updateRetryButton: String { s("updateRetryButton") }
    static var updateInstallNowButton: String { s("updateInstallNowButton") }
    static func updateDownloadingStatus(_ percent: Int) -> String {
        String(format: s("updateDownloadingStatus"), percent)
    }
    static var updateInstallingStatus: String { s("updateInstallingStatus") }
    static var updateInstallFailedStatus: String { s("updateInstallFailedStatus") }

    // Updates — menu bar
    static var checkForUpdatesMenu: String { s("checkForUpdatesMenu") }
    static var checkingForUpdatesMenu: String { s("checkingForUpdatesMenu") }
    static func updateAvailableMenu(_ v: String) -> String {
        String(format: s("updateAvailableMenu"), v)
    }
    static func updateDownloadingMenu(_ percent: Int) -> String {
        String(format: s("updateDownloadingMenu"), percent)
    }
    static var updateInstallingMenu: String { s("updateInstallingMenu") }
    static var updateInstallFailedMenu: String { s("updateInstallFailedMenu") }

    // Updates — progress HUD
    static var updateCheckingHUD: String { s("updateCheckingHUD") }
    static func updateDownloadingHUD(_ percent: Int) -> String {
        String(format: s("updateDownloadingHUD"), percent)
    }
    static var updateVerifyingHUD: String { s("updateVerifyingHUD") }
    static var updateUnzippingHUD: String { s("updateUnzippingHUD") }
    static var updateInstallingHUD: String { s("updateInstallingHUD") }

    // Updates — manual check result alert
    static func updateAvailableTitle(_ v: String) -> String {
        String(format: s("updateAvailableTitle"), v)
    }
    static var updateAvailableBody: String { s("updateAvailableBody") }
    static var updateUpToDateTitle: String { s("updateUpToDateTitle") }
    static func updateUpToDateBody(_ v: String) -> String {
        String(format: s("updateUpToDateBody"), v)
    }
    static var updateFailedTitle: String { s("updateFailedTitle") }
    static var updateFailedBody: String { s("updateFailedBody") }
    static var updateInstallFailedTitle: String { s("updateInstallFailedTitle") }
    static var updateInstallFailedBody: String { s("updateInstallFailedBody") }
    static var updateOpenPageButton: String { s("updateOpenPageButton") }
    static var updateSkipButton: String { s("updateSkipButton") }
    static var updateLaterButton: String { s("updateLaterButton") }
    static var updateOKButton: String { s("updateOKButton") }

    // Quit confirmation dialog
    static var quitConfirmTitle: String { s("quitConfirmTitle") }
    static var quitConfirmMessage: String { s("quitConfirmMessage") }
    static var quitConfirmAction: String { s("quitConfirmAction") }
    static var quitConfirmCancel: String { s("quitConfirmCancel") }

    // Upload — toolbar / toast / progress
    static var tipUpload: String { s("tipUpload") }
    static var uploadingTitle: String { s("uploadingTitle") }
    static var uploadCopied: String { s("uploadCopied") }
    static var uploadCopiedMarkdown: String { s("uploadCopiedMarkdown") }
    static var uploadNoProvider: String { s("uploadNoProvider") }
    static var uploadFailedPrefix: String { s("uploadFailedPrefix") }

    // Upload — settings tab
    static var uploadDefaultProvider: String { s("uploadDefaultProvider") }
    static var uploadDefaultNone: String { s("uploadDefaultNone") }
    static var uploadSetDefaultButton: String { s("uploadSetDefaultButton") }
    static var uploadSaveButton: String { s("uploadSaveButton") }
    static var uploadClearButton: String { s("uploadClearButton") }
    static var uploadSavedToast: String { s("uploadSavedToast") }
    static var uploadCurrentDefault: String { s("uploadCurrentDefault") }
    static var uploadMarkdownToggleTitle: String { s("uploadMarkdownToggleTitle") }
    static var uploadMarkdownToggleSubtitle: String { s("uploadMarkdownToggleSubtitle") }

    // Upload — provider field labels
    static var uploadFieldBucket: String { s("uploadFieldBucket") }
    static var uploadFieldBucketSpace: String { s("uploadFieldBucketSpace") }
    static var uploadFieldRegion: String { s("uploadFieldRegion") }
    static var uploadFieldRegionOptional: String { s("uploadFieldRegionOptional") }
    static var uploadFieldPathOptional: String { s("uploadFieldPathOptional") }
    static var uploadFieldCustomUrlOptional: String { s("uploadFieldCustomUrlOptional") }
    static var uploadFieldPublicDomain: String { s("uploadFieldPublicDomain") }
    static var uploadFieldEndpointArea: String { s("uploadFieldEndpointArea") }
    static var uploadFieldEndpointOptional: String { s("uploadFieldEndpointOptional") }
    static var uploadFieldAccountId: String { s("uploadFieldAccountId") }
    static var uploadTestImageFailed: String { s("uploadTestImageFailed") }

    // Upload — provider names
    static var providerTencentCOS: String { s("providerTencentCOS") }
    static var providerQiniuKodo: String { s("providerQiniuKodo") }
    static var providerAliyunOSS: String { s("providerAliyunOSS") }

    // Upload — errors
    static var uploadErrMissingConfig: String { s("uploadErrMissingConfig") }
    static var uploadErrInvalidConfigPrefix: String { s("uploadErrInvalidConfigPrefix") }
    static var uploadErrNetworkPrefix: String { s("uploadErrNetworkPrefix") }
    static func uploadErrServerPrefix(_ code: Int) -> String {
        String(format: s("uploadErrServerPrefix"), code)
    }
    static var uploadErrUnexpectedResponsePrefix: String { s("uploadErrUnexpectedResponsePrefix") }
    static func missingField(_ key: String) -> String {
        String(format: s("missingField"), key)
    }

    // Upload — test/validation pill
    static var uploadStatusUntested: String { s("uploadStatusUntested") }
    static var uploadStatusTesting: String { s("uploadStatusTesting") }
    static var uploadStatusValid: String { s("uploadStatusValid") }
    static var uploadStatusInvalid: String { s("uploadStatusInvalid") }

    // Upload — log lines
    static var uploadLogStartingTest: String { s("uploadLogStartingTest") }
    static var uploadLogConfigSaved: String { s("uploadLogConfigSaved") }
    static func uploadLogMissingFields(_ keys: [String]) -> String {
        String(format: s("uploadLogMissingFields"), keys.joined(separator: ", "))
    }
    static func uploadLogTestSucceeded(_ url: String) -> String {
        String(format: s("uploadLogTestSucceeded"), url)
    }
    static func uploadLogTestFailed(_ message: String) -> String {
        String(format: s("uploadLogTestFailed"), message)
    }
    static var uploadLogProviderDisabled: String { s("uploadLogProviderDisabled") }
    static var uploadLogConfigCleared: String { s("uploadLogConfigCleared") }

    // Permissions — status label
    static var permissionGranted: String { s("permissionGranted") }
    static var permissionNotGranted: String { s("permissionNotGranted") }

    // OCR & Translation — result panel
    static var ocrTextHeader: String { s("ocrTextHeader") }
    static var ocrRecognizing: String { s("ocrRecognizing") }
    static var ocrNoText: String { s("ocrNoText") }
    static var ocrCopy: String { s("ocrCopy") }
    static var ocrCopied: String { s("ocrCopied") }
    static var ocrRetry: String { s("ocrRetry") }
    static var ocrTranslating: String { s("ocrTranslating") }
    static var ocrTranslateFailedPrefix: String { s("ocrTranslateFailedPrefix") }
    static var ocrNoProviderTitle: String { s("ocrNoProviderTitle") }
    static var ocrNoProviderHint: String { s("ocrNoProviderHint") }
    static var ocrOpenSettings: String { s("ocrOpenSettings") }

    // Translation — settings tab
    static var translationTargetLanguage: String { s("translationTargetLanguage") }
    static var translationTargetHint: String { s("translationTargetHint") }
    static var translationProvidersHeader: String { s("translationProvidersHeader") }
    static var translationApiKey: String { s("translationApiKey") }
    static var translationModel: String { s("translationModel") }
    static var translationEndpoint: String { s("translationEndpoint") }
    static var translationEndpointOptional: String { s("translationEndpointOptional") }
    static var translationSave: String { s("translationSave") }
    static var translationClear: String { s("translationClear") }
    static var translationConfigSaved: String { s("translationConfigSaved") }
    static var translationTesting: String { s("translationTesting") }
    static var translationTestPassed: String { s("translationTestPassed") }
    static var translationTestFailed: String { s("translationTestFailed") }
    static var translationTestFailedTitle: String { s("translationTestFailedTitle") }
    static var translationProviderCustom: String { s("translationProviderCustom") }

    // Translation — target language names
    static var transLangChinese: String { s("transLangChinese") }
    static var transLangEnglish: String { s("transLangEnglish") }
    static var transLangJapanese: String { s("transLangJapanese") }
    static var transLangKorean: String { s("transLangKorean") }

    // Translation — errors
    static var translationErrMissingAPIKey: String { s("translationErrMissingAPIKey") }
    static var translationErrBadEndpoint: String { s("translationErrBadEndpoint") }
    static var translationErrBadResponse: String { s("translationErrBadResponse") }
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

    // Custom screenshot hotkey. When the key is absent, no custom hotkey is set
    // (fall back to double-tap ⌘). keyCode 0 is a valid value — it is the `A` key
    // (kVK_ANSI_A) — so presence must be checked via `hasCustomScreenshotHotkey`,
    // never by comparing the key code to 0.
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
        defaults.object(forKey: "screenshotHotkeyKeyCode") != nil
    }

    static func clearScreenshotHotkey() {
        defaults.removeObject(forKey: "screenshotHotkeyKeyCode")
        defaults.removeObject(forKey: "screenshotHotkeyModifiers")
    }

    // Custom pin-image hotkey. Pressing it pins the image selected in Finder or
    // held on the clipboard onto the screen. It has no default — when the key
    // is absent the hotkey is simply unregistered. Presence must be checked via
    // `hasCustomPinHotkey` since key code 0 (`A`) is a valid value.
    // Modifiers are stored using Carbon flags, same as the screenshot hotkey.

    static var pinHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "pinHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "pinHotkeyKeyCode") }
    }

    static var pinHotkeyModifiers: Int {
        get { defaults.integer(forKey: "pinHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "pinHotkeyModifiers") }
    }

    static var hasCustomPinHotkey: Bool {
        defaults.object(forKey: "pinHotkeyKeyCode") != nil
    }

    static func clearPinHotkey() {
        defaults.removeObject(forKey: "pinHotkeyKeyCode")
        defaults.removeObject(forKey: "pinHotkeyModifiers")
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

    static let countdownSecondsMin: Int = 3
    static let countdownSecondsMax: Int = 10

    static var countdownSeconds: Int {
        get {
            if defaults.object(forKey: "countdownSeconds") == nil {
                return countdownSecondsMin
            }
            let val = defaults.integer(forKey: "countdownSeconds")
            return min(max(val, countdownSecondsMin), countdownSecondsMax)
        }
        set {
            let clamped = min(max(newValue, countdownSecondsMin), countdownSecondsMax)
            defaults.set(clamped, forKey: "countdownSeconds")
        }
    }

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
            // Explicit user choice wins; otherwise follow the system locale on
            // first launch so a fresh install opens in a familiar language.
            if let raw = defaults.string(forKey: "appLanguage"),
               let lang = AppLanguage(rawValue: raw) {
                return lang
            }
            return AppLanguage.systemDefault
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
