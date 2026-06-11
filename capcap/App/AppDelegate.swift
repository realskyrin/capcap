import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var keyMonitor: KeyMonitor!
    private var overlayController: OverlayWindowController?
    private var recordingEngine: RecordingEngine?
    private var recordingHUDPanel: RecordingHUDPanel?
    private var recordingBorderPanel: RecordingBorderPanel?
    private var recordingScreenRect: NSRect = .zero
    private var recordingScreen: NSScreen?
    private var recordingCancelLocalMonitor: Any?
    private var recordingCancelGlobalMonitor: Any?
    private var recordingCancelRequested = false
    private var countdownActive = false
    private var appInitialized = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchAtLogin.isEnabled && AppPermissions.allRequiredGranted {
            initializeApp()
        } else {
            showStartupDialog()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if appInitialized {
            openSettings()
        } else {
            showStartupDialog()
        }
        return false
    }

    private func showStartupDialog() {
        let settingsController = configuredSettingsController()
        settingsController.showAsStartupDialog()
    }

    private func configuredSettingsController() -> SettingsWindowController {
        let settingsController = SettingsWindowController.shared
        settingsController.onMenuBarToggle = { [weak self] visible in
            self?.statusBarController?.setMenuBarVisible(visible)
        }
        settingsController.onLaunch = { [weak self] in
            self?.initializeApp()
        }
        return settingsController
    }

    private func initializeApp() {
        guard !appInitialized else { return }
        appInitialized = true

        ImageEditLauncher.clearTempDir()
        ImageMergeLauncher.shared.onContinueEditing = { [weak self] image in
            self?.continueEditingMergedImage(image)
        }

        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in self?.handleTrigger() },
            onTakeFullScreenScreenshot: { [weak self] in self?.handleFullScreenScreenshotTrigger() },
            onRecord: { [weak self] in self?.handleRecordingTrigger() },
            onMergeImages: { [weak self] in self?.handleImageMergeMenuTrigger() },
            onColorPicker: { [weak self] in self?.handleColorPickerTrigger() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        statusBarController.setMenuBarVisible(Defaults.showMenuBar)

        keyMonitor = KeyMonitor(
            onTrigger: { [weak self] in self?.handleDoubleTapCommand() },
            onCountdownTrigger: { [weak self] in self?.handleCountdownTrigger() }
        )

        NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHotkeyState()
        }
        applyHotkeyState()
    }

    private func applyHotkeyState() {
        if HotkeyManager.shared.isRecording {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterCountdown()
            unregisterNonScreenshotHotkeys()
            keyMonitor?.isEnabled = false
            return
        }

        if recordingEngine != nil {
            unregisterNonScreenshotHotkeys()
            keyMonitor?.isEnabled = true
            keyMonitor?.isRegularDoubleTapEnabled = !Defaults.hasCustomScreenshotHotkey
            if Defaults.hasCustomScreenshotHotkey {
                HotkeyManager.shared.register { [weak self] in
                    self?.stopRecordingAndSave()
                }
            } else {
                HotkeyManager.shared.unregister()
            }
            HotkeyManager.shared.unregisterCountdown()
            return
        }

        keyMonitor?.isEnabled = true
        if Defaults.hasCustomScreenshotHotkey {
            HotkeyManager.shared.register { [weak self] in
                self?.handleTrigger(fromShortcut: true)
            }
            HotkeyManager.shared.registerCountdown { [weak self] in
                self?.handleCountdownTrigger()
            }
        } else {
            HotkeyManager.shared.unregister()
            HotkeyManager.shared.unregisterCountdown()
        }

        // Double-tap ⌘ does two jobs: it's the default screenshot trigger
        // when no custom screenshot hotkey is set, and the default
        // copy-to-clipboard trigger while an overlay is up (when no custom
        // clipboard hotkey is set). Keep it live whenever either path needs it.
        let needsDoubleTap = !Defaults.hasCustomScreenshotHotkey
            || (overlayController != nil && !Defaults.hasCustomClipboardHotkey)
        keyMonitor?.isRegularDoubleTapEnabled = needsDoubleTap

        // The pin hotkeys are independent of the screenshot hotkey.
        if Defaults.hasCustomSelectedImagePinHotkey {
            HotkeyManager.shared.registerSelectedImagePin { [weak self] in
                self?.handleSelectedImagePinTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterSelectedImagePin()
        }

        if Defaults.hasCustomClipboardImagePinHotkey {
            HotkeyManager.shared.registerClipboardImagePin { [weak self] in
                self?.handleClipboardImagePinTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterClipboardImagePin()
        }

        if Defaults.hasCustomSelectedImageEditHotkey {
            HotkeyManager.shared.registerSelectedImageEdit { [weak self] in
                self?.handleSelectedImageEditTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterSelectedImageEdit()
        }

        if Defaults.hasCustomClipboardImageEditHotkey {
            HotkeyManager.shared.registerClipboardImageEdit { [weak self] in
                self?.handleClipboardImageEditTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterClipboardImageEdit()
        }

        if Defaults.hasCustomTextRecognitionHotkey {
            HotkeyManager.shared.registerTextRecognition { [weak self] in
                self?.handleTextRecognitionTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterTextRecognition()
        }

        if Defaults.hasCustomCopyImageTextHotkey {
            HotkeyManager.shared.registerCopyImageText { [weak self] in
                self?.handleCopyImageTextTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterCopyImageText()
        }

        if Defaults.hasCustomScreenshotTranslationHotkey {
            HotkeyManager.shared.registerScreenshotTranslation { [weak self] in
                self?.handleScreenshotTranslationTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterScreenshotTranslation()
        }

        if Defaults.hasCustomRecordHotkey {
            HotkeyManager.shared.registerRecord { [weak self] in
                self?.handleRecordingTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterRecord()
        }

        if Defaults.hasCustomImageMergeHotkey {
            HotkeyManager.shared.registerImageMerge { [weak self] in
                self?.handleImageMergeShortcutTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterImageMerge()
        }

        if Defaults.hasCustomFullScreenScreenshotHotkey {
            HotkeyManager.shared.registerFullScreenScreenshot { [weak self] in
                self?.handleFullScreenScreenshotTrigger(fromShortcut: true)
            }
        } else {
            HotkeyManager.shared.unregisterFullScreenScreenshot()
        }

        if Defaults.hasCustomColorPickerHotkey {
            HotkeyManager.shared.registerColorPicker { [weak self] in
                self?.handleColorPickerTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterColorPicker()
        }
    }

    private func unregisterNonScreenshotHotkeys() {
        HotkeyManager.shared.unregisterSelectedImagePin()
        HotkeyManager.shared.unregisterClipboardImagePin()
        HotkeyManager.shared.unregisterSelectedImageEdit()
        HotkeyManager.shared.unregisterClipboardImageEdit()
        HotkeyManager.shared.unregisterTextRecognition()
        HotkeyManager.shared.unregisterCopyImageText()
        HotkeyManager.shared.unregisterScreenshotTranslation()
        HotkeyManager.shared.unregisterRecord()
        HotkeyManager.shared.unregisterImageMerge()
        HotkeyManager.shared.unregisterFullScreenScreenshot()
        HotkeyManager.shared.unregisterColorPicker()
    }

    /// KeyMonitor entry point for plain double-tap ⌘. While an overlay is
    /// active this is the default copy-to-clipboard hotkey; otherwise it falls
    /// through to the regular screenshot trigger.
    private func handleDoubleTapCommand() {
        if recordingEngine != nil {
            stopRecordingAndSave()
            return
        }
        if let overlay = overlayController {
            if !Defaults.hasCustomClipboardHotkey {
                overlay.confirmFromKeyboard()
            }
            return
        }
        handleTrigger(fromShortcut: true)
    }

    func handleTrigger(fromShortcut: Bool = false) {
        if recordingEngine != nil {
            stopRecordingAndSave()
            return
        }
        guard overlayController == nil, recordingEngine == nil else { return }
        if fromShortcut {
            UpdateChecker.shared.checkFromScreenshotShortcutIfDue()
        }
        startCapture()
    }

    func handleRecordingTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        overlayController = OverlayWindowController(
            postCaptureAction: .record,
            onRecordingSelection: { [weak self] rect, screen in
                self?.beginRecording(rect: rect, screen: screen)
            },
            onRequestFocusReturn: {
                focusRestorer.restore()
            },
            onComplete: { [weak self] finalImage in
                self?.handleEditCompletion(finalImage)
            }
        )
        overlayController?.activate()
        applyHotkeyState()
    }

    /// Opens the single image currently selected in Finder directly in the
    /// editor. Returns nil when Finder has no exactly-one editable image.
    private func launchSelectedImageEdit() -> OverlayWindowController? {
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        let onComplete: (NSImage?) -> Void = { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }

        if let url = FinderSelection.currentImageFileURL(),
           let controller = ImageEditLauncher.launch(
               sourceURL: url,
               onRequestFocusReturn: {
                   focusRestorer.restore()
               },
               onComplete: onComplete
           ) {
            return controller
        }

        return nil
    }

    /// Opens the current clipboard image directly in the editor. Returns nil
    /// when the clipboard has no editable image.
    private func launchClipboardImageEdit() -> OverlayWindowController? {
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        let onComplete: (NSImage?) -> Void = { [weak self] finalImage in
            self?.handleEditCompletion(finalImage)
        }

        if let image = ClipboardImageSource.currentImage(),
           let controller = ImageEditLauncher.launch(
               clipboardImage: image,
               onRequestFocusReturn: {
                   focusRestorer.restore()
               },
               onComplete: onComplete
           ) {
            return controller
        }

        return nil
    }

    /// Countdown-triggered capture. It never checks image-edit sources; the
    /// user explicitly asked for a delayed screen capture.
    func handleCountdownTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        countdownActive = true
        CountdownWindow.start(
            seconds: Defaults.countdownSeconds,
            onFinish: { [weak self] in
                self?.countdownActive = false
                self?.startCapture()
            },
            onCancel: { [weak self] in
                self?.countdownActive = false
            }
        )
    }

    /// Pin-hotkey trigger: pin Finder selection onto the screen. Skipped while
    /// a capture overlay is up.
    func handleSelectedImagePinTrigger() {
        guard overlayController == nil, recordingEngine == nil else { return }
        PinLauncher.pinSelectedImagesIfAvailable()
    }

    /// Pin-hotkey trigger: pin the clipboard image onto the screen. Skipped
    /// while a capture overlay is up.
    func handleClipboardImagePinTrigger() {
        guard overlayController == nil, recordingEngine == nil else { return }
        PinLauncher.pinClipboardImageIfAvailable()
    }

    func handleSelectedImageEditTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        guard let controller = launchSelectedImageEdit() else {
            ToastWindow.show(message: L10n.selectedImageEditNoImage)
            return
        }
        overlayController = controller
        applyHotkeyState()
    }

    func handleClipboardImageEditTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        guard let controller = launchClipboardImageEdit() else {
            ToastWindow.show(message: L10n.clipboardImageEditNoImage)
            return
        }
        overlayController = controller
        applyHotkeyState()
    }

    @discardableResult
    func handlePinnedImageEditRequest(_ image: NSImage, beforePresent: () -> Void) -> Bool {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return false }
        beforePresent()

        guard let controller = ImageEditLauncher.launch(
            generatedImage: image,
            source: .pin,
            keepsEditorAcrossSpaces: Defaults.pinAcrossSpaces,
            onComplete: { [weak self] finalImage in
                self?.handleEditCompletion(finalImage)
            }
        ) else {
            return false
        }

        overlayController = controller
        applyHotkeyState()
        return true
    }

    func handleTextRecognitionTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        startCapture(postCaptureAction: .textRecognition)
    }

    func handleCopyImageTextTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        startCapture(postCaptureAction: .copyImageText)
    }

    func handleScreenshotTranslationTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        startCapture(postCaptureAction: .screenshotTranslation)
    }

    func handleImageMergeMenuTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        ImageMergeLauncher.shared.openEmpty()
    }

    func handleImageMergeShortcutTrigger() {
        guard overlayController == nil,
              recordingEngine == nil,
              !countdownActive,
              !ImageMergeLauncher.shared.isWorkbenchActive
        else { return }
        ImageMergeLauncher.shared.openFromShortcutSources()
    }

    func handleColorPickerTrigger() {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        NSApp.activate(ignoringOtherApps: true)
        let didStart = ColorPickerRunner.shared.run(onFinished: {
            focusRestorer.restore()
        })
        if !didStart {
            focusRestorer.restore()
        }
    }

    func handleFullScreenScreenshotTrigger(fromShortcut: Bool = false) {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        if fromShortcut {
            UpdateChecker.shared.checkFromScreenshotShortcutIfDue()
        }

        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        let cursorPoint = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let image = ScreenCapturer.capture(rect: CGDisplayBounds(displayID), screen: screen),
              let controller = ImageEditLauncher.launch(
                generatedImage: image,
                source: .fullScreen,
                onRequestFocusReturn: {
                    focusRestorer.restore()
                },
                onComplete: { [weak self] finalImage in
                    self?.handleEditCompletion(finalImage)
                }
              )
        else {
            ToastWindow.show(message: L10n.fullScreenScreenshotFailed)
            return
        }

        overlayController = controller
        applyHotkeyState()
    }

    func startCapture(postCaptureAction: OverlayWindowController.PostCaptureAction = .edit) {
        guard overlayController == nil, recordingEngine == nil else { return }
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        overlayController = OverlayWindowController(
            postCaptureAction: postCaptureAction,
            onRecordingSelection: { [weak self] rect, screen in
                self?.beginRecording(rect: rect, screen: screen)
            },
            onRequestFocusReturn: {
                focusRestorer.restore()
            },
            onComplete: { [weak self] finalImage in
                self?.handleEditCompletion(finalImage)
            }
        )
        overlayController?.activate()
        applyHotkeyState()
    }

    private func handleEditCompletion(_ finalImage: NSImage?) {
        if let finalImage = finalImage {
            ClipboardManager.copyToClipboard(image: finalImage)
            HistoryManager.shared.add(image: finalImage)
            ToastWindow.show()
        }
        overlayController = nil
        applyHotkeyState()
    }

    private func continueEditingMergedImage(_ image: NSImage) {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return }
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        guard let controller = ImageEditLauncher.launch(
            generatedImage: image,
            source: .merge,
            onRequestFocusReturn: {
                focusRestorer.restore()
            },
            onComplete: { [weak self] finalImage in
                self?.handleEditCompletion(finalImage)
            }
        ) else {
            ToastWindow.show(message: L10n.imageMergeFailed)
            return
        }
        overlayController = controller
        applyHotkeyState()
    }

    private func beginRecording(rect: NSRect, screen: NSScreen) {
        guard recordingEngine == nil else { return }

        recordingScreenRect = rect
        recordingScreen = screen
        recordingCancelRequested = false

        let borderPanel = RecordingBorderPanel(screen: screen)
        borderPanel.setSelectionRect(rect)
        borderPanel.orderFrontRegardless()
        recordingBorderPanel = borderPanel

        let hudPanel = RecordingHUDPanel()
        hudPanel.update(elapsedSeconds: 0)
        hudPanel.positionOnScreen(relativeTo: rect, screen: screen)
        hudPanel.onStopRecording = { [weak self] in
            self?.stopRecordingAndSave()
        }
        hudPanel.onPauseRecording = { [weak self] in
            self?.recordingEngine?.pauseRecording()
        }
        hudPanel.onResumeRecording = { [weak self] in
            self?.recordingEngine?.resumeRecording()
        }
        hudPanel.orderFrontRegardless()
        recordingHUDPanel = hudPanel

        let engine = RecordingEngine()
        engine.onProgress = { [weak self] seconds in
            self?.updateRecordingHUD(seconds: seconds)
        }
        engine.onPauseChanged = { [weak self] paused in
            self?.recordingHUDPanel?.setPaused(paused)
        }
        engine.onCompletion = { [weak self] url, error in
            self?.finishRecording(url: url, error: error)
        }
        recordingEngine = engine
        installRecordingCancelMonitors()
        applyHotkeyState()

        let excludedWindows = [
            recordingBorderPanel.map { CGWindowID($0.windowNumber) },
            recordingHUDPanel.map { CGWindowID($0.windowNumber) },
        ].compactMap { $0 }
        engine.startRecording(rect: rect, screen: screen, excludeWindowNumbers: excludedWindows)
    }

    private func updateRecordingHUD(seconds: Int) {
        recordingHUDPanel?.update(elapsedSeconds: seconds)
        if let screen = recordingScreen, recordingHUDPanel?.userHasDragged != true {
            recordingHUDPanel?.positionOnScreen(relativeTo: recordingScreenRect, screen: screen)
        }
    }

    private func finishRecording(url: URL?, error: Error?) {
        let wasCancelled = recordingCancelRequested
        recordingCancelRequested = false
        stopRecordingUI()

        if wasCancelled {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            ToastWindow.show(message: L10n.recordingCancelled)
            return
        }

        if let error {
            ToastWindow.show(message: L10n.recordingFailed(error.localizedDescription), duration: 3.5)
            return
        }

        guard let url else {
            ToastWindow.show(message: L10n.recordingFailed(RecordingEngine.RecordingError.noFrames.localizedDescription), duration: 3.5)
            return
        }

        promptToSaveRecording(tmpURL: url)
    }

    private func stopRecordingUI() {
        removeRecordingCancelMonitors()
        recordingHUDPanel?.close()
        recordingHUDPanel = nil
        recordingBorderPanel?.close()
        recordingBorderPanel = nil
        recordingEngine = nil
        recordingScreenRect = .zero
        recordingScreen = nil
        applyHotkeyState()
    }

    private func stopRecordingAndSave() {
        guard let recordingEngine else { return }
        recordingEngine.stopRecording()
    }

    private func cancelRecordingFromKeyboard() {
        guard let recordingEngine, !recordingCancelRequested else { return }
        switch recordingEngine.state {
        case .recording, .paused:
            break
        case .idle, .stopping:
            return
        }
        recordingCancelRequested = true
        recordingEngine.cancelRecording()
    }

    private func installRecordingCancelMonitors() {
        removeRecordingCancelMonitors()
        recordingCancelLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isPlainEscape(event) {
                self?.cancelRecordingFromKeyboard()
                return nil
            }
            return event
        }
        recordingCancelGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isPlainEscape(event) {
                self?.cancelRecordingFromKeyboard()
            }
        }
    }

    private func removeRecordingCancelMonitors() {
        if let monitor = recordingCancelLocalMonitor {
            NSEvent.removeMonitor(monitor)
            recordingCancelLocalMonitor = nil
        }
        if let monitor = recordingCancelGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            recordingCancelGlobalMonitor = nil
        }
    }

    private static func isPlainEscape(_ event: NSEvent) -> Bool {
        let activeModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return event.keyCode == 53 && activeModifiers.isEmpty
    }

    private func promptToSaveRecording(tmpURL: URL) {
        if let format = Defaults.recordingSavePreference.format {
            saveRecordingToConfiguredDirectory(tmpURL: tmpURL, format: format)
            return
        }

        promptToChooseRecordingFormat(tmpURL: tmpURL)
    }

    private func promptToChooseRecordingFormat(tmpURL: URL) {
        var selectedFormat = Defaults.recordingSaveFormat
        let alert = NSAlert()
        alert.messageText = L10n.recordingFormatChoiceTitle
        alert.informativeText = L10n.recordingFormatChoiceMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.saveRecordingPrompt)
        alert.addButton(withTitle: L10n.shortcutCancel)
        alert.accessoryView = RecordingSaveAccessoryView(initialFormat: selectedFormat) { format in
            selectedFormat = format
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? FileManager.default.removeItem(at: tmpURL)
            return
        }

        Defaults.recordingSaveFormat = selectedFormat
        saveRecordingToConfiguredDirectory(tmpURL: tmpURL, format: selectedFormat)
    }

    private func saveRecordingToConfiguredDirectory(tmpURL: URL, format: ScreenRecordingFormat) {
        do {
            let filename = FilenameTemplate.recordingFileName(fileExtension: format.fileExtension)
            let destination = try SaveDestination.uniqueFile(in: Defaults.recordingSaveDirectory, fileName: filename)
            saveRecording(tmpURL: tmpURL, destination: destination, format: format)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            ToastWindow.show(message: L10n.recordingFailed(error.localizedDescription), duration: 3.5)
        }
    }

    private func saveRecording(tmpURL: URL, destination: URL, format: ScreenRecordingFormat) {
        switch format {
        case .mp4:
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tmpURL, to: destination)
                showSavedRecording(destination)
            } catch {
                ToastWindow.show(message: L10n.recordingFailed(error.localizedDescription), duration: 3.5)
            }
        case .gif:
            ToastWindow.show(message: L10n.recordingExportingGIF, duration: 600)
            RecordingExporter.exportGIF(from: tmpURL, to: destination) { result in
                ToastWindow.dismiss()
                switch result {
                case .success:
                    try? FileManager.default.removeItem(at: tmpURL)
                    self.showSavedRecording(destination)
                case .failure(let error):
                    ToastWindow.show(message: L10n.recordingFailed(error.localizedDescription), duration: 3.5)
                    NSWorkspace.shared.activateFileViewerSelecting([tmpURL])
                }
            }
        }
    }

    private func showSavedRecording(_ destination: URL) {
        let directoryPath = SaveDestination.displayPath(destination.deletingLastPathComponent())
        ToastWindow.show(message: L10n.recordingSaved(to: directoryPath))
        if Defaults.autoRevealSavedFiles {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private func openSettings() {
        configuredSettingsController().showAsSettings()
    }
}

private final class RecordingSaveAccessoryView: NSView {
    private static let labelTrailingInset: CGFloat = 170
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onFormatChanged: (ScreenRecordingFormat) -> Void

    init(initialFormat: ScreenRecordingFormat, onFormatChanged: @escaping (ScreenRecordingFormat) -> Void) {
        self.onFormatChanged = onFormatChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 32))

        let label = NSTextField(labelWithString: L10n.recordingFormatLabel)
        label.translatesAutoresizingMaskIntoConstraints = false

        popup.translatesAutoresizingMaskIntoConstraints = false
        for format in ScreenRecordingFormat.allCases {
            popup.addItem(withTitle: format.displayName)
            popup.lastItem?.representedObject = format.rawValue
        }
        popup.selectItem(withTitle: initialFormat.displayName)
        popup.target = self
        popup.action = #selector(formatDidChange)

        addSubview(label)
        addSubview(popup)

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelTrailingInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func formatDidChange() {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let format = ScreenRecordingFormat(rawValue: raw)
        else {
            return
        }
        onFormatChanged(format)
    }
}
