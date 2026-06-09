import Cocoa
import Carbon

final class HotkeyManager {

    static let shared = HotkeyManager()

    private(set) var isRecording: Bool = false

    private var hotKeyRef: EventHotKeyRef?
    private var countdownHotKeyRef: EventHotKeyRef?
    private var selectedImagePinHotKeyRef: EventHotKeyRef?
    private var clipboardImagePinHotKeyRef: EventHotKeyRef?
    private var selectedImageEditHotKeyRef: EventHotKeyRef?
    private var clipboardImageEditHotKeyRef: EventHotKeyRef?
    private var textRecognitionHotKeyRef: EventHotKeyRef?
    private var copyImageTextHotKeyRef: EventHotKeyRef?
    private var screenshotTranslationHotKeyRef: EventHotKeyRef?
    private var recordHotKeyRef: EventHotKeyRef?
    private var imageMergeHotKeyRef: EventHotKeyRef?
    private var fullScreenScreenshotHotKeyRef: EventHotKeyRef?
    private var colorPickerHotKeyRef: EventHotKeyRef?
    private var callback: (() -> Void)?
    private var countdownCallback: (() -> Void)?
    private var selectedImagePinCallback: (() -> Void)?
    private var clipboardImagePinCallback: (() -> Void)?
    private var selectedImageEditCallback: (() -> Void)?
    private var clipboardImageEditCallback: (() -> Void)?
    private var textRecognitionCallback: (() -> Void)?
    private var copyImageTextCallback: (() -> Void)?
    private var screenshotTranslationCallback: (() -> Void)?
    private var recordCallback: (() -> Void)?
    private var imageMergeCallback: (() -> Void)?
    private var fullScreenScreenshotCallback: (() -> Void)?
    private var colorPickerCallback: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    private static let regularHotKeySignature: OSType = OSType(0x4341_5043) // 'CAPC'
    private static let regularHotKeyID: UInt32 = 1
    private static let countdownHotKeyID: UInt32 = 2
    private static let selectedImagePinHotKeyID: UInt32 = 3
    private static let selectedImageEditHotKeyID: UInt32 = 4
    private static let clipboardImageEditHotKeyID: UInt32 = 5
    private static let clipboardImagePinHotKeyID: UInt32 = 6
    private static let textRecognitionHotKeyID: UInt32 = 7
    private static let screenshotTranslationHotKeyID: UInt32 = 8
    private static let recordHotKeyID: UInt32 = 9
    private static let imageMergeHotKeyID: UInt32 = 10
    private static let fullScreenScreenshotHotKeyID: UInt32 = 11
    private static let colorPickerHotKeyID: UInt32 = 12
    private static let copyImageTextHotKeyID: UInt32 = 13

    private init() {}

    deinit {
        unregister()
        unregisterCountdown()
        unregisterSelectedImagePin()
        unregisterClipboardImagePin()
        unregisterSelectedImageEdit()
        unregisterClipboardImageEdit()
        unregisterTextRecognition()
        unregisterCopyImageText()
        unregisterScreenshotTranslation()
        unregisterRecord()
        unregisterImageMerge()
        unregisterFullScreenScreenshot()
        unregisterColorPicker()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    // MARK: - Registration

    /// Register the saved screenshot hotkey, if any. Caller's `callback` is invoked when fired.
    /// If no hotkey is saved (key code == 0 with no function-key fallback), this no-ops.
    func register(callback: @escaping () -> Void) {
        self.callback = callback
        unregister()

        guard let (keyCode, modifiers) = currentHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.regularHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Register the ⌥-augmented variant of the saved hotkey for countdown capture.
    /// Skips when no custom hotkey is set or when the saved hotkey already
    /// contains ⌥ (the +⌥ variant would collide with the regular hotkey).
    func registerCountdown(callback: @escaping () -> Void) {
        self.countdownCallback = callback
        unregisterCountdown()

        guard let (keyCode, modifiers) = currentCountdownHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.countdownHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            countdownHotKeyRef = ref
        }
    }

    func unregisterCountdown() {
        if let ref = countdownHotKeyRef {
            UnregisterEventHotKey(ref)
            countdownHotKeyRef = nil
        }
    }

    /// Register the saved selected-image pin hotkey, if any. Caller's
    /// `callback` fires when it is pressed. No-ops when unset.
    func registerSelectedImagePin(callback: @escaping () -> Void) {
        self.selectedImagePinCallback = callback
        unregisterSelectedImagePin()

        guard let (keyCode, modifiers) = currentSelectedImagePinHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.selectedImagePinHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            selectedImagePinHotKeyRef = ref
        }
    }

