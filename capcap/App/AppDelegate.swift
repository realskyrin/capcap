import AppKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let shareHandoffNotificationName = Notification.Name("cn.skyrin.capcap.share-handoff")

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
    private var historyPanelController: HistoryPanelController?
    private var countdownActive = false
    private var appInitialized = false
    private var suspendedEditDraft: OverlayWindowController.SuspendedEditDraft?
    private var pendingReopenSettingsWorkItem: DispatchWorkItem?
    private var pendingOpenImageURLs: [URL] = []
    private var startupDialogShown = false
    private let clipboardTextHistoryMonitor = ClipboardTextHistoryMonitor()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerShareHandoffObserver()
        clipboardTextHistoryMonitor.start()

        if appInitialized {
            flushPendingOpenImageURLs()
        } else if LaunchAtLogin.isEnabled && AppPermissions.allRequiredGranted {
            initializeApp()
            flushPendingOpenImageURLs()
        } else if !pendingOpenImageURLs.isEmpty {
            initializeApp()
            flushPendingOpenImageURLs()
        } else {
            showStartupDialog()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardTextHistoryMonitor.stop()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard appInitialized else { return }
        overlayController?.screenParametersDidChange()
        let displayIDs = Set(NSScreen.screens.compactMap { screen in
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID
        })
        ScreenSnapshotProvider.shared.invalidateAndPrewarm(displayIDs: displayIDs)
        OverlayWindowController.invalidateAndPrewarmPresentationSurfaces()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if appInitialized {
            scheduleSettingsOpenFromReopen()
        } else {
            showStartupDialog()
        }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = requestOpenImageURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        requestOpenImageURLs([URL(fileURLWithPath: filename)])
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let handled = requestOpenImageURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    private func showStartupDialog() {
        startupDialogShown = true
        let settingsController = configuredSettingsController()
        settingsController.showAsStartupDialog()
    }

    private func configuredSettingsController() -> SettingsWindowController {
        let settingsController = SettingsWindowController.shared
        settingsController.onMenuBarToggle = { [weak self] visible in
            self?.statusBarController?.setMenuBarVisible(visible)
        }
        settingsController.onLaunch = { [weak self] in
            self?.startupDialogShown = false
            self?.initializeApp()
        }
        return settingsController
    }

    private func registerShareHandoffObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShareHandoffNotification(_:)),
            name: Self.shareHandoffNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func initializeApp() {
        guard !appInitialized else { return }
        appInitialized = true

        ImageEditLauncher.clearTempDir()
        OverlayWindowController.prewarmPresentationSurfaces()
        if AppPermissions.screenRecordingGranted {
            ScreenSnapshotProvider.shared.prewarm()
        }
        ImageMergeLauncher.shared.onContinueEditing = { [weak self] image in
            self?.continueEditingMergedImage(image)
        }
        historyPanelController = HistoryPanelController { [weak self] entry in
            _ = self?.launchImageFile(entry.fileURL)
        }

        statusBarController = StatusBarController(
            onTakeScreenshot: { [weak self] in
                self?.handleTrigger(
                    triggerContext: CaptureTriggerContext(source: .menu)
                )
            },
            onTakeFullScreenScreenshot: { [weak self] in self?.handleFullScreenScreenshotTrigger() },
            onRecord: { [weak self] in self?.handleRecordingTrigger() },
            onMergeImages: { [weak self] in self?.handleImageMergeMenuTrigger() },
            onColorPicker: { [weak self] in self?.handleColorPickerTrigger() },
            onOpenHistoryPanel: { [weak self] in self?.handleHistoryPanelTrigger(holdOpenUntilMouseEnters: true) },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        statusBarController.setMenuBarVisible(Defaults.showMenuBar)

        keyMonitor = KeyMonitor(
            onTrigger: { [weak self] context in
                guard let self else {
                    context.finish(.ignored)
                    return
                }
                self.handleDoubleTapCommand(triggerContext: context)
            },
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
                HotkeyManager.shared.register { [weak self] context in
                    guard let self else {
                        context.finish(.ignored)
                        return
                    }
                    self.stopRecordingAndSave()
                    context.finish(.rerouted)
                }
            } else {
                HotkeyManager.shared.unregister()
            }
            HotkeyManager.shared.unregisterCountdown()
            return
        }

        keyMonitor?.isEnabled = true
        if Defaults.hasCustomScreenshotHotkey {
            HotkeyManager.shared.register { [weak self] context in
                guard let self else {
                    context.finish(.ignored)
                    return
                }
                self.handleTrigger(fromShortcut: true, triggerContext: context)
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

        if Defaults.hasCustomClipboardTextPinHotkey {
            HotkeyManager.shared.registerClipboardTextPin { [weak self] in
                self?.handleClipboardTextPinTrigger()
            }
        } else {
            HotkeyManager.shared.unregisterClipboardTextPin()
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

        if Defaults.hasCustomHistoryPanelHotkey {
            HotkeyManager.shared.registerHistoryPanel { [weak self] in
                self?.handleHistoryPanelTrigger(holdOpenUntilMouseEnters: true)
            }
        } else {
            HotkeyManager.shared.unregisterHistoryPanel()
        }
    }

    private func unregisterNonScreenshotHotkeys() {
        HotkeyManager.shared.unregisterSelectedImagePin()
        HotkeyManager.shared.unregisterClipboardImagePin()
        HotkeyManager.shared.unregisterClipboardTextPin()
        HotkeyManager.shared.unregisterSelectedImageEdit()
        HotkeyManager.shared.unregisterClipboardImageEdit()
        HotkeyManager.shared.unregisterTextRecognition()
        HotkeyManager.shared.unregisterCopyImageText()
        HotkeyManager.shared.unregisterScreenshotTranslation()
        HotkeyManager.shared.unregisterRecord()
        HotkeyManager.shared.unregisterImageMerge()
        HotkeyManager.shared.unregisterFullScreenScreenshot()
        HotkeyManager.shared.unregisterColorPicker()
        HotkeyManager.shared.unregisterHistoryPanel()
    }

    @discardableResult
    private func requestOpenImageURLs(_ urls: [URL]) -> Bool {
        guard Self.containsImageFile(in: urls) else {
            if appInitialized {
                ToastWindow.show(message: L10n.openImageNoImage)
            }
            return false
        }

        pendingOpenImageURLs.append(contentsOf: urls)
        cancelPendingReopenSettings()

        if appInitialized {
            flushPendingOpenImageURLs()
        } else {
            initializeApp()
            if startupDialogShown {
                SettingsWindowController.shared.dismissStartupDialogForExternalOpen()
                startupDialogShown = false
            }
            flushPendingOpenImageURLs()
        }

        return true
    }

    private func flushPendingOpenImageURLs() {
        guard appInitialized, !pendingOpenImageURLs.isEmpty else { return }
        let urls = pendingOpenImageURLs
        pendingOpenImageURLs.removeAll()
        _ = openImageURLs(urls)
    }

    @discardableResult
    private func openImageURLs(_ urls: [URL]) -> Bool {
        guard overlayController == nil, recordingEngine == nil, !countdownActive else { return true }
        guard let url = urls.lazy.compactMap(Self.resolvedImageFileURL).first(where: Self.isImageFile) else {
            ToastWindow.show(message: L10n.openImageNoImage)
            return false
        }

        let didLaunch = launchImageFile(url)
        if didLaunch {
            cancelPendingReopenSettings()
        }
        return didLaunch
    }

    @discardableResult
    private func launchImageFile(_ url: URL) -> Bool {
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        guard let controller = ImageEditLauncher.launch(
            sourceURL: url,
            onRequestFocusReturn: {
                focusRestorer.restore()
            },
            onSuspend: { [weak self] draft in
                self?.handleEditSuspension(draft)
            },
            onComplete: { [weak self] finalImage in
                self?.handleEditCompletion(finalImage)
            }
        ) else {
            ToastWindow.show(message: L10n.openImageNoImage)
            return false
        }

        overlayController = controller
        applyHotkeyState()
        return true
    }

    private func handleHistoryPanelTrigger(holdOpenUntilMouseEnters: Bool = false) {
        historyPanelController?.toggleFromUserRequest(holdOpenUntilMouseEnters: holdOpenUntilMouseEnters)
    }

    /// KeyMonitor entry point for plain double-tap ⌘. While an overlay is
    /// active this is the default copy-to-clipboard hotkey; otherwise it falls
    /// through to the regular screenshot trigger.
    private func handleDoubleTapCommand(triggerContext: CaptureTriggerContext) {
        if recordingEngine != nil {
            stopRecordingAndSave()
            triggerContext.finish(.rerouted)
            return
        }
        if let overlay = overlayController {
            if !Defaults.hasCustomClipboardHotkey {
                overlay.confirmFromKeyboard()
            }
            triggerContext.finish(.rerouted)
            return
        }
        handleTrigger(fromShortcut: true, triggerContext: triggerContext)
    }

    func handleTrigger(
        fromShortcut: Bool = false,
        triggerContext: CaptureTriggerContext? = nil
    ) {
        let context = triggerContext ?? CaptureTriggerContext(
            source: fromShortcut ? .keyboardShortcut : .programmatic
        )
        context.mark(.handleTrigger)

        if recordingEngine != nil {
            stopRecordingAndSave()
            context.finish(.rerouted)
            return
        }
        guard overlayController == nil, recordingEngine == nil else {
            context.finish(.ignored)
            return
        }
        if resumeSuspendedEditIfAvailable() {
            context.finish(.rerouted)
            return
        }
        startCapture(
            triggerContext: context,
            onFirstFramePresented: fromShortcut ? {
                UpdateChecker.shared.checkFromScreenshotShortcutIfDue()
            } : nil
        )
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
               onSuspend: { [weak self] draft in
                   self?.handleEditSuspension(draft)
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
               onSuspend: { [weak self] draft in
                   self?.handleEditSuspension(draft)
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
                self?.startCapture(
                    triggerContext: CaptureTriggerContext(source: .countdown)
                )
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

    /// Pin-hotkey trigger: render clipboard text into a desktop text pin.
    /// Skipped while a capture overlay is up.
    func handleClipboardTextPinTrigger() {
        guard overlayController == nil, recordingEngine == nil else { return }
        PinLauncher.pinClipboardTextIfAvailable()
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
            onSuspend: { [weak self] draft in
                self?.handleEditSuspension(draft)
            },
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
                onSuspend: { [weak self] draft in
                    self?.handleEditSuspension(draft)
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

    func startCapture(
        postCaptureAction: OverlayWindowController.PostCaptureAction = .edit,
        triggerContext: CaptureTriggerContext? = nil,
        onFirstFramePresented: (() -> Void)? = nil
    ) {
        let context = triggerContext ?? CaptureTriggerContext(source: .programmatic)
        context.mark(.startCapture)
        guard overlayController == nil, recordingEngine == nil else {
            context.finish(.ignored)
            return
        }
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        overlayController = OverlayWindowController(
            postCaptureAction: postCaptureAction,
            triggerContext: context,
            onFirstFramePresented: onFirstFramePresented,
            onRecordingSelection: { [weak self] rect, screen in
                self?.beginRecording(rect: rect, screen: screen)
            },
            onRequestFocusReturn: {
                focusRestorer.restore()
            },
            onSuspend: { [weak self] draft in
                self?.handleEditSuspension(draft)
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
            let quality = Defaults.screenshotClipboardQuality
            if quality.usesLossyCompression {
                ToastWindow.show(message: L10n.screenshotQualityCompressingClipboard, duration: 600)
            }
            ImageOutputEncoder.encodeClipboardAsync(image: finalImage, quality: quality) { result in
                if quality.usesLossyCompression {
                    ToastWindow.dismiss()
                }
                switch result {
                case .failure:
                    HistoryManager.shared.add(image: finalImage)
                    ToastWindow.show(message: L10n.screenshotCompressionFailed, duration: 3.0)
                case .success(let output):
                    ClipboardManager.copyToClipboard(imageOutput: output)
                    HistoryManager.shared.add(image: finalImage)
                    ToastWindow.show()
                }
            }
        }
        overlayController = nil
        applyHotkeyState()
    }

    private func handleEditSuspension(_ draft: OverlayWindowController.SuspendedEditDraft) {
        suspendedEditDraft = draft
        overlayController = nil
        applyHotkeyState()
        ToastWindow.show(
            message: L10n.editSuspendedToast,
            on: screen(for: draft),
            duration: 3.0
        )
    }

    private func resumeSuspendedEditIfAvailable() -> Bool {
        guard let draft = suspendedEditDraft else { return false }
        let focusRestorer = SourceAppFocusRestorer.captureFrontmostApplication()
        let controller = OverlayWindowController(
            suspendedDraft: draft,
            onRecordingSelection: { [weak self] rect, screen in
                self?.beginRecording(rect: rect, screen: screen)
            },
            onRequestFocusReturn: {
                focusRestorer.restore()
            },
            onSuspend: { [weak self] draft in
                self?.handleEditSuspension(draft)
            },
            onComplete: { [weak self] finalImage in
                self?.handleEditCompletion(finalImage)
            }
        )
        suspendedEditDraft = nil
        overlayController = controller
        controller.activate()
        applyHotkeyState()
        return true
    }

    private func screen(for draft: OverlayWindowController.SuspendedEditDraft) -> NSScreen? {
        if let displayID = draft.screenDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
           }) {
            return screen
        }
        return NSScreen.screens.first(where: { $0.frame == draft.screenFrame }) ?? NSScreen.main
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
            onSuspend: { [weak self] draft in
                self?.handleEditSuspension(draft)
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
        ].compactMap { $0 } + ToastWindow.captureExcludedWindowNumbers
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
        HistoryManager.shared.addFile(destination)
        let directoryPath = SaveDestination.displayPath(destination.deletingLastPathComponent())
        ToastWindow.show(message: L10n.recordingSaved(to: directoryPath))
        if Defaults.autoRevealSavedFiles {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private func openSettings() {
        configuredSettingsController().showAsSettings()
    }

    private func scheduleSettingsOpenFromReopen() {
        cancelPendingReopenSettings()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.overlayController == nil else { return }
            self.openSettings()
        }
        pendingReopenSettingsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func cancelPendingReopenSettings() {
        pendingReopenSettingsWorkItem?.cancel()
        pendingReopenSettingsWorkItem = nil
    }

    @objc private func handleShareHandoffNotification(_ notification: Notification) {
        guard let filePath = notification.userInfo?["file"] as? String,
              !filePath.isEmpty
        else {
            return
        }

        cancelPendingReopenSettings()
        requestOpenImageURLs([URL(fileURLWithPath: filePath)])
    }

    private static func containsImageFile(in urls: [URL]) -> Bool {
        urls.lazy.compactMap(resolvedImageFileURL).contains(where: isImageFile)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey])
        if values?.contentType?.conforms(to: .image) == true {
            return true
        }

        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func resolvedImageFileURL(from url: URL) -> URL? {
        if url.isFileURL {
            return url
        }

        guard url.scheme?.caseInsensitiveCompare("capcap") == .orderedSame,
              url.host?.caseInsensitiveCompare("edit") == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let filePath = components.queryItems?.first(where: { $0.name == "file" })?.value,
              !filePath.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: filePath)
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
