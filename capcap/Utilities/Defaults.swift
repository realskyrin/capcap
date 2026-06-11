import Foundation

/// A language the app's UI can be displayed in. Raw values double as the
/// `appLanguage` UserDefaults value (kept stable for backward compatibility).
enum AppLanguage: String, CaseIterable {
    case zh
    case zhTW = "zh-Hant"
    case en
    case ja
    case ko
    case fr
    case ru
    case vi

    /// Folder name (without extension) of the matching `.lproj` bundle inside
    /// `capcap.app/Contents/Resources/`.
    var lprojName: String {
        switch self {
        case .zh: return "zh-Hans"
        case .zhTW: return "zh-Hant"
        default:  return rawValue
        }
    }

    /// Native language name shown in the in-app language picker.
    var displayName: String {
        switch self {
        case .zh: return "简体中文"
        case .zhTW: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .ru: return "Русский"
        case .vi: return "Tiếng Việt"
        }
    }

    /// Best-effort match of the system's preferred languages to a supported
    /// app language — used on first launch before the user picks explicitly.
    static var systemDefault: AppLanguage {
        for code in Locale.preferredLanguages {
            let lower = code.lowercased()
            if lower.hasPrefix("zh-hant") ||
                lower.hasPrefix("zh-tw") ||
                lower.hasPrefix("zh-hk") ||
                lower.hasPrefix("zh-mo") {
                return .zhTW
            }
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("ko") { return .ko }
            if lower.hasPrefix("fr") { return .fr }
            if lower.hasPrefix("ru") { return .ru }
            if lower.hasPrefix("vi") { return .vi }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("capcap.languageDidChange")
    static let historyCacheEnabledDidChange = Notification.Name("capcap.historyCacheEnabledDidChange")
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
    static var pinAcrossSpaces: String { s("pinAcrossSpaces") }
    static var pinAcrossSpacesHint: String { s("pinAcrossSpacesHint") }
    static var historyCacheToggleLabel: String { s("historyCacheToggleLabel") }
    static var historyCacheToggleHint: String { s("historyCacheToggleHint") }
    static var historyCacheLabel: String { s("historyCacheLabel") }
    static var historyCacheHint: String { s("historyCacheHint") }
    static var countdownLabel: String { s("countdownLabel") }
    static var countdownHint: String { s("countdownHint") }
    static var countdownSecondsSuffix: String { s("countdownSecondsSuffix") }
    static var windowShadowToggleLabel: String { s("windowShadowToggleLabel") }
    static var windowShadowToggleHint: String { s("windowShadowToggleHint") }
    static var windowShadowSizeLabel: String { s("windowShadowSizeLabel") }
    static var windowShadowSizeHint: String { s("windowShadowSizeHint") }
    static var savePathTitle: String { s("savePathTitle") }
    static var savePathSubtitle: String { s("savePathSubtitle") }
    static var autoRevealSavedFilesLabel: String { s("autoRevealSavedFilesLabel") }
    static var autoRevealSavedFilesHint: String { s("autoRevealSavedFilesHint") }
    static var recordingSavePathLabel: String { s("recordingSavePathLabel") }
    static var recordingSaveFormatSettingLabel: String { s("recordingSaveFormatSettingLabel") }
    static var screenshotSavePathLabel: String { s("screenshotSavePathLabel") }
    static var savePathChoose: String { s("savePathChoose") }
    static var savePathReveal: String { s("savePathReveal") }
    static var chooseRecordingSavePathTitle: String { s("chooseRecordingSavePathTitle") }
    static var chooseScreenshotSavePathTitle: String { s("chooseScreenshotSavePathTitle") }

    // Screenshot shortcut
    static var shortcutHeader: String { s("shortcutHeader") }
    static var shortcutHint: String { s("shortcutHint") }
    static var shortcutDefaultDisplay: String { s("shortcutDefaultDisplay") }
    static var shortcutSet: String { s("shortcutSet") }
    static var shortcutCancel: String { s("shortcutCancel") }
    static var shortcutWaiting: String { s("shortcutWaiting") }
    static var shortcutRestore: String { s("shortcutRestore") }

    // Pin-image shortcut
    static var selectedImagePinShortcutHeader: String { s("selectedImagePinShortcutHeader") }
    static var selectedImagePinShortcutDefaultDisplay: String { s("selectedImagePinShortcutDefaultDisplay") }
    static var selectedImagePinShortcutClear: String { s("selectedImagePinShortcutClear") }
    static var clipboardImagePinShortcutHeader: String { s("clipboardImagePinShortcutHeader") }
    static var clipboardImagePinShortcutDefaultDisplay: String { s("clipboardImagePinShortcutDefaultDisplay") }
    static var clipboardImagePinShortcutClear: String { s("clipboardImagePinShortcutClear") }
    static var selectedImagePinNoImage: String { s("selectedImagePinNoImage") }
    static var clipboardImagePinNoImage: String { s("clipboardImagePinNoImage") }
    static var pinFromFinderHint: String { s("pinFromFinderHint") }
    static var pinFromClipboardHint: String { s("pinFromClipboardHint") }
    static var pinToolbarEdit: String { s("pinToolbarEdit") }

    // Image-edit shortcuts
    static var selectedImageEditShortcutHeader: String { s("selectedImageEditShortcutHeader") }
    static var selectedImageEditShortcutHint: String { s("selectedImageEditShortcutHint") }
    static var selectedImageEditShortcutDefaultDisplay: String { s("selectedImageEditShortcutDefaultDisplay") }
    static var clipboardImageEditShortcutHeader: String { s("clipboardImageEditShortcutHeader") }
    static var clipboardImageEditShortcutHint: String { s("clipboardImageEditShortcutHint") }
    static var clipboardImageEditShortcutDefaultDisplay: String { s("clipboardImageEditShortcutDefaultDisplay") }
    static var textRecognitionShortcutHeader: String { s("textRecognitionShortcutHeader") }
    static var textRecognitionShortcutDefaultDisplay: String { s("textRecognitionShortcutDefaultDisplay") }
    static var copyImageTextShortcutHeader: String { s("copyImageTextShortcutHeader") }
    static var copyImageTextShortcutDefaultDisplay: String { s("copyImageTextShortcutDefaultDisplay") }
    static var screenshotTranslationShortcutHeader: String { s("screenshotTranslationShortcutHeader") }
    static var screenshotTranslationShortcutDefaultDisplay: String { s("screenshotTranslationShortcutDefaultDisplay") }
    static var recordShortcutHeader: String { s("recordShortcutHeader") }
    static var recordShortcutDefaultDisplay: String { s("recordShortcutDefaultDisplay") }
    static var imageMergeShortcutHeader: String { s("imageMergeShortcutHeader") }
    static var imageMergeShortcutDefaultDisplay: String { s("imageMergeShortcutDefaultDisplay") }
    static var fullScreenScreenshotShortcutHeader: String { s("fullScreenScreenshotShortcutHeader") }
    static var fullScreenScreenshotShortcutDefaultDisplay: String { s("fullScreenScreenshotShortcutDefaultDisplay") }
    static var colorPickerShortcutHeader: String { s("colorPickerShortcutHeader") }
    static var colorPickerShortcutDefaultDisplay: String { s("colorPickerShortcutDefaultDisplay") }

    // Copy-to-clipboard shortcut (editor confirm)
    static var clipboardShortcutHeader: String { s("clipboardShortcutHeader") }
    static var clipboardShortcutHint: String { s("clipboardShortcutHint") }
    static var clipboardShortcutDefaultDisplay: String { s("clipboardShortcutDefaultDisplay") }

    // History navigation shortcuts (editor)
    static var previousHistoryImageShortcutHeader: String { s("previousHistoryImageShortcutHeader") }
    static var nextHistoryImageShortcutHeader: String { s("nextHistoryImageShortcutHeader") }

    // Save-to-file shortcut (editor save)
    static var fileSaveShortcutHeader: String { s("fileSaveShortcutHeader") }
    static var fileSaveShortcutHint: String { s("fileSaveShortcutHint") }

    // Shortcut conflict
    static var shortcutConflictTitle: String { s("shortcutConflictTitle") }
    static var shortcutConflictScreenshot: String { s("shortcutConflictScreenshot") }
    static var shortcutConflictCountdown: String { s("shortcutConflictCountdown") }
    static var shortcutConflictSelectedImagePin: String { s("shortcutConflictSelectedImagePin") }
    static var shortcutConflictClipboardImagePin: String { s("shortcutConflictClipboardImagePin") }
    static var shortcutConflictClipboard: String { s("shortcutConflictClipboard") }
    static var shortcutConflictFileSave: String { s("shortcutConflictFileSave") }
    static var shortcutConflictPreviousHistoryImage: String { s("shortcutConflictPreviousHistoryImage") }
    static var shortcutConflictNextHistoryImage: String { s("shortcutConflictNextHistoryImage") }
    static var shortcutConflictSelectedImageEdit: String { s("shortcutConflictSelectedImageEdit") }
    static var shortcutConflictClipboardImageEdit: String { s("shortcutConflictClipboardImageEdit") }
    static var shortcutConflictTextRecognition: String { s("shortcutConflictTextRecognition") }
    static var shortcutConflictCopyImageText: String { s("shortcutConflictCopyImageText") }
    static var shortcutConflictScreenshotTranslation: String { s("shortcutConflictScreenshotTranslation") }
    static var shortcutConflictRecord: String { s("shortcutConflictRecord") }
    static var shortcutConflictImageMerge: String { s("shortcutConflictImageMerge") }
    static var shortcutConflictFullScreenScreenshot: String { s("shortcutConflictFullScreenScreenshot") }
    static var shortcutConflictColorPicker: String { s("shortcutConflictColorPicker") }

    // Menu bar
    static var takeScreenshot: String { s("takeScreenshot") }
    static var takeFullScreenScreenshot: String { s("takeFullScreenScreenshot") }
    static var record: String { s("record") }
    static var mergeImages: String { s("mergeImages") }
    static var colorPicker: String { s("colorPicker") }
    static var settings: String { s("settings") }
    static var quitApp: String { s("quitApp") }
    static var historyMenu: String { s("historyMenu") }
    static var historyEmpty: String { s("historyEmpty") }
    static var historyClear: String { s("historyClear") }
    static var historyShowInFinder: String { s("historyShowInFinder") }
    static var historyCloudMarkdownTip: String { s("historyCloudMarkdownTip") }

    // Cursor chip
    static var dragToScreenshot: String { s("dragToScreenshot") }
    static var dragToTextRecognition: String { s("dragToTextRecognition") }
    static var dragToCopyImageText: String { s("dragToCopyImageText") }
    static var dragToScreenshotTranslation: String { s("dragToScreenshotTranslation") }
    static var dragToRecord: String { s("dragToRecord") }

    // Toast
    static var copiedToClipboard: String { s("copiedToClipboard") }
    static var mergedLongScreenshot: String { s("mergedLongScreenshot") }
    static var autoScrollPermissionNeeded: String { s("autoScrollPermissionNeeded") }
    static var cropLongScreenshotHint: String { s("cropLongScreenshotHint") }
    static var scrollCaptureHint: String { s("scrollCaptureHint") }
    static var scrollCaptureManualHint: String { s("scrollCaptureManualHint") }
    static var finderEditExitHint: String { s("finderEditExitHint") }
    static var clipboardEditExitHint: String { s("clipboardEditExitHint") }
    static var pinEditExitHint: String { s("pinEditExitHint") }
    static var fullScreenEditExitHint: String { s("fullScreenEditExitHint") }
    static var fullScreenScreenshotFailed: String { s("fullScreenScreenshotFailed") }
    static var selectedImageEditNoImage: String { s("selectedImageEditNoImage") }
    static var clipboardImageEditNoImage: String { s("clipboardImageEditNoImage") }
    static var mergeEditExitHint: String { s("mergeEditExitHint") }
    static var imageMergeNeedTwoImages: String { s("imageMergeNeedTwoImages") }
    static var imageMergeSomeImagesSkipped: String { s("imageMergeSomeImagesSkipped") }
    static var imageMergeNoClipboardImage: String { s("imageMergeNoClipboardImage") }
    static var imageMergeFailed: String { s("imageMergeFailed") }
    static var imageMergeSaved: String { s("imageMergeSaved") }
    static func recordingSaved(to path: String) -> String {
        String(format: s("recordingSaved"), path)
    }
    static var recordingCancelled: String { s("recordingCancelled") }
    static var recordingExportingGIF: String { s("recordingExportingGIF") }
    static var saveRecording: String { s("saveRecording") }
    static var saveRecordingPrompt: String { s("saveRecordingPrompt") }
    static var recordingFormatLabel: String { s("recordingFormatLabel") }
    static var recordingFormatManual: String { s("recordingFormatManual") }
    static var recordingFormatMP4: String { s("recordingFormatMP4") }
    static var recordingFormatGIF: String { s("recordingFormatGIF") }
    static var recordingFormatChoiceTitle: String { s("recordingFormatChoiceTitle") }
    static var recordingFormatChoiceMessage: String { s("recordingFormatChoiceMessage") }
    static func screenshotSaved(to path: String) -> String {
        String(format: s("screenshotSaved"), path)
    }
    static var recordingStop: String { s("recordingStop") }
    static var recordingPause: String { s("recordingPause") }
    static var recordingResume: String { s("recordingResume") }
    static func recordingFailed(_ message: String) -> String {
        String(format: s("recordingFailed"), message)
    }
    static func screenshotSaveFailed(_ message: String) -> String {
        String(format: s("screenshotSaveFailed"), message)
    }
    static func colorCopied(_ hex: String) -> String {
        String(format: s("colorCopied"), hex)
    }

    // Toolbar tooltips
    static var tipRectangle: String { s("tipRectangle") }
    static var tipEllipse: String { s("tipEllipse") }
    static var tipArrow: String { s("tipArrow") }
    static var tipLine: String { s("tipLine") }
    static var tipPen: String { s("tipPen") }
    static var tipMarker: String { s("tipMarker") }
    static var tipMosaic: String { s("tipMosaic") }
    static var mosaicGranularity: String { s("mosaicGranularity") }
    static var tipEraser: String { s("tipEraser") }
    static var tipMagnifier: String { s("tipMagnifier") }
    static var tipNumbered: String { s("tipNumbered") }
    static var tipText: String { s("tipText") }
    static var tipEmoji: String { s("tipEmoji") }
    static var tipMoreEmoji: String { s("tipMoreEmoji") }
    static var tipInsertImage: String { s("tipInsertImage") }
    static var tipColorPicker: String { s("tipColorPicker") }
    static var tipPickedInkBottle: String { s("tipPickedInkBottle") }
    static var tipUndo: String { s("tipUndo") }
    static var tipRedo: String { s("tipRedo") }
    static var tipMoveSelection: String { s("tipMoveSelection") }
    static var tipScrollCapture: String { s("tipScrollCapture") }
    static var tipBeautify: String { s("tipBeautify") }
    static var tipOCR: String { s("tipOCR") }
    static var tipScreenshotTranslate: String { s("tipScreenshotTranslate") }
    static var tipSave: String { s("tipSave") }
    static var tipPin: String { s("tipPin") }
    static var tipRecord: String { s("tipRecord") }
    static var tipCancel: String { s("tipCancel") }
    static var tipConfirm: String { s("tipConfirm") }
    static var tipScrollCropConfirm: String { s("tipScrollCropConfirm") }

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
    static var beautifyShadowEffect: String { s("beautifyShadowEffect") }

    // Text tool
    static var textStrokeEffect: String { s("textStrokeEffect") }
    static var textCalloutEffect: String { s("textCalloutEffect") }

    // Shape tool
    static var shapeFillEffect: String { s("shapeFillEffect") }
    static var shapeFillNone: String { s("shapeFillNone") }
    static var shapeFillOpaque: String { s("shapeFillOpaque") }
    static var shapeFillTranslucent: String { s("shapeFillTranslucent") }
    static var shapeStyleStandard: String { s("shapeStyleStandard") }
    static var shapeStyleHandDrawn: String { s("shapeStyleHandDrawn") }

    // Insert tools
    static var insertImageFromClipboard: String { s("insertImageFromClipboard") }
    static var insertImageFromFile: String { s("insertImageFromFile") }
    static var insertImageChooseFile: String { s("insertImageChooseFile") }
    static var insertImageNoClipboardImage: String { s("insertImageNoClipboardImage") }
    static var scrollCaptureAutoScroll: String { s("scrollCaptureAutoScroll") }
    static var scrollCaptureManualScroll: String { s("scrollCaptureManualScroll") }

    // Language
    static var languageHeader: String { s("languageHeader") }

    // Settings sidebar tabs
    static var settingsTabGeneral: String { s("settingsTabGeneral") }
    static var settingsTabShortcuts: String { s("settingsTabShortcuts") }
    static var settingsTabPermissions: String { s("settingsTabPermissions") }
    static var settingsTabUpload: String { s("settingsTabUpload") }
    static var settingsTabAbout: String { s("settingsTabAbout") }
    static var settingsTabTranslation: String { s("settingsTabTranslation") }
    static var settingsTabToolbar: String { s("settingsTabToolbar") }
    static var settingsQuit: String { s("settingsQuit") }

    // Toolbar settings
    static var toolbarSettingsPrimaryTitle: String { s("toolbarSettingsPrimaryTitle") }
    static var toolbarSettingsPrimaryHint: String { s("toolbarSettingsPrimaryHint") }
    static var toolbarSettingsSideTitle: String { s("toolbarSettingsSideTitle") }
    static var toolbarSettingsSideHint: String { s("toolbarSettingsSideHint") }
    static var toolbarSettingsHiddenTitle: String { s("toolbarSettingsHiddenTitle") }
    static var toolbarSettingsHiddenHint: String { s("toolbarSettingsHiddenHint") }
    static var toolbarSettingsFootnote: String { s("toolbarSettingsFootnote") }
    static var toolbarSettingsReset: String { s("toolbarSettingsReset") }
    static var toolbarSettingsCancel: String { s("toolbarSettingsCancel") }
    static var toolbarSettingsApply: String { s("toolbarSettingsApply") }

    // About pane
    static var aboutTagline: String { s("aboutTagline") }
    static var aboutLicense: String { s("aboutLicense") }
    static var aboutSourceCode: String { s("aboutSourceCode") }
    static var aboutStarOnGitHub: String { s("aboutStarOnGitHub") }
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
    static var aboutErrorLogRefresh: String { s("aboutErrorLogRefresh") }
    static var aboutErrorLogClear: String { s("aboutErrorLogClear") }
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
    static var filenameRuleTitle: String { s("filenameRuleTitle") }
    static var filenameRuleSubtitle: String { s("filenameRuleSubtitle") }
    static var filenameRulePresetLabel: String { s("filenameRulePresetLabel") }
    static var filenameRulePresetCustom: String { s("filenameRulePresetCustom") }
    static var filenameRulePresetShort: String { s("filenameRulePresetShort") }
    static var filenameRulePresetCompact: String { s("filenameRulePresetCompact") }
    static var filenameRulePresetUnique: String { s("filenameRulePresetUnique") }
    static var filenameRulePresetCounter: String { s("filenameRulePresetCounter") }
    static var filenameRulePresetRestore: String { s("filenameRulePresetRestore") }
    static var filenameRuleImageLabel: String { s("filenameRuleImageLabel") }
    static var filenameRuleRecordingLabel: String { s("filenameRuleRecordingLabel") }
    static var filenameRuleVariablesLabel: String { s("filenameRuleVariablesLabel") }
    static var filenameRuleVariableDate: String { s("filenameRuleVariableDate") }
    static var filenameRuleVariableTime: String { s("filenameRuleVariableTime") }
    static var filenameRuleVariableDaily: String { s("filenameRuleVariableDaily") }
    static var filenameRuleVariableRandom: String { s("filenameRuleVariableRandom") }
    static var filenameRuleVariableSize: String { s("filenameRuleVariableSize") }
    static func filenameRulePreview(_ value: String) -> String {
        String(format: s("filenameRulePreview"), value)
    }

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
    static var ocrLineCopied: String { s("ocrLineCopied") }
    static var copyImageTextCopying: String { s("copyImageTextCopying") }
    static var copyImageTextCopied: String { s("copyImageTextCopied") }
    static var copyImageTextNoText: String { s("copyImageTextNoText") }
    static var screenshotTranslationHeader: String { s("screenshotTranslationHeader") }
    static func screenshotTranslationLanguageButton(_ language: String) -> String {
        String(format: s("screenshotTranslationLanguageButton"), language)
    }
    static var dictionaryEntryLabel: String { s("dictionaryEntryLabel") }
    static var dictionaryPhoneticLabel: String { s("dictionaryPhoneticLabel") }
    static var dictionaryPartOfSpeechLabel: String { s("dictionaryPartOfSpeechLabel") }
    static var dictionaryDefinitionLabel: String { s("dictionaryDefinitionLabel") }
    static var dictionaryExampleLabel: String { s("dictionaryExampleLabel") }
    static var dictionaryDifficultyLabel: String { s("dictionaryDifficultyLabel") }
    static var dictionaryNoProviderTitle: String { s("dictionaryNoProviderTitle") }
    static var dictionaryNoProviderHint: String { s("dictionaryNoProviderHint") }

    // Translation — settings tab
    static var translationDictionaryModeTitle: String { s("translationDictionaryModeTitle") }
    static var translationDictionaryModeSubtitle: String { s("translationDictionaryModeSubtitle") }
    static var translationTargetLanguage: String { s("translationTargetLanguage") }
    static var translationTargetHint: String { s("translationTargetHint") }
    static var translationProvidersHeader: String { s("translationProvidersHeader") }
    static var translationApiKey: String { s("translationApiKey") }
    static var translationApiKeyOptional: String { s("translationApiKeyOptional") }
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
    static var translationMoveUp: String { s("translationMoveUp") }
    static var translationMoveDown: String { s("translationMoveDown") }

    // Translation — target language names
    static var transLangChinese: String { s("transLangChinese") }
    static var transLangEnglish: String { s("transLangEnglish") }
    static var transLangJapanese: String { s("transLangJapanese") }
    static var transLangKorean: String { s("transLangKorean") }

    // Translation — errors
    static var translationErrMissingAPIKey: String { s("translationErrMissingAPIKey") }
    static var translationErrBadEndpoint: String { s("translationErrBadEndpoint") }
    static var translationErrBadResponse: String { s("translationErrBadResponse") }

    // Image Merge workbench
    static var imageMergeWindowTitle: String { s("imageMergeWindowTitle") }
    static var imageMergeSources: String { s("imageMergeSources") }
    static var imageMergeAddFiles: String { s("imageMergeAddFiles") }
    static var imageMergeAddFromClipboard: String { s("imageMergeAddFromClipboard") }
    static var imageMergeImageList: String { s("imageMergeImageList") }
    static var imageMergeTemplate: String { s("imageMergeTemplate") }
    static var imageMergeTemplateHorizontal: String { s("imageMergeTemplateHorizontal") }
    static var imageMergeTemplateVertical: String { s("imageMergeTemplateVertical") }
    static var imageMergeTemplateGrid: String { s("imageMergeTemplateGrid") }
    static var imageMergeTemplateLongStitch: String { s("imageMergeTemplateLongStitch") }
    static var imageMergeLayout: String { s("imageMergeLayout") }
    static var imageMergeSpacing: String { s("imageMergeSpacing") }
    static var imageMergeMargin: String { s("imageMergeMargin") }
    static var imageMergeCornerRadius: String { s("imageMergeCornerRadius") }
    static var imageMergeBackground: String { s("imageMergeBackground") }
    static var imageMergeTransparent: String { s("imageMergeTransparent") }
    static var imageMergeSolid: String { s("imageMergeSolid") }
    static var imageMergeOutput: String { s("imageMergeOutput") }
    static var imageMergeCopy: String { s("imageMergeCopy") }
    static var imageMergeSave: String { s("imageMergeSave") }
    static var imageMergeContinueEditing: String { s("imageMergeContinueEditing") }
    static var imageMergeClose: String { s("imageMergeClose") }
    static var imageMergeEmptyTitle: String { s("imageMergeEmptyTitle") }
    static var imageMergeEmptyBody: String { s("imageMergeEmptyBody") }
    static var imageMergeClipboardSourceName: String { s("imageMergeClipboardSourceName") }
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

    private static func clearLegacyPinHotkey() {
        defaults.removeObject(forKey: "pinHotkeyKeyCode")
        defaults.removeObject(forKey: "pinHotkeyModifiers")
    }

    // Custom pin-image hotkeys. They are global Carbon hotkeys with no
    // defaults: users opt in from Settings. The selected-image shortcut reads
    // images selected in Finder; the clipboard-image shortcut reads only the
    // clipboard image.

    static var selectedImagePinHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "selectedImagePinHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "selectedImagePinHotkeyKeyCode") }
    }

    static var selectedImagePinHotkeyModifiers: Int {
        get { defaults.integer(forKey: "selectedImagePinHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "selectedImagePinHotkeyModifiers") }
    }

    static var hasCustomSelectedImagePinHotkey: Bool {
        defaults.object(forKey: "selectedImagePinHotkeyKeyCode") != nil
    }

    static func clearSelectedImagePinHotkey() {
        defaults.removeObject(forKey: "selectedImagePinHotkeyKeyCode")
        defaults.removeObject(forKey: "selectedImagePinHotkeyModifiers")
    }

    static var clipboardImagePinHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "clipboardImagePinHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "clipboardImagePinHotkeyKeyCode") }
    }

    static var clipboardImagePinHotkeyModifiers: Int {
        get { defaults.integer(forKey: "clipboardImagePinHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "clipboardImagePinHotkeyModifiers") }
    }

    static var hasCustomClipboardImagePinHotkey: Bool {
        defaults.object(forKey: "clipboardImagePinHotkeyKeyCode") != nil
    }

    static func clearClipboardImagePinHotkey() {
        defaults.removeObject(forKey: "clipboardImagePinHotkeyKeyCode")
        defaults.removeObject(forKey: "clipboardImagePinHotkeyModifiers")
    }

    static func resetShortcutHotkeysToDefaults() {
        clearScreenshotHotkey()
        clearLegacyPinHotkey()
        clearSelectedImagePinHotkey()
        clearClipboardImagePinHotkey()
        clearSelectedImageEditHotkey()
        clearClipboardImageEditHotkey()
        clearTextRecognitionHotkey()
        clearCopyImageTextHotkey()
        clearScreenshotTranslationHotkey()
        clearRecordHotkey()
        clearImageMergeHotkey()
        clearFullScreenScreenshotHotkey()
        clearColorPickerHotkey()
        clearClipboardHotkey()
        clearFileSaveHotkey()
        clearPreviousHistoryImageHotkey()
        clearNextHistoryImageHotkey()
    }

    // Custom image-edit hotkeys. They are global Carbon hotkeys with no
    // defaults: users opt in from Settings. The selected-image shortcut reads
    // one image selected in Finder; the clipboard-image shortcut reads only
    // the clipboard image.

    static var selectedImageEditHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "selectedImageEditHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "selectedImageEditHotkeyKeyCode") }
    }

    static var selectedImageEditHotkeyModifiers: Int {
        get { defaults.integer(forKey: "selectedImageEditHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "selectedImageEditHotkeyModifiers") }
    }

    static var hasCustomSelectedImageEditHotkey: Bool {
        defaults.object(forKey: "selectedImageEditHotkeyKeyCode") != nil
    }

    static func clearSelectedImageEditHotkey() {
        defaults.removeObject(forKey: "selectedImageEditHotkeyKeyCode")
        defaults.removeObject(forKey: "selectedImageEditHotkeyModifiers")
    }

    static var clipboardImageEditHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "clipboardImageEditHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "clipboardImageEditHotkeyKeyCode") }
    }

    static var clipboardImageEditHotkeyModifiers: Int {
        get { defaults.integer(forKey: "clipboardImageEditHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "clipboardImageEditHotkeyModifiers") }
    }

    static var hasCustomClipboardImageEditHotkey: Bool {
        defaults.object(forKey: "clipboardImageEditHotkeyKeyCode") != nil
    }

    static func clearClipboardImageEditHotkey() {
        defaults.removeObject(forKey: "clipboardImageEditHotkeyKeyCode")
        defaults.removeObject(forKey: "clipboardImageEditHotkeyModifiers")
    }

    // Custom OCR/translation hotkeys. They are global Carbon hotkeys with no
    // defaults: users opt in from Settings, then select a region that is sent
    // straight to the corresponding result panel.

    static var textRecognitionHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "textRecognitionHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "textRecognitionHotkeyKeyCode") }
    }

    static var textRecognitionHotkeyModifiers: Int {
        get { defaults.integer(forKey: "textRecognitionHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "textRecognitionHotkeyModifiers") }
    }

    static var hasCustomTextRecognitionHotkey: Bool {
        defaults.object(forKey: "textRecognitionHotkeyKeyCode") != nil
    }

    static func clearTextRecognitionHotkey() {
        defaults.removeObject(forKey: "textRecognitionHotkeyKeyCode")
        defaults.removeObject(forKey: "textRecognitionHotkeyModifiers")
    }

    static var copyImageTextHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "copyImageTextHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "copyImageTextHotkeyKeyCode") }
    }

    static var copyImageTextHotkeyModifiers: Int {
        get { defaults.integer(forKey: "copyImageTextHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "copyImageTextHotkeyModifiers") }
    }

    static var hasCustomCopyImageTextHotkey: Bool {
        defaults.object(forKey: "copyImageTextHotkeyKeyCode") != nil
    }

    static func clearCopyImageTextHotkey() {
        defaults.removeObject(forKey: "copyImageTextHotkeyKeyCode")
        defaults.removeObject(forKey: "copyImageTextHotkeyModifiers")
    }

    static var screenshotTranslationHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "screenshotTranslationHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "screenshotTranslationHotkeyKeyCode") }
    }

    static var screenshotTranslationHotkeyModifiers: Int {
        get { defaults.integer(forKey: "screenshotTranslationHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "screenshotTranslationHotkeyModifiers") }
    }

    static var hasCustomScreenshotTranslationHotkey: Bool {
        defaults.object(forKey: "screenshotTranslationHotkeyKeyCode") != nil
    }

    static func clearScreenshotTranslationHotkey() {
        defaults.removeObject(forKey: "screenshotTranslationHotkeyKeyCode")
        defaults.removeObject(forKey: "screenshotTranslationHotkeyModifiers")
    }

    static var recordHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "recordHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "recordHotkeyKeyCode") }
    }

    static var recordHotkeyModifiers: Int {
        get { defaults.integer(forKey: "recordHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "recordHotkeyModifiers") }
    }

    static var hasCustomRecordHotkey: Bool {
        defaults.object(forKey: "recordHotkeyKeyCode") != nil
    }

    static func clearRecordHotkey() {
        defaults.removeObject(forKey: "recordHotkeyKeyCode")
        defaults.removeObject(forKey: "recordHotkeyModifiers")
    }

    static var imageMergeHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "imageMergeHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "imageMergeHotkeyKeyCode") }
    }

    static var imageMergeHotkeyModifiers: Int {
        get { defaults.integer(forKey: "imageMergeHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "imageMergeHotkeyModifiers") }
    }

    static var hasCustomImageMergeHotkey: Bool {
        defaults.object(forKey: "imageMergeHotkeyKeyCode") != nil
    }

    static func clearImageMergeHotkey() {
        defaults.removeObject(forKey: "imageMergeHotkeyKeyCode")
        defaults.removeObject(forKey: "imageMergeHotkeyModifiers")
    }

    static var fullScreenScreenshotHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "fullScreenScreenshotHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "fullScreenScreenshotHotkeyKeyCode") }
    }

    static var fullScreenScreenshotHotkeyModifiers: Int {
        get { defaults.integer(forKey: "fullScreenScreenshotHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "fullScreenScreenshotHotkeyModifiers") }
    }

    static var hasCustomFullScreenScreenshotHotkey: Bool {
        defaults.object(forKey: "fullScreenScreenshotHotkeyKeyCode") != nil
    }

    static func clearFullScreenScreenshotHotkey() {
        defaults.removeObject(forKey: "fullScreenScreenshotHotkeyKeyCode")
        defaults.removeObject(forKey: "fullScreenScreenshotHotkeyModifiers")
    }

    static var colorPickerHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "colorPickerHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "colorPickerHotkeyKeyCode") }
    }

    static var colorPickerHotkeyModifiers: Int {
        get { defaults.integer(forKey: "colorPickerHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "colorPickerHotkeyModifiers") }
    }

    static var hasCustomColorPickerHotkey: Bool {
        defaults.object(forKey: "colorPickerHotkeyKeyCode") != nil
    }

    static func clearColorPickerHotkey() {
        defaults.removeObject(forKey: "colorPickerHotkeyKeyCode")
        defaults.removeObject(forKey: "colorPickerHotkeyModifiers")
    }

    static var imageMergeTemplate: ImageMergeTemplate {
        get {
            let rawValue = defaults.integer(forKey: "imageMergeTemplate")
            return ImageMergeTemplate(rawValue: rawValue) ?? .horizontal
        }
        set {
            defaults.set(newValue.rawValue, forKey: "imageMergeTemplate")
        }
    }

    static var imageMergeSpacing: Double {
        get {
            if defaults.object(forKey: "imageMergeSpacing") == nil {
                return 12
            }
            return min(max(defaults.double(forKey: "imageMergeSpacing"), 0), 80)
        }
        set {
            defaults.set(min(max(newValue.rounded(), 0), 80), forKey: "imageMergeSpacing")
        }
    }

    static var imageMergeMargin: Double {
        get {
            if defaults.object(forKey: "imageMergeMargin") == nil {
                return 24
            }
            return min(max(defaults.double(forKey: "imageMergeMargin"), 0), 120)
        }
        set {
            defaults.set(min(max(newValue.rounded(), 0), 120), forKey: "imageMergeMargin")
        }
    }

    static var imageMergeCornerRadius: Double {
        get {
            if defaults.object(forKey: "imageMergeCornerRadius") == nil {
                return 0
            }
            return min(max(defaults.double(forKey: "imageMergeCornerRadius"), 0), 80)
        }
        set {
            defaults.set(min(max(newValue.rounded(), 0), 80), forKey: "imageMergeCornerRadius")
        }
    }

    static var imageMergeBackgroundIsSolid: Bool {
        get { defaults.bool(forKey: "imageMergeBackgroundIsSolid") }
        set { defaults.set(newValue, forKey: "imageMergeBackgroundIsSolid") }
    }

    static var imageMergeBackgroundColorHex: String {
        get {
            normalizedHexColor(defaults.string(forKey: "imageMergeBackgroundColorHex")) ?? "#FFFFFF"
        }
        set {
            defaults.set(normalizedHexColor(newValue) ?? "#FFFFFF", forKey: "imageMergeBackgroundColorHex")
        }
    }

    static var recordingSaveFormat: ScreenRecordingFormat {
        get {
            guard let raw = defaults.string(forKey: "recordingSaveFormat"),
                  let format = ScreenRecordingFormat(rawValue: raw)
            else {
                return .mp4
            }
            return format
        }
        set {
            defaults.set(newValue.rawValue, forKey: "recordingSaveFormat")
        }
    }

    static var recordingSavePreference: RecordingSavePreference {
        get {
            guard let raw = defaults.string(forKey: "recordingSavePreference"),
                  let preference = RecordingSavePreference(rawValue: raw)
            else {
                return .manual
            }
            return preference
        }
        set {
            defaults.set(newValue.rawValue, forKey: "recordingSavePreference")
        }
    }

    static var autoRevealSavedFiles: Bool {
        get {
            if defaults.object(forKey: "autoRevealSavedFiles") == nil {
                return true
            }
            return defaults.bool(forKey: "autoRevealSavedFiles")
        }
        set {
            defaults.set(newValue, forKey: "autoRevealSavedFiles")
        }
    }

    static var defaultRecordingSaveDirectory: URL {
        defaultDocumentsDirectory.appendingPathComponent("record", isDirectory: true)
    }

    static var defaultScreenshotSaveDirectory: URL {
        defaultDocumentsDirectory.appendingPathComponent("screenshots", isDirectory: true)
    }

    static var recordingSaveDirectory: URL {
        get {
            normalizedDirectoryURL(
                defaults.string(forKey: "recordingSaveDirectory"),
                fallback: defaultRecordingSaveDirectory
            )
        }
        set {
            defaults.set(newValue.standardizedFileURL.path, forKey: "recordingSaveDirectory")
        }
    }

    static var screenshotSaveDirectory: URL {
        get {
            normalizedDirectoryURL(
                defaults.string(forKey: "screenshotSaveDirectory"),
                fallback: defaultScreenshotSaveDirectory
            )
        }
        set {
            defaults.set(newValue.standardizedFileURL.path, forKey: "screenshotSaveDirectory")
        }
    }

    static let defaultImageFilenameTemplate = "capcap-{date}-{time}"
    static let defaultRecordingFilenameTemplate = "capcap-rec-{date}-{time}"

    static var imageFilenameTemplate: String {
        get {
            normalizedFilenameTemplate(
                defaults.string(forKey: "imageFilenameTemplate"),
                fallback: defaultImageFilenameTemplate
            )
        }
        set {
            defaults.set(
                normalizedFilenameTemplate(newValue, fallback: defaultImageFilenameTemplate),
                forKey: "imageFilenameTemplate"
            )
        }
    }

    static var recordingFilenameTemplate: String {
        get {
            normalizedFilenameTemplate(
                defaults.string(forKey: "recordingFilenameTemplate"),
                fallback: defaultRecordingFilenameTemplate
            )
        }
        set {
            defaults.set(
                normalizedFilenameTemplate(newValue, fallback: defaultRecordingFilenameTemplate),
                forKey: "recordingFilenameTemplate"
            )
        }
    }

    private static func normalizedFilenameTemplate(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static var defaultDocumentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    private static func normalizedDirectoryURL(_ value: String?, fallback: URL) -> URL {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback.standardizedFileURL }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    static func filenameSequenceValue(scope: String, dayStamp: String?, consume: Bool) -> Int {
        if let dayStamp {
            let counterKey = "filenameDailyCounter.\(scope)"
            let dayKey = "filenameDailyCounterDay.\(scope)"
            let currentDay = defaults.string(forKey: dayKey)
            let currentValue = currentDay == dayStamp ? defaults.integer(forKey: counterKey) : 0
            let nextValue = currentValue + 1
            if consume {
                defaults.set(dayStamp, forKey: dayKey)
                defaults.set(nextValue, forKey: counterKey)
            }
            return nextValue
        }

        let key = "filenameCounter.\(scope)"
        let nextValue = defaults.integer(forKey: key) + 1
        if consume {
            defaults.set(nextValue, forKey: key)
        }
        return nextValue
    }

    // Custom copy-to-clipboard hotkey used inside the editor overlay to
    // confirm the screenshot. When absent, the default is "double-tap ⌘",
    // detected via the global flag monitor (KeyMonitor) — see AppDelegate.
    // Unlike the screenshot and pin hotkeys this is matched locally against
    // keyDown events instead of registered as a Carbon global hotkey, so it
    // may be bare (no modifiers). Presence must be checked via
    // `hasCustomClipboardHotkey` since key code 0 (`A`) is a valid value.

    private static func migrateLegacySaveHotkeyIfNeeded() {
        // capcap ≤ 1.x stored this same hotkey under "saveHotkey*". Migrate
        // once on first read so existing users don't lose their binding.
        let migratedKey = "clipboardHotkeyMigrated"
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard defaults.object(forKey: "saveHotkeyKeyCode") != nil,
              defaults.object(forKey: "clipboardHotkeyKeyCode") == nil
        else { return }
        defaults.set(defaults.integer(forKey: "saveHotkeyKeyCode"), forKey: "clipboardHotkeyKeyCode")
        defaults.set(defaults.integer(forKey: "saveHotkeyModifiers"), forKey: "clipboardHotkeyModifiers")
        defaults.removeObject(forKey: "saveHotkeyKeyCode")
        defaults.removeObject(forKey: "saveHotkeyModifiers")
    }

    static var clipboardHotkeyKeyCode: Int {
        get {
            migrateLegacySaveHotkeyIfNeeded()
            return defaults.integer(forKey: "clipboardHotkeyKeyCode")
        }
        set { defaults.set(newValue, forKey: "clipboardHotkeyKeyCode") }
    }

    static var clipboardHotkeyModifiers: Int {
        get {
            migrateLegacySaveHotkeyIfNeeded()
            return defaults.integer(forKey: "clipboardHotkeyModifiers")
        }
        set { defaults.set(newValue, forKey: "clipboardHotkeyModifiers") }
    }

    static var hasCustomClipboardHotkey: Bool {
        migrateLegacySaveHotkeyIfNeeded()
        return defaults.object(forKey: "clipboardHotkeyKeyCode") != nil
    }

    static func clearClipboardHotkey() {
        defaults.removeObject(forKey: "clipboardHotkeyKeyCode")
        defaults.removeObject(forKey: "clipboardHotkeyModifiers")
    }

    // Custom save-to-file hotkey used inside the editor overlay to invoke
    // the configured-directory file save. When absent, defaults to ⌘S.
    // Matched locally against keyDown events, same as the clipboard hotkey.

    static var fileSaveHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "fileSaveHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "fileSaveHotkeyKeyCode") }
    }

    static var fileSaveHotkeyModifiers: Int {
        get { defaults.integer(forKey: "fileSaveHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "fileSaveHotkeyModifiers") }
    }

    static var hasCustomFileSaveHotkey: Bool {
        defaults.object(forKey: "fileSaveHotkeyKeyCode") != nil
    }

    static func clearFileSaveHotkey() {
        defaults.removeObject(forKey: "fileSaveHotkeyKeyCode")
        defaults.removeObject(forKey: "fileSaveHotkeyModifiers")
    }

    // History navigation hotkeys used inside the editor overlay. Defaults are
    // comma for previous and period for next. Like clipboard/save editor
    // hotkeys, bare keys are allowed because matching is local to the editor.

    static var previousHistoryImageHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "previousHistoryImageHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "previousHistoryImageHotkeyKeyCode") }
    }

    static var previousHistoryImageHotkeyModifiers: Int {
        get { defaults.integer(forKey: "previousHistoryImageHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "previousHistoryImageHotkeyModifiers") }
    }

    static var hasCustomPreviousHistoryImageHotkey: Bool {
        defaults.object(forKey: "previousHistoryImageHotkeyKeyCode") != nil
    }

    static func clearPreviousHistoryImageHotkey() {
        defaults.removeObject(forKey: "previousHistoryImageHotkeyKeyCode")
        defaults.removeObject(forKey: "previousHistoryImageHotkeyModifiers")
    }

    static var nextHistoryImageHotkeyKeyCode: Int {
        get { defaults.integer(forKey: "nextHistoryImageHotkeyKeyCode") }
        set { defaults.set(newValue, forKey: "nextHistoryImageHotkeyKeyCode") }
    }

    static var nextHistoryImageHotkeyModifiers: Int {
        get { defaults.integer(forKey: "nextHistoryImageHotkeyModifiers") }
        set { defaults.set(newValue, forKey: "nextHistoryImageHotkeyModifiers") }
    }

    static var hasCustomNextHistoryImageHotkey: Bool {
        defaults.object(forKey: "nextHistoryImageHotkeyKeyCode") != nil
    }

    static func clearNextHistoryImageHotkey() {
        defaults.removeObject(forKey: "nextHistoryImageHotkeyKeyCode")
        defaults.removeObject(forKey: "nextHistoryImageHotkeyModifiers")
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

    static let editorLineWidthMin: Double = 1
    static let editorLineWidthMax: Double = 16
    static let markerLineWidthMax: Double = 10

    static var lastEditorColorHex: String? {
        get {
            normalizedHexColor(defaults.string(forKey: "lastEditorColorHex"))
        }
        set {
            if let normalized = normalizedHexColor(newValue) {
                defaults.set(normalized, forKey: "lastEditorColorHex")
            } else {
                defaults.removeObject(forKey: "lastEditorColorHex")
            }
        }
    }

    static var lastEditorLineWidth: Double {
        get {
            if defaults.object(forKey: "lastEditorLineWidth") == nil {
                return 4.0
            }
            return clampedEditorLineWidth(defaults.double(forKey: "lastEditorLineWidth"))
        }
        set {
            defaults.set(clampedEditorLineWidth(newValue), forKey: "lastEditorLineWidth")
        }
    }

    static var lastMarkerColorHex: String? {
        get {
            normalizedHexColor(defaults.string(forKey: "lastMarkerColorHex"))
        }
        set {
            if let normalized = normalizedHexColor(newValue) {
                defaults.set(normalized, forKey: "lastMarkerColorHex")
            } else {
                defaults.removeObject(forKey: "lastMarkerColorHex")
            }
        }
    }

    static var lastMarkerLineWidth: Double {
        get {
            if defaults.object(forKey: "lastMarkerLineWidth") == nil {
                return 5.0
            }
            return clampedMarkerLineWidth(defaults.double(forKey: "lastMarkerLineWidth"))
        }
        set {
            defaults.set(clampedMarkerLineWidth(newValue), forKey: "lastMarkerLineWidth")
        }
    }

    static var mosaicBlockSize: Double {
        get {
            let val = defaults.double(forKey: "mosaicBlockSize")
            guard val > 0 else { return 12.0 }
            return min(max(val, mosaicBlockSizeMin), mosaicBlockSizeMax)
        }
        set {
            defaults.set(min(max(newValue, mosaicBlockSizeMin), mosaicBlockSizeMax), forKey: "mosaicBlockSize")
        }
    }

    static let mosaicBlockSizeMin: Double = 4
    static let mosaicBlockSizeMax: Double = 48

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

    /// Whether the text tool's outline checkbox was last left on.
    static var lastTextStroke: Bool {
        get { defaults.bool(forKey: "lastTextStroke") }
        set { defaults.set(newValue, forKey: "lastTextStroke") }
    }

    /// Whether the text tool's callout checkbox was last left on.
    static var lastTextCallout: Bool {
        get { defaults.bool(forKey: "lastTextCallout") }
        set { defaults.set(newValue, forKey: "lastTextCallout") }
    }

    /// Last rectangle/ellipse fill mode. Migrates the previous checkbox
    /// preference by treating its "on" state as the old opaque fill.
    static var lastShapeFillMode: ShapeFillMode {
        get {
            guard let raw = defaults.string(forKey: "lastShapeFillMode"),
                  let mode = ShapeFillMode(rawValue: raw) else {
                return defaults.bool(forKey: "lastShapeFill") ? .opaque : .none
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: "lastShapeFillMode")
            defaults.set(newValue.isFilled, forKey: "lastShapeFill")
        }
    }

    static var lastShapeStrokeStyle: ShapeStrokeStyle {
        get {
            guard let raw = defaults.string(forKey: "lastShapeStrokeStyle"),
                  let style = ShapeStrokeStyle(rawValue: raw) else {
                return .standard
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: "lastShapeStrokeStyle")
        }
    }

    /// Whether the rectangle/ellipse tool's legacy fill checkbox was last left on.
    static var lastShapeFill: Bool {
        get { lastShapeFillMode.isFilled }
        set { lastShapeFillMode = newValue ? .opaque : .none }
    }

    static var lastArrowStyle: ArrowStyle {
        get {
            guard let raw = defaults.string(forKey: "lastArrowStyle"),
                  let style = ArrowStyle(rawValue: raw) else {
                return .tapered
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: "lastArrowStyle")
        }
    }

    static var lastPickedColorHex: String? {
        get {
            guard historyCacheEnabled else { return nil }
            return normalizedHexColor(defaults.string(forKey: "lastPickedColorHex"))
        }
        set {
            if let normalized = normalizedHexColor(newValue) {
                defaults.set(normalized, forKey: "lastPickedColorHex")
            } else {
                defaults.removeObject(forKey: "lastPickedColorHex")
            }
        }
    }

    static var recentEmojis: [String] {
        get {
            normalizedEmojiList(defaults.stringArray(forKey: "recentEmojis") ?? [])
        }
        set {
            let normalized = normalizedEmojiList(newValue)
            if normalized.isEmpty {
                defaults.removeObject(forKey: "recentEmojis")
            } else {
                defaults.set(normalized, forKey: "recentEmojis")
            }
        }
    }

    private static func normalizedEmojiList(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            result.append(trimmed)
            if result.count == 10 { break }
        }
        return result
    }

    private static func normalizedHexColor(_ hex: String?) -> String? {
        guard var trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, UInt32(trimmed, radix: 16) != nil else { return nil }
        return "#\(trimmed)"
    }

    private static func clampedEditorLineWidth(_ width: Double) -> Double {
        min(max(width, editorLineWidthMin), editorLineWidthMax)
    }

    private static func clampedMarkerLineWidth(_ width: Double) -> Double {
        min(max(width, editorLineWidthMin), markerLineWidthMax)
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
            return min(max(val, 0), 56)
        }
        set {
            defaults.set(min(max(newValue, 0), 56), forKey: "lastBeautifyPadding")
        }
    }

    static var lastBeautifyShadowEnabled: Bool {
        get {
            if defaults.object(forKey: "lastBeautifyShadowEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "lastBeautifyShadowEnabled")
        }
        set {
            defaults.set(newValue, forKey: "lastBeautifyShadowEnabled")
        }
    }

    static let historyCacheMin: Int = 10
    static let historyCacheMax: Int = 100
    static let historyCacheStep: Int = 10

    static var historyCacheEnabled: Bool {
        get {
            if defaults.object(forKey: "historyCacheEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "historyCacheEnabled")
        }
        set {
            let oldValue = historyCacheEnabled
            defaults.set(newValue, forKey: "historyCacheEnabled")
            if !newValue {
                lastPickedColorHex = nil
            }
            if oldValue != newValue {
                NotificationCenter.default.post(name: .historyCacheEnabledDidChange, object: nil)
            }
        }
    }

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
            return normalizedHistoryCacheLimit(val)
        }
        set {
            defaults.set(normalizedHistoryCacheLimit(newValue), forKey: "historyCacheLimit")
            NotificationCenter.default.post(name: .historyCacheLimitDidChange, object: nil)
        }
    }

    private static func normalizedHistoryCacheLimit(_ value: Int) -> Int {
        let clamped = min(max(value, historyCacheMin), historyCacheMax)
        let offset = clamped - historyCacheMin
        let snapped = historyCacheMin + ((offset + historyCacheStep / 2) / historyCacheStep) * historyCacheStep
        return min(max(snapped, historyCacheMin), historyCacheMax)
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

    static var pinAcrossSpaces: Bool {
        get { defaults.bool(forKey: "pinAcrossSpaces") }
        set { defaults.set(newValue, forKey: "pinAcrossSpaces") }
    }

    // Window-capture drop shadow. When enabled, single-window screenshots get
    // rounded corners and a macOS-style drop shadow in the final output.
    // Rounded corners are always applied to window captures; this toggle only
    // governs the shadow.

    static let windowShadowSizeMin: Double = 6
    static let windowShadowSizeMax: Double = 60

    static var windowShadowEnabled: Bool {
        get {
            if defaults.object(forKey: "windowShadowEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "windowShadowEnabled")
        }
        set {
            defaults.set(newValue, forKey: "windowShadowEnabled")
        }
    }

    static var windowShadowSize: Double {
        get {
            if defaults.object(forKey: "windowShadowSize") == nil {
                return 22
            }
            let val = defaults.double(forKey: "windowShadowSize")
            return min(max(val, windowShadowSizeMin), windowShadowSizeMax)
        }
        set {
            defaults.set(min(max(newValue, windowShadowSizeMin), windowShadowSizeMax), forKey: "windowShadowSize")
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