    func unregisterSelectedImagePin() {
        if let ref = selectedImagePinHotKeyRef {
            UnregisterEventHotKey(ref)
            selectedImagePinHotKeyRef = nil
        }
    }

    /// Register the saved clipboard-image pin hotkey, if any. Caller's
    /// `callback` fires when it is pressed. No-ops when unset.
    func registerClipboardImagePin(callback: @escaping () -> Void) {
        self.clipboardImagePinCallback = callback
        unregisterClipboardImagePin()

        guard let (keyCode, modifiers) = currentClipboardImagePinHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.clipboardImagePinHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            clipboardImagePinHotKeyRef = ref
        }
    }

    func unregisterClipboardImagePin() {
        if let ref = clipboardImagePinHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardImagePinHotKeyRef = nil
        }
    }

    /// Register the saved selected-image edit hotkey, if any. No-ops when no
    /// selected-image edit hotkey is saved.
    func registerSelectedImageEdit(callback: @escaping () -> Void) {
        self.selectedImageEditCallback = callback
        unregisterSelectedImageEdit()

        guard let (keyCode, modifiers) = currentSelectedImageEditHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.selectedImageEditHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            selectedImageEditHotKeyRef = ref
        }
    }

    func unregisterSelectedImageEdit() {
        if let ref = selectedImageEditHotKeyRef {
            UnregisterEventHotKey(ref)
            selectedImageEditHotKeyRef = nil
        }
    }

    /// Register the saved clipboard-image edit hotkey, if any. No-ops when no
    /// clipboard-image edit hotkey is saved.
    func registerClipboardImageEdit(callback: @escaping () -> Void) {
        self.clipboardImageEditCallback = callback
        unregisterClipboardImageEdit()

        guard let (keyCode, modifiers) = currentClipboardImageEditHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.clipboardImageEditHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            clipboardImageEditHotKeyRef = ref
        }
    }

    func unregisterClipboardImageEdit() {
        if let ref = clipboardImageEditHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardImageEditHotKeyRef = nil
        }
    }

    /// Register the saved text-recognition hotkey, if any.
    func registerTextRecognition(callback: @escaping () -> Void) {
        self.textRecognitionCallback = callback
        unregisterTextRecognition()

        guard let (keyCode, modifiers) = currentTextRecognitionHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.textRecognitionHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            textRecognitionHotKeyRef = ref
        }
    }

    func unregisterTextRecognition() {
        if let ref = textRecognitionHotKeyRef {
            UnregisterEventHotKey(ref)
            textRecognitionHotKeyRef = nil
        }
    }

    /// Register the saved copy-image-text hotkey, if any.
    func registerCopyImageText(callback: @escaping () -> Void) {
        self.copyImageTextCallback = callback
        unregisterCopyImageText()

        guard let (keyCode, modifiers) = currentCopyImageTextHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.copyImageTextHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            copyImageTextHotKeyRef = ref
        }
    }

    func unregisterCopyImageText() {
        if let ref = copyImageTextHotKeyRef {
            UnregisterEventHotKey(ref)
            copyImageTextHotKeyRef = nil
        }
    }

    /// Register the saved screenshot-translation hotkey, if any.
    func registerScreenshotTranslation(callback: @escaping () -> Void) {
        self.screenshotTranslationCallback = callback
        unregisterScreenshotTranslation()

        guard let (keyCode, modifiers) = currentScreenshotTranslationHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.screenshotTranslationHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            screenshotTranslationHotKeyRef = ref
        }
    }

    func unregisterScreenshotTranslation() {
        if let ref = screenshotTranslationHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotTranslationHotKeyRef = nil
        }
    }

    /// Register the saved recording hotkey, if any.
    func registerRecord(callback: @escaping () -> Void) {
        self.recordCallback = callback
        unregisterRecord()

        guard let (keyCode, modifiers) = currentRecordHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.recordHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            recordHotKeyRef = ref
        }
    }

    func unregisterRecord() {
        if let ref = recordHotKeyRef {
            UnregisterEventHotKey(ref)
            recordHotKeyRef = nil
        }
    }

    /// Register the saved image-merge hotkey, if any.
    func registerImageMerge(callback: @escaping () -> Void) {
        self.imageMergeCallback = callback
        unregisterImageMerge()

        guard let (keyCode, modifiers) = currentImageMergeHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.imageMergeHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            imageMergeHotKeyRef = ref
        }
    }

    func unregisterImageMerge() {
        if let ref = imageMergeHotKeyRef {
            UnregisterEventHotKey(ref)
            imageMergeHotKeyRef = nil
        }
    }

    /// Register the saved full-screen screenshot hotkey, if any.
    func registerFullScreenScreenshot(callback: @escaping () -> Void) {
        self.fullScreenScreenshotCallback = callback
        unregisterFullScreenScreenshot()

        guard let (keyCode, modifiers) = currentFullScreenScreenshotHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.fullScreenScreenshotHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            fullScreenScreenshotHotKeyRef = ref
        }
    }

    func unregisterFullScreenScreenshot() {
        if let ref = fullScreenScreenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            fullScreenScreenshotHotKeyRef = nil
        }
    }

    /// Register the saved color-picker hotkey, if any.
    func registerColorPicker(callback: @escaping () -> Void) {
        self.colorPickerCallback = callback
        unregisterColorPicker()

        guard let (keyCode, modifiers) = currentColorPickerHotkey() else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.regularHotKeySignature, id: Self.colorPickerHotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            colorPickerHotKeyRef = ref
        }
    }

    func unregisterColorPicker() {
        if let ref = colorPickerHotKeyRef {
            UnregisterEventHotKey(ref)
            colorPickerHotKeyRef = nil
        }
    }

    /// Returns the (keyCode, modifiers) for the countdown variant — user hotkey + ⌥.
    /// Returns nil if no custom hotkey is set or the saved hotkey already contains ⌥.
    func currentCountdownHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let (kc, mods) = currentHotkey() else { return nil }
        if mods & UInt32(optionKey) != 0 { return nil }
        return (kc, mods | UInt32(optionKey))
    }

    // MARK: - Recording lifecycle

    /// Called by Settings UI when the user starts capturing a new key combo.
    /// Suspends the active hotkey so the user's recorded keypress is not swallowed.
    func beginRecording() {
        isRecording = true
        unregister()
        unregisterCountdown()
        unregisterSelectedImagePin()
        unregisterClipboardImagePin()
        unregisterSelectedImageEdit()
        unregisterClipboardImageEdit()
        unregisterTextRecognition()
        unregisterCopyImageText()
        unregisterScreenshotTranslation()
        unregisterRecord()
        unregisterImageMerge()
        unregisterFullScreenScreenshot()
        unregisterColorPicker()
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
    }

    /// Called when recording finishes (saved or cancelled).
    func endRecording() {
        isRecording = false
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
    }

    // MARK: - Stored hotkey accessors

    /// Returns (keyCode, carbonModifiers) for the saved hotkey, or nil if none/invalid.
    func currentHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomScreenshotHotkey else { return nil }
        let kc = UInt32(Defaults.screenshotHotkeyKeyCode)
        let mods = UInt32(Defaults.screenshotHotkeyModifiers)
        // Require at least one modifier unless it is a standalone function key.
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string like "⌘⇧X" for the saved hotkey, or nil if not set.
    static func currentDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved selected-image pin
    /// hotkey, or nil.
    func currentSelectedImagePinHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomSelectedImagePinHotkey else { return nil }
        let kc = UInt32(Defaults.selectedImagePinHotkeyKeyCode)
        let mods = UInt32(Defaults.selectedImagePinHotkeyModifiers)
        // Require at least one modifier unless it is a standalone function key.
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string like "⌘⇧P" for the saved selected-image pin hotkey, or
    /// nil if not set.
    static func currentSelectedImagePinDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentSelectedImagePinHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved clipboard-image pin
    /// hotkey, or nil.
    func currentClipboardImagePinHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomClipboardImagePinHotkey else { return nil }
        let kc = UInt32(Defaults.clipboardImagePinHotkeyKeyCode)
        let mods = UInt32(Defaults.clipboardImagePinHotkeyModifiers)
        // Require at least one modifier unless it is a standalone function key.
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string like "⌘⇧P" for the saved clipboard-image pin hotkey, or
    /// nil if not set.
    static func currentClipboardImagePinDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentClipboardImagePinHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved selected-image edit
    /// hotkey, or nil when the user hasn't bound one.
    func currentSelectedImageEditHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomSelectedImageEditHotkey else { return nil }
        let kc = UInt32(Defaults.selectedImageEditHotkeyKeyCode)
        let mods = UInt32(Defaults.selectedImageEditHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the selected-image edit hotkey, or nil if not set.
    static func currentSelectedImageEditDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentSelectedImageEditHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved clipboard-image edit
    /// hotkey, or nil when the user hasn't bound one.
    func currentClipboardImageEditHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomClipboardImageEditHotkey else { return nil }
        let kc = UInt32(Defaults.clipboardImageEditHotkeyKeyCode)
        let mods = UInt32(Defaults.clipboardImageEditHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the clipboard-image edit hotkey, or nil if not set.
    static func currentClipboardImageEditDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentClipboardImageEditHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved text-recognition
    /// hotkey, or nil when the user hasn't bound one.
    func currentTextRecognitionHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomTextRecognitionHotkey else { return nil }
        let kc = UInt32(Defaults.textRecognitionHotkeyKeyCode)
        let mods = UInt32(Defaults.textRecognitionHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the text-recognition hotkey, or nil if not set.
    static func currentTextRecognitionDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentTextRecognitionHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved copy-image-text
    /// hotkey, or nil when the user hasn't bound one.
    func currentCopyImageTextHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomCopyImageTextHotkey else { return nil }
        let kc = UInt32(Defaults.copyImageTextHotkeyKeyCode)
        let mods = UInt32(Defaults.copyImageTextHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the copy-image-text hotkey, or nil if not set.
    static func currentCopyImageTextDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentCopyImageTextHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved screenshot-translation
    /// hotkey, or nil when the user hasn't bound one.
    func currentScreenshotTranslationHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomScreenshotTranslationHotkey else { return nil }
        let kc = UInt32(Defaults.screenshotTranslationHotkeyKeyCode)
        let mods = UInt32(Defaults.screenshotTranslationHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the screenshot-translation hotkey, or nil if not set.
    static func currentScreenshotTranslationDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentScreenshotTranslationHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved recording hotkey.
    func currentRecordHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomRecordHotkey else { return nil }
        let kc = UInt32(Defaults.recordHotkeyKeyCode)
        let mods = UInt32(Defaults.recordHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the recording hotkey, or nil if not set.
    static func currentRecordDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentRecordHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved image-merge hotkey.
    func currentImageMergeHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomImageMergeHotkey else { return nil }
        let kc = UInt32(Defaults.imageMergeHotkeyKeyCode)
        let mods = UInt32(Defaults.imageMergeHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the image-merge hotkey, or nil if not set.
    static func currentImageMergeDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentImageMergeHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved full-screen screenshot
    /// hotkey.
    func currentFullScreenScreenshotHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomFullScreenScreenshotHotkey else { return nil }
        let kc = UInt32(Defaults.fullScreenScreenshotHotkeyKeyCode)
        let mods = UInt32(Defaults.fullScreenScreenshotHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the full-screen screenshot hotkey, or nil if not set.
    static func currentFullScreenScreenshotDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentFullScreenScreenshotHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved color-picker hotkey.
    func currentColorPickerHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomColorPickerHotkey else { return nil }
        let kc = UInt32(Defaults.colorPickerHotkeyKeyCode)
        let mods = UInt32(Defaults.colorPickerHotkeyModifiers)
        guard mods != 0 || Self.isFunctionKey(kc) else { return nil }
        return (kc, mods)
    }

    /// Display string for the color-picker hotkey, or nil if not set.
    static func currentColorPickerDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentColorPickerHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns (keyCode, carbonModifiers) for the saved copy-to-clipboard
    /// hotkey, or nil when the user hasn't bound one (the default is
    /// "double-tap ⌘", handled separately by `KeyMonitor`).
    /// Bare (no-modifier) values are allowed here — the clipboard hotkey is
    /// matched locally against keyDown events inside the editor, not registered
    /// as a global Carbon hotkey, so it won't intercept ordinary typing.
    func currentClipboardHotkey() -> (keyCode: UInt32, modifiers: UInt32)? {
        guard Defaults.hasCustomClipboardHotkey else { return nil }
        let kc = UInt32(Defaults.clipboardHotkeyKeyCode)
        let mods = UInt32(Defaults.clipboardHotkeyModifiers)
        return (kc, mods)
    }

    /// Display string for the saved clipboard hotkey, or nil if not set.
    static func currentClipboardDisplayString() -> String? {
        guard let (kc, mods) = HotkeyManager.shared.currentClipboardHotkey() else { return nil }
        return modifierString(mods) + keyString(kc)
    }

    /// Returns true when the given keyDown event matches the user's
    /// copy-to-clipboard hotkey. Returns false when no custom hotkey is set —
    /// the default (double-tap ⌘) is detected via `KeyMonitor`, not keyDown.
    static func eventMatchesClipboardHotkey(_ event: NSEvent) -> Bool {
        guard let (kc, m) = HotkeyManager.shared.currentClipboardHotkey() else { return false }
        return matches(event: event, keyCode: kc, modifiers: m)
    }

    /// Returns (keyCode, carbonModifiers) for the save-to-file hotkey. Falls
    /// back to ⌘S when the user hasn't bound a custom one.
    func currentFileSaveHotkey() -> (keyCode: UInt32, modifiers: UInt32) {
        if Defaults.hasCustomFileSaveHotkey {
            return (UInt32(Defaults.fileSaveHotkeyKeyCode),
                    UInt32(Defaults.fileSaveHotkeyModifiers))
        }
        return (UInt32(kVK_ANSI_S), UInt32(cmdKey))
    }

    /// Display string for the save-to-file hotkey (default or custom).
    static func currentFileSaveDisplayString() -> String {
        let (kc, mods) = HotkeyManager.shared.currentFileSaveHotkey()
        return modifierString(mods) + keyString(kc)
    }

    /// Returns true when the given keyDown event matches the save-to-file
    /// hotkey (custom or the ⌘S default).
    static func eventMatchesFileSaveHotkey(_ event: NSEvent) -> Bool {
        let (kc, m) = HotkeyManager.shared.currentFileSaveHotkey()
        return matches(event: event, keyCode: kc, modifiers: m)
    }

    func currentPreviousHistoryImageHotkey() -> (keyCode: UInt32, modifiers: UInt32) {
        if Defaults.hasCustomPreviousHistoryImageHotkey {
            return (UInt32(Defaults.previousHistoryImageHotkeyKeyCode),
                    UInt32(Defaults.previousHistoryImageHotkeyModifiers))
        }
        return (UInt32(kVK_ANSI_Comma), 0)
    }

    static func currentPreviousHistoryImageDisplayString() -> String {
        let (kc, mods) = HotkeyManager.shared.currentPreviousHistoryImageHotkey()
        return modifierString(mods) + keyString(kc)
    }

    static func eventMatchesPreviousHistoryImageHotkey(_ event: NSEvent) -> Bool {
        let (kc, m) = HotkeyManager.shared.currentPreviousHistoryImageHotkey()
        return matches(event: event, keyCode: kc, modifiers: m)
    }

    func currentNextHistoryImageHotkey() -> (keyCode: UInt32, modifiers: UInt32) {
        if Defaults.hasCustomNextHistoryImageHotkey {
            return (UInt32(Defaults.nextHistoryImageHotkeyKeyCode),
                    UInt32(Defaults.nextHistoryImageHotkeyModifiers))
        }
        return (UInt32(kVK_ANSI_Period), 0)
    }

    static func currentNextHistoryImageDisplayString() -> String {
        let (kc, mods) = HotkeyManager.shared.currentNextHistoryImageHotkey()
        return modifierString(mods) + keyString(kc)
    }

    static func eventMatchesNextHistoryImageHotkey(_ event: NSEvent) -> Bool {
        let (kc, m) = HotkeyManager.shared.currentNextHistoryImageHotkey()
        return matches(event: event, keyCode: kc, modifiers: m)
    }

    private static func matches(event: NSEvent, keyCode: UInt32, modifiers: UInt32) -> Bool {
        let activeMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(activeMask)
        var carbonMods: UInt32 = 0
        if mods.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if mods.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if mods.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if mods.contains(.control) { carbonMods |= UInt32(controlKey) }
        return UInt32(event.keyCode) == keyCode && carbonMods == modifiers
    }

    // MARK: - Conflict detection

    /// A user-configurable hotkey slot in Settings.
    enum HotkeySlot {
        case screenshot
        case selectedImagePin
        case clipboardImagePin
        case selectedImageEdit
        case clipboardImageEdit
        case textRecognition
        case copyImageText
        case screenshotTranslation
        case record
        case imageMerge
        case fullScreenScreenshot
        case colorPicker
        case clipboard
        case fileSave
        case previousHistoryImage
        case nextHistoryImage
    }

    /// Returns a localized message describing the existing binding a candidate
    /// `(keyCode, modifiers)` would collide with, or nil when it is free to
    /// assign. `slot` is the function being edited and is excluded from the
    /// check, so re-recording its own combo is not flagged as a self-conflict.
    ///
    /// Assigning the screenshot hotkey also redefines the derived countdown
    /// hotkey (screenshot + ⌥), so for that slot the ⌥ variant is checked
    /// against other global hotkeys as well.
    func hotkeyConflictMessage(forKeyCode keyCode: UInt32,
                               modifiers: UInt32,
                               assigningTo slot: HotkeySlot) -> String? {
        if slot != .screenshot {
            if let (kc, m) = currentHotkey(), kc == keyCode, m == modifiers {
                return L10n.shortcutConflictScreenshot
            }
            if let (kc, m) = currentCountdownHotkey(), kc == keyCode, m == modifiers {
                return L10n.shortcutConflictCountdown
            }
        }
        if slot != .selectedImagePin, let (kc, m) = currentSelectedImagePinHotkey() {
            if kc == keyCode, m == modifiers {
                return L10n.shortcutConflictSelectedImagePin
            }
            // The screenshot hotkey's ⌥ variant becomes the countdown hotkey;
            // it must not land on the selected-image pin hotkey either.
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               kc == keyCode, m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictSelectedImagePin
            }
        }
        if slot != .clipboardImagePin, let (kc, m) = currentClipboardImagePinHotkey() {
            if kc == keyCode, m == modifiers {
                return L10n.shortcutConflictClipboardImagePin
            }
            // The screenshot hotkey's ⌥ variant becomes the countdown hotkey;
            // it must not land on the clipboard-image pin hotkey either.
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               kc == keyCode, m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictClipboardImagePin
            }
        }
        if slot != .selectedImageEdit,
           let (kc, m) = currentSelectedImageEditHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictSelectedImageEdit
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictSelectedImageEdit
            }
        }
        if slot != .clipboardImageEdit,
           let (kc, m) = currentClipboardImageEditHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictClipboardImageEdit
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictClipboardImageEdit
            }
        }
        if slot != .textRecognition,
           let (kc, m) = currentTextRecognitionHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictTextRecognition
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictTextRecognition
            }
        }
        if slot != .copyImageText,
           let (kc, m) = currentCopyImageTextHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictCopyImageText
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictCopyImageText
            }
        }
        if slot != .screenshotTranslation,
           let (kc, m) = currentScreenshotTranslationHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictScreenshotTranslation
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictScreenshotTranslation
            }
        }
        if slot != .record,
           let (kc, m) = currentRecordHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictRecord
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictRecord
            }
        }
        if slot != .imageMerge,
           let (kc, m) = currentImageMergeHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictImageMerge
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictImageMerge
            }
        }
        if slot != .fullScreenScreenshot,
           let (kc, m) = currentFullScreenScreenshotHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictFullScreenScreenshot
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictFullScreenScreenshot
            }
        }
        if slot != .colorPicker,
           let (kc, m) = currentColorPickerHotkey(),
           kc == keyCode {
            if m == modifiers {
                return L10n.shortcutConflictColorPicker
            }
            if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
               m == modifiers | UInt32(optionKey) {
                return L10n.shortcutConflictColorPicker
            }
        }
        if slot != .clipboard, let (kc, m) = currentClipboardHotkey(), kc == keyCode, m == modifiers {
            return L10n.shortcutConflictClipboard
        }
        if slot != .fileSave {
            let (kc, m) = currentFileSaveHotkey()
            if kc == keyCode, m == modifiers {
                return L10n.shortcutConflictFileSave
            }
        }
        if slot != .previousHistoryImage {
            let (kc, m) = currentPreviousHistoryImageHotkey()
            if kc == keyCode {
                if m == modifiers {
                    return L10n.shortcutConflictPreviousHistoryImage
                }
                if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
                   m == modifiers | UInt32(optionKey) {
                    return L10n.shortcutConflictPreviousHistoryImage
                }
            }
        }
        if slot != .nextHistoryImage {
            let (kc, m) = currentNextHistoryImageHotkey()
            if kc == keyCode {
                if m == modifiers {
                    return L10n.shortcutConflictNextHistoryImage
                }
                if slot == .screenshot, modifiers & UInt32(optionKey) == 0,
                   m == modifiers | UInt32(optionKey) {
                    return L10n.shortcutConflictNextHistoryImage
                }
            }
        }
        return nil
    }

    // MARK: - Event handler

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }

                let callback: (() -> Void)?
                switch hkID.id {
                case HotkeyManager.countdownHotKeyID:
                    callback = mgr.countdownCallback
                case HotkeyManager.selectedImagePinHotKeyID:
                    callback = mgr.selectedImagePinCallback
                case HotkeyManager.clipboardImagePinHotKeyID:
                    callback = mgr.clipboardImagePinCallback
                case HotkeyManager.selectedImageEditHotKeyID:
                    callback = mgr.selectedImageEditCallback
                case HotkeyManager.clipboardImageEditHotKeyID:
                    callback = mgr.clipboardImageEditCallback
                case HotkeyManager.textRecognitionHotKeyID:
                    callback = mgr.textRecognitionCallback
                case HotkeyManager.copyImageTextHotKeyID:
                    callback = mgr.copyImageTextCallback
                case HotkeyManager.screenshotTranslationHotKeyID:
                    callback = mgr.screenshotTranslationCallback
                case HotkeyManager.recordHotKeyID:
                    callback = mgr.recordCallback
                case HotkeyManager.imageMergeHotKeyID:
                    callback = mgr.imageMergeCallback
                case HotkeyManager.fullScreenScreenshotHotKeyID:
                    callback = mgr.fullScreenScreenshotCallback
                case HotkeyManager.colorPickerHotKeyID:
                    callback = mgr.colorPickerCallback
                case HotkeyManager.regularHotKeyID:
                    callback = mgr.callback
                default:
                    callback = nil
                }
                if let callback {
                    MainRunLoopScheduler.perform(callback)
                }
                return noErr
            },
            1, &spec, selfPtr, &eventHandlerRef
        )
    }

    // MARK: - Keycode helpers

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        let codes: Set<UInt32> = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
            UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
            UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
        ]
        return codes.contains(keyCode)
    }

    static func modifierString(_ m: UInt32) -> String {
        var s = ""
        if m & UInt32(controlKey) != 0 { s += "\u{2303}" }
        if m & UInt32(optionKey) != 0  { s += "\u{2325}" }
        if m & UInt32(shiftKey) != 0   { s += "\u{21E7}" }
        if m & UInt32(cmdKey) != 0     { s += "\u{2318}" }
        return s
    }

    static func keyString(_ keyCode: UInt32) -> String {
        if let mapped = keyMap[keyCode] { return mapped }
        return "Key \(keyCode)"
    }

    // MARK: - NSMenuItem integration

    /// Apply the saved hotkey to a menu item via the native keyEquivalent system.
    /// When no custom hotkey is set, renders "⌘⌘" (double-tap ⌘) by using ⌘
    /// as both the modifier mask and the key character — AppKit displays them
    /// as two glyphs side-by-side in the shortcut column. The binding can't
    /// fire from a real keystroke since ⌘ can't be pressed as a key while held
    /// as a modifier, so it functions purely as a visual hint.
    static func applyToMenuItem(_ item: NSMenuItem) {
        item.attributedTitle = nil

        guard let (kc, mods) = HotkeyManager.shared.currentHotkey() else {
            item.keyEquivalent = "\u{2318}"
            item.keyEquivalentModifierMask = .command
            return
        }

        apply(keyCode: kc, modifiers: mods, to: item)
    }

    static func applyImageMergeToMenuItem(_ item: NSMenuItem) {
        item.attributedTitle = nil
        guard let (kc, mods) = HotkeyManager.shared.currentImageMergeHotkey() else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        apply(keyCode: kc, modifiers: mods, to: item)
    }

    static func applyFullScreenScreenshotToMenuItem(_ item: NSMenuItem) {
        item.attributedTitle = nil
        guard let (kc, mods) = HotkeyManager.shared.currentFullScreenScreenshotHotkey() else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        apply(keyCode: kc, modifiers: mods, to: item)
    }

    static func applyRecordToMenuItem(_ item: NSMenuItem) {
        item.attributedTitle = nil
        guard let (kc, mods) = HotkeyManager.shared.currentRecordHotkey() else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        apply(keyCode: kc, modifiers: mods, to: item)
    }

    static func applyColorPickerToMenuItem(_ item: NSMenuItem) {
        item.attributedTitle = nil
        guard let (kc, mods) = HotkeyManager.shared.currentColorPickerHotkey() else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        apply(keyCode: kc, modifiers: mods, to: item)
    }

    private static func apply(keyCode kc: UInt32, modifiers mods: UInt32, to item: NSMenuItem) {
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(cmdKey) != 0     { flags.insert(.command) }
        if mods & UInt32(shiftKey) != 0   { flags.insert(.shift) }
        if mods & UInt32(optionKey) != 0  { flags.insert(.option) }
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }

        let key: String
        if let special = menuKeyCharMap[kc] {
            key = special
        } else {
            let display = keyString(kc)
            guard !display.hasPrefix("Key ") else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                return
            }
            key = display.lowercased()
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = flags
    }

    private static let menuKeyCharMap: [UInt32: String] = [
        UInt32(kVK_F1): "\u{F704}", UInt32(kVK_F2): "\u{F705}", UInt32(kVK_F3): "\u{F706}",
        UInt32(kVK_F4): "\u{F707}", UInt32(kVK_F5): "\u{F708}", UInt32(kVK_F6): "\u{F709}",
        UInt32(kVK_F7): "\u{F70A}", UInt32(kVK_F8): "\u{F70B}", UInt32(kVK_F9): "\u{F70C}",
        UInt32(kVK_F10): "\u{F70D}", UInt32(kVK_F11): "\u{F70E}", UInt32(kVK_F12): "\u{F70F}",
        UInt32(kVK_F13): "\u{F710}", UInt32(kVK_F14): "\u{F711}", UInt32(kVK_F15): "\u{F712}",
        UInt32(kVK_F16): "\u{F713}", UInt32(kVK_F17): "\u{F714}", UInt32(kVK_F18): "\u{F715}",
        UInt32(kVK_F19): "\u{F716}", UInt32(kVK_F20): "\u{F717}",
        UInt32(kVK_Space): " ", UInt32(kVK_Return): "\r", UInt32(kVK_Tab): "\t",
        UInt32(kVK_Delete): "\u{7F}", UInt32(kVK_ForwardDelete): "\u{F728}",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_LeftArrow): "\u{F702}", UInt32(kVK_RightArrow): "\u{F703}",
        UInt32(kVK_UpArrow): "\u{F700}", UInt32(kVK_DownArrow): "\u{F701}",
        UInt32(kVK_Home): "\u{F729}", UInt32(kVK_End): "\u{F72B}",
        UInt32(kVK_PageUp): "\u{F72C}", UInt32(kVK_PageDown): "\u{F72D}",
    ]

    private static let keyMap: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete", UInt32(kVK_ForwardDelete): "Fwd Del",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_LeftArrow): "\u{2190}", UInt32(kVK_RightArrow): "\u{2192}",
        UInt32(kVK_UpArrow): "\u{2191}", UInt32(kVK_DownArrow): "\u{2193}",
        UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "PgUp", UInt32(kVK_PageDown): "PgDn",
    ]
}
