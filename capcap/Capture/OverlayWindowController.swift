import AppKit
import QuartzCore

typealias WindowSnapshotLoader = @Sendable (CGFloat) -> Result<[DetectedWindow], WindowDetectionError>
typealias WindowImageLoader = @Sendable (CGWindowID, NSSize) async throws -> NSImage?

struct CaptureResult {
    let rect: CGRect       // In CG coordinates (top-left origin) for capture
    let screen: NSScreen   // The screen where selection was made
    let screenRect: NSRect // In AppKit coordinates for editor positioning
}

class OverlayWindowController {
    /// Where a preset image came from — drives the source-specific edit hint.
    enum PresetSource {
        case finder
        case clipboard
        case pin
        case merge
        case fullScreen
    }

    enum PostCaptureAction {
        case edit
        case textRecognition
        case copyImageText
        case screenshotTranslation
        case record

        var cursorChipText: String {
            switch self {
            case .record:
                return L10n.dragToRecord
            case .edit:
                return L10n.dragToScreenshot
            case .textRecognition:
                return L10n.dragToTextRecognition
            case .copyImageText:
                return L10n.dragToCopyImageText
            case .screenshotTranslation:
                return L10n.dragToScreenshotTranslation
            }
        }
    }

    struct SuspendedEditDraft {
        let captureRect: CGRect
        let screenDisplayID: CGDirectDisplayID?
        let screenFrame: NSRect
        let selectionRect: NSRect
        let selectionViewRect: NSRect
        let selectionSizeLabelOverride: String?
        let selectionLocked: Bool
        let selectionInteractionEnabled: Bool
        let preSnapshot: CGImage?
        let overrideBaseImage: NSImage?
        let windowBaseImage: NSImage?
        let isWindowCapture: Bool
        let editorState: EditWindowController.RestorableState
        let keepsEditorAcrossSpaces: Bool
    }

    private var windows: [NSWindow] = []
    private var chipWindow: CursorChipWindow?
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    private var rightMouseLocalMonitor: Any?
    private var rightMouseGlobalMonitor: Any?
    private var editController: EditWindowController?
    private var activeSelectionView: SelectionView?
    private var activeScreen: NSScreen?
    private var historyEntries: [HistoryEntry] = []
    private var historyEntryIndex: Int?
    private var historyEditorDrafts: [URL: EditWindowController.RestorableState] = [:]
    private var activeEditorContext: ActiveEditorContext?
    private var currentEditHistoryDraft: CurrentEditHistoryDraft?
    private let windowDetector = WindowDetector()
    private let windowSnapshotLoader: WindowSnapshotLoader
    private let windowImageLoader: WindowImageLoader
    private let snapshotProvider: ScreenSnapshotProviding
    private let triggerContext: CaptureTriggerContext?
    private let onFirstFramePresented: (() -> Void)?
    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]
    private var selectionViewsByDisplayID: [CGDirectDisplayID: SelectionView] = [:]
    private var expectedSnapshotDisplayIDs = Set<CGDirectDisplayID>()
    private var failedSnapshotDisplayIDs = Set<CGDirectDisplayID>()
    private var snapshotCancellation: ScreenSnapshotCancellation?
    private var windowCaptureTask: Task<Void, Never>?
    private var pendingWindowCapture: PendingWindowCapture?
    private var snapshotCaptureFinished = false
    private var pendingSelection: PendingSelection?
    private let onComplete: (NSImage?) -> Void
    private let onRequestFocusReturn: (() -> Void)?
    private let onRecordingSelection: ((NSRect, NSScreen) -> Void)?
    private let onSuspend: ((SuspendedEditDraft) -> Void)?
    private let postCaptureAction: PostCaptureAction

    /// Image-edit mode: when set, `activate()` skips the user's drag-to-select
    /// step and immediately opens the editor on the supplied image, sized to
    /// fit the screen with margins.
    private let presetImage: NSImage?
    /// In image-edit mode, where `presetImage` came from. nil otherwise.
    private let presetSource: PresetSource?
    private let suspendedDraft: SuspendedEditDraft?
    private let keepsEditorAcrossSpaces: Bool
    private var presentationScheduled = false
    /// Bumped whenever a presentation starts or ends so stale asynchronous
    /// snapshot/window-list callbacks cannot mutate a newer overlay session.
    private var presentationGeneration = 0
    private var sessionEnded = false
    private var firstFrameReported = false
    private var firstFrameTargetDisplayID: CGDirectDisplayID?

    private struct ActiveEditorContext {
        let captureRect: CGRect
        let screen: NSScreen
        let selectionRect: NSRect
        let selectionViewRect: NSRect
        weak var hostSelectionView: SelectionView?
        let selectionViewState: SelectionViewState
        let preSnapshot: CGImage?
        let overrideBaseImage: NSImage?
        let windowBaseImage: NSImage?
        let isWindowCapture: Bool
    }

    private struct CurrentEditHistoryDraft {
        let captureRect: CGRect
        let screen: NSScreen
        let selectionRect: NSRect
        let selectionViewRect: NSRect
        weak var hostSelectionView: SelectionView?
        let selectionViewState: SelectionViewState
        let preSnapshot: CGImage?
        let overrideBaseImage: NSImage?
        let windowBaseImage: NSImage?
        let isWindowCapture: Bool
        var editorState: EditWindowController.RestorableState?
    }

    private struct SelectionViewState {
        let selectionSizeLabelOverride: String?
        let selectionLocked: Bool
        let selectionInteractionEnabled: Bool

        init(selectionView: SelectionView) {
            selectionSizeLabelOverride = selectionView.selectionSizeLabelOverride
            selectionLocked = selectionView.selectionLocked
            selectionInteractionEnabled = selectionView.selectionInteractionEnabled
        }

        init(
            selectionSizeLabelOverride: String?,
            selectionLocked: Bool,
            selectionInteractionEnabled: Bool
        ) {
            self.selectionSizeLabelOverride = selectionSizeLabelOverride
            self.selectionLocked = selectionLocked
            self.selectionInteractionEnabled = selectionInteractionEnabled
        }

        func apply(to selectionView: SelectionView) {
            selectionView.selectionSizeLabelOverride = selectionSizeLabelOverride
            selectionView.selectionLocked = selectionLocked
            selectionView.selectionInteractionEnabled = selectionInteractionEnabled
        }
    }

    private struct PendingSelection {
        let rect: NSRect
        let screenRect: NSRect
        let captureRect: CGRect
        let screen: NSScreen
        let selectionView: SelectionView
        let displayID: CGDirectDisplayID
        let isWindowSelection: Bool
        let windowID: CGWindowID?
    }

    private struct PendingWindowCapture {
        let id: UUID
        let generation: Int
        let request: PendingSelection
        let preSnapshot: CGImage?
    }

    /// Route the default copy-to-clipboard hotkey (double-tap ⌘) into the
    /// editor while the overlay is active. No-op when the editor isn't up yet.
    func confirmFromKeyboard() {
        editController?.confirmFromKeyboard()
    }

    static func prewarmPresentationSurfaces() {
        OverlayPanelPool.shared.prewarm(screens: NSScreen.screens)
    }

    static func invalidateAndPrewarmPresentationSurfaces() {
        OverlayPanelPool.shared.invalidateAndPrewarm(screens: NSScreen.screens)
    }

    func screenParametersDidChange() {
        guard presentationScheduled,
              !sessionEnded,
              editController == nil else { return }
        cancel()
    }

    init(
        postCaptureAction: PostCaptureAction = .edit,
        triggerContext: CaptureTriggerContext = CaptureTriggerContext(source: .programmatic),
        snapshotProvider: ScreenSnapshotProviding = ScreenSnapshotProvider.shared,
        windowSnapshotLoader: @escaping WindowSnapshotLoader = {
            WindowDetector.snapshot(primaryScreenArea: $0)
        },
        windowImageLoader: @escaping WindowImageLoader = { windowID, pointSize in
            try await ScreenCapturer.captureWindowAsync(
                windowID: windowID,
                pointSize: pointSize
            )
        },
        onFirstFramePresented: (() -> Void)? = nil,
        onRecordingSelection: ((NSRect, NSScreen) -> Void)? = nil,
        onRequestFocusReturn: (() -> Void)? = nil,
        onSuspend: ((SuspendedEditDraft) -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.presetImage = nil
        self.presetSource = nil
        self.suspendedDraft = nil
        self.keepsEditorAcrossSpaces = false
        self.postCaptureAction = postCaptureAction
        self.triggerContext = triggerContext
        self.snapshotProvider = snapshotProvider
        self.windowSnapshotLoader = windowSnapshotLoader
        self.windowImageLoader = windowImageLoader
        self.onFirstFramePresented = onFirstFramePresented
        self.onRecordingSelection = onRecordingSelection
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onSuspend = onSuspend
        self.onComplete = onComplete
    }

    init(
        presetImage: NSImage,
        presetSource: PresetSource,
        keepsEditorAcrossSpaces: Bool = false,
        onRequestFocusReturn: (() -> Void)? = nil,
        onSuspend: ((SuspendedEditDraft) -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.presetImage = presetImage
        self.presetSource = presetSource
        self.suspendedDraft = nil
        self.keepsEditorAcrossSpaces = keepsEditorAcrossSpaces
        self.postCaptureAction = .edit
        self.triggerContext = nil
        self.snapshotProvider = ScreenSnapshotProvider.shared
        self.windowSnapshotLoader = { WindowDetector.snapshot(primaryScreenArea: $0) }
        self.windowImageLoader = { windowID, pointSize in
            try await ScreenCapturer.captureWindowAsync(
                windowID: windowID,
                pointSize: pointSize
            )
        }
        self.onFirstFramePresented = nil
        self.onRecordingSelection = nil
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onSuspend = onSuspend
        self.onComplete = onComplete
    }

    init(
        suspendedDraft: SuspendedEditDraft,
        onRecordingSelection: ((NSRect, NSScreen) -> Void)? = nil,
        onRequestFocusReturn: (() -> Void)? = nil,
        onSuspend: ((SuspendedEditDraft) -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.presetImage = nil
        self.presetSource = nil
        self.suspendedDraft = suspendedDraft
        self.keepsEditorAcrossSpaces = suspendedDraft.keepsEditorAcrossSpaces
        self.postCaptureAction = .edit
        self.triggerContext = nil
        self.snapshotProvider = ScreenSnapshotProvider.shared
        self.windowSnapshotLoader = { WindowDetector.snapshot(primaryScreenArea: $0) }
        self.windowImageLoader = { windowID, pointSize in
            try await ScreenCapturer.captureWindowAsync(
                windowID: windowID,
                pointSize: pointSize
            )
        }
        self.onFirstFramePresented = nil
        self.onRecordingSelection = onRecordingSelection
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onSuspend = onSuspend
        self.onComplete = onComplete
    }

    func activate() {
        guard !presentationScheduled else { return }
        presentationScheduled = true
        triggerContext?.mark(.activateRequested)
        ToastWindow.dismiss()
        beginOverlaySession()
    }

    var isOverlayPresented: Bool {
        !windows.isEmpty && windows.allSatisfy(\.isVisible)
    }

    var isSelectionInteractive: Bool {
        windows.compactMap { $0.contentView as? SelectionView }
            .contains(where: \.selectionInteractionEnabled)
    }

    var activeSelectionViews: [SelectionView] {
        windows.compactMap { $0.contentView as? SelectionView }
    }

    var isWaitingForSnapshot: Bool { pendingSelection != nil }
    var isWaitingForWindowCapture: Bool { pendingWindowCapture != nil }
    var appliedSnapshotCount: Int { screenSnapshots.count }
    var hasActiveEditor: Bool { editController != nil }
    var isCaptureSessionEnded: Bool { sessionEnded }

    private func beginOverlaySession() {
        presentationGeneration += 1
        let generation = presentationGeneration
        sessionEnded = false
        screenSnapshots.removeAll()
        selectionViewsByDisplayID.removeAll()
        failedSnapshotDisplayIDs.removeAll()
        snapshotCaptureFinished = false
        pendingSelection = nil
        firstFrameReported = false

        let targets = Self.snapshotTargets()
        expectedSnapshotDisplayIDs = Set(targets.map(\.displayID))
        firstFrameTargetDisplayID = Self.displayIDUnderPointer()
            ?? targets.first?.displayID
        triggerContext?.mark(.backgroundPreparationStarted)

        startWindowEnumeration(generation: generation)
        startSnapshotCapture(targets: targets, generation: generation)
        presentOverlay(generation: generation)
    }

    private func startSnapshotCapture(
        targets: [ScreenSnapshotTarget],
        generation: Int
    ) {
        guard shouldCaptureSnapshots,
              generation == presentationGeneration,
              !sessionEnded else { return }
        triggerContext?.mark(.snapshotCaptureStarted)
        let context = triggerContext
        snapshotCancellation = snapshotProvider.capture(targets: targets) { [weak self] event in
            context?.mark(.snapshotResultReady)
            MainRunLoopScheduler.perform {
                self?.handleSnapshotEvent(event, generation: generation)
            }
        }
    }

    private static func snapshotTargets() -> [ScreenSnapshotTarget] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return nil }
            return ScreenSnapshotTarget(
                displayID: displayID,
                bounds: CGDisplayBounds(displayID),
                scale: screen.backingScaleFactor
            )
        }
    }

    private var shouldCaptureSnapshots: Bool {
        guard presetImage == nil, suspendedDraft == nil else { return false }
        if case .record = postCaptureAction { return false }
        return true
    }

    private func startWindowEnumeration(generation: Int) {
        guard presetImage == nil,
              suspendedDraft == nil,
              let primaryFrame = NSScreen.screens.first?.frame else { return }
        let primaryScreenArea = primaryFrame.width * primaryFrame.height

        let snapshotLoader = windowSnapshotLoader
        let context = triggerContext
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = snapshotLoader(primaryScreenArea)
            context?.mark(.windowEnumerationReady)
            MainRunLoopScheduler.perform {
                guard let self,
                      generation == self.presentationGeneration,
                      !self.sessionEnded else { return }
                self.triggerContext?.mark(.windowEnumerationApplied)
                switch result {
                case .success(let windows):
                    self.windowDetector.apply(windows)
                    for selectionView in self.selectionViewsByDisplayID.values {
                        selectionView.refreshHoverAtCurrentMouseLocation()
                    }
                case .failure(let error):
                    self.logPreparationFailure("window-enumeration", error: error)
                }
            }
        }
    }

    private func handleSnapshotEvent(_ event: ScreenSnapshotEvent, generation: Int) {
        guard generation == presentationGeneration, !sessionEnded else { return }
        triggerContext?.mark(.snapshotResultApplied)

        switch event {
        case .image(let displayID, let image):
            screenSnapshots[displayID] = image
            if let selectionView = selectionViewsByDisplayID[displayID] {
                selectionView.setBackgroundSnapshot(
                    cgImage: image,
                    pointSize: selectionView.bounds.size
                )
            }
            resumePendingSelectionIfReady(displayID: displayID)
        case .failure(let displayID, let error):
            failedSnapshotDisplayIDs.insert(displayID)
            logPreparationFailure("screen-snapshot-\(displayID)", error: error)
            if pendingSelection?.displayID == displayID {
                finishSelectionCaptureFailure()
            }
        case .finished:
            snapshotCaptureFinished = true
            if let pendingSelection,
               screenSnapshots[pendingSelection.displayID] == nil {
                finishSelectionCaptureFailure()
            }
        }
    }

    private func logPreparationFailure(_ operation: String, error: Error) {
        let message = String(describing: error)
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(
                "overlay-prepare",
                "async-preparation-failed",
                metadata: ["operation": operation, "error": message]
            )
        }
    }

    private func presentOverlay(generation: Int) {
        guard windows.isEmpty else { return }

        // The transparent selection shell is deliberately created without
        // waiting for frozen pixels. Until a snapshot arrives, AppKit simply
        // reveals the live desktop through the clear panel.
        for screen in NSScreen.screens {
            let window = OverlayPanelPool.shared.lease(for: screen)
            let surfacePresentationToken = window.surfacePresentationToken
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.sharingType = Defaults.demoMode ? .readOnly : .none
            window.acceptsMouseMovedEvents = true
            window.animationBehavior = .none

            let selectionView = SelectionView(frame: screen.frame)
            selectionView.delegate = self
            selectionView.windowDetector = windowDetector
            selectionView.aspectRatio = usesAspectRatioSelection ? Self.persistedSelectionAspectRatio : nil
            selectionView.onFirstDrawCompleted = { [weak self] in
                self?.recordFirstDraw(generation: generation)
            }
            selectionView.onFirstFramePresented = { [weak self] in
                guard OverlayPanelPool.shared.markSurfacePresented(
                    window,
                    for: screen,
                    presentationToken: surfacePresentationToken
                ) else { return }
                let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID
                self?.recordFirstFrame(
                    generation: generation,
                    displayID: displayID
                )
            }
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               let snapshot = screenSnapshots[displayID] {
                selectionView.setBackgroundSnapshot(cgImage: snapshot, pointSize: screen.frame.size)
            }
            window.contentView = selectionView

            if let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID {
                selectionViewsByDisplayID[displayID] = selectionView
            }

            windows.append(window)
        }

        // Show all overlay windows in one batch with animations disabled.
        triggerContext?.mark(.overlayInitialized)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in windows {
            window.orderFrontRegardless()
        }
        CATransaction.commit()
        triggerContext?.mark(.overlayOrderedFront)

        chipWindow = CursorChipWindow(text: currentCursorChipText)
        chipWindow?.show()

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.editController?.isTextEditing == true {
                return event
            }
            if self?.editController?.confirmCropFromKeyboard(for: event) == true {
                return nil
            }
            if self?.editController?.undoFromKeyboard(for: event) == true {
                return nil
            }
            if self?.editController?.redoFromKeyboard(for: event) == true {
                return nil
            }
            if self?.editController?.handleAnnotationClipboardShortcutFromKeyboard(for: event) == true {
                return nil
            }
            if self?.editController?.nudgeSelectedAnnotationFromKeyboard(for: event) == true {
                return nil
            }
            if self?.editController?.deleteSelectedAnnotationFromKeyboard(for: event) == true {
                return nil
            }
            if self?.switchHistoryImageFromKeyboard(for: event) == true {
                return nil
            }
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            if self?.cycleSelectionAspectRatioFromKeyboard(for: event) == true {
                return nil
            }
            if HotkeyManager.eventMatchesClipboardHotkey(event) {
                self?.editController?.confirmFromKeyboard()
                return nil
            }
            if HotkeyManager.eventMatchesFileSaveHotkey(event) {
                self?.editController?.saveFromKeyboard()
                return nil
            }
            if self?.editController?.handleEditorShortcutFromKeyboard(for: event) == true {
                return nil
            }
            return event
        }
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.editController?.isTextEditing == true {
                return
            }
            if event.keyCode == 53 {
                self?.cancel()
            }
        }
        rightMouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            if self?.editController?.isTextEditing == true {
                return event
            }
            self?.cancel()
            return nil
        }
        rightMouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            if self?.editController?.isTextEditing == true {
                return
            }
            self?.cancel()
        }

        if presetImage == nil, suspendedDraft == nil {
            NSCursor.crosshair.push()
            cursorWasPushed = true
        } else {
            // Skip cursor push so tearDown's pop doesn't strip an unrelated cursor.
            cursorPopped = true
            // The chip is a "drag to select" hint — irrelevant in image-edit mode.
            chipWindow?.dismiss()
            chipWindow = nil
            if suspendedDraft != nil {
                enterSuspendedSelection()
            } else {
                enterPresetSelection()
            }
        }
    }

    private func recordFirstDraw(generation: Int) {
        guard generation == presentationGeneration, !sessionEnded else { return }
        triggerContext?.mark(.firstDrawCompleted)
    }

    private func recordFirstFrame(
        generation: Int,
        displayID: CGDirectDisplayID?
    ) {
        guard generation == presentationGeneration,
              !sessionEnded,
              !firstFrameReported,
              firstFrameTargetDisplayID == nil
                || displayID == firstFrameTargetDisplayID else { return }
        firstFrameReported = true
        triggerContext?.mark(.firstFrame)
        triggerContext?.finish(.presented)
        onFirstFramePresented?()
    }

    private static func displayIDUnderPointer() -> CGDirectDisplayID? {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }

    private static var persistedSelectionAspectRatio: CGFloat? {
        guard Defaults.hasSelectionAspectRatio else { return nil }
        let ratio = Defaults.selectionAspectRatio
        guard ratio > 0, ratio.isFinite else { return nil }
        return CGFloat(ratio)
    }

    private var currentCursorChipText: String {
        if usesAspectRatioSelection {
            return Self.aspectRatioCursorChipText(
                for: postCaptureAction,
                aspectRatio: Self.persistedSelectionAspectRatio
            )
        }
        return postCaptureAction.cursorChipText
    }

    private var usesAspectRatioSelection: Bool {
        guard presetImage == nil, suspendedDraft == nil else { return false }
        switch postCaptureAction {
        case .edit, .record:
            return true
        case .textRecognition, .copyImageText, .screenshotTranslation:
            return false
        }
    }

    private static func aspectRatioCursorChipText(for action: PostCaptureAction, aspectRatio: CGFloat?) -> String {
        switch action {
        case .edit:
            guard let aspectRatio else { return L10n.dragToScreenshotAspectFree }
            return L10n.dragToScreenshotAspect(aspectRatioLabel(for: aspectRatio))
        case .record:
            guard let aspectRatio else { return L10n.dragToRecordAspectFree }
            return L10n.dragToRecordAspect(aspectRatioLabel(for: aspectRatio))
        case .textRecognition, .copyImageText, .screenshotTranslation:
            return action.cursorChipText
        }
    }

    private static func aspectRatioLabel(for aspectRatio: CGFloat) -> String {
        let presets: [(CGFloat, String)] = [
            (1.0, "1:1"),
            (2.35, "2.35:1"),
            (3.0, "3:1"),
            (3.0 / 2.0, "3:2"),
            (4.0 / 3.0, "4:3"),
            (9.0 / 16.0, "9:16"),
            (16.0 / 9.0, "16:9"),
        ]
        if let preset = presets.first(where: { abs($0.0 - aspectRatio) < 0.000_001 }) {
            return preset.1
        }
        return String(format: "%.2f:1", Double(aspectRatio))
    }

    private func cycleSelectionAspectRatioFromKeyboard(for event: NSEvent) -> Bool {
        guard usesAspectRatioSelection else { return false }
        guard editController == nil, event.keyCode == 15 else { return false }
        let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(modifierMask).isEmpty else { return false }

        let presets = Defaults.selectionAspectRatioPresets
        let currentModeIndex: Int
        if Defaults.hasSelectionAspectRatio {
            let currentRatio = CGFloat(Defaults.selectionAspectRatio)
            let presetIndex = presets.firstIndex { abs($0 - currentRatio) < 0.000_001 }
            currentModeIndex = presetIndex.map { $0 + 1 } ?? 0
        } else {
            currentModeIndex = 0
        }

        let nextModeIndex = (currentModeIndex + 1) % (presets.count + 1)
        let nextAspectRatio: CGFloat?
        if nextModeIndex == 0 {
            Defaults.clearSelectionAspectRatio()
            nextAspectRatio = nil
        } else {
            let ratio = presets[nextModeIndex - 1]
            Defaults.selectionAspectRatio = Double(ratio)
            nextAspectRatio = ratio
        }
        applySelectionAspectRatio(nextAspectRatio)
        if usesAspectRatioSelection {
            chipWindow?.updateText(Self.aspectRatioCursorChipText(for: postCaptureAction, aspectRatio: nextAspectRatio))
        }
        return true
    }

    private func applySelectionAspectRatio(_ aspectRatio: CGFloat?) {
        for case let selectionView as SelectionView in windows.compactMap(\.contentView) {
            selectionView.aspectRatio = aspectRatio
        }
        activeSelectionView?.aspectRatio = aspectRatio
    }

    /// Image-edit mode: pick the screen under the cursor, place a centered
    /// selection sized to the supplied image, lock interaction, and hand off
    /// to the editor.
    private func enterPresetSelection() {
        guard let presetImage else { return }
        let cursorPoint = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        guard let window = windows.first(where: { $0.screen == screen }),
              let selectionView = window.contentView as? SelectionView else { return }

        let displayMetrics = Self.displayMetrics(for: presetImage.size, on: screen)
        let imageSize = displayMetrics.viewportSize
        let visibleRect = Self.visibleRectInSelectionView(for: screen)
        let centeredOrigin = NSPoint(
            x: visibleRect.midX - imageSize.width / 2,
            y: visibleRect.midY - imageSize.height / 2
        )
        let viewRect = NSRect(origin: centeredOrigin, size: imageSize)

        selectionView.updateSelectionRect(viewRect)
        selectionView.selectionSizeLabelOverride = Self.scaleLabelText(
            imageSize: presetImage.size,
            displaySize: displayMetrics.canvasSize
        )
        // Lock immediately so user can't drag/resize a fixed-image canvas.
        selectionView.selectionLocked = true
        selectionView.selectionInteractionEnabled = false

        // Drive the same path as a real selection completion. The captureRect
        // is irrelevant because the editor uses overrideBaseImage, but we
        // pass a sensible value derived from the selection rect.
        selectionDidComplete(rect: viewRect, inView: selectionView, isWindowSelection: false, windowID: nil)

        // Pin a hint to the center of the loaded image: X exits editing.
        let anchorRect = convertToScreenRect(viewRect, view: selectionView)
        let hint: String
        switch presetSource {
        case .clipboard:
            hint = L10n.clipboardEditExitHint
        case .pin:
            hint = L10n.pinEditExitHint
        case .fullScreen:
            hint = L10n.fullScreenEditExitHint
        case .merge:
            hint = L10n.mergeEditExitHint
        case .finder, nil:
            hint = L10n.finderEditExitHint
        }
        ToastWindow.show(
            message: hint,
            centerAnchor: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
            duration: 3.0
        )
    }

    private func enterSuspendedSelection() {
        guard let suspendedDraft else { return }
        let screen = screenForSuspendedDraft(suspendedDraft)
        guard let window = windows.first(where: { $0.screen == screen }),
              let selectionView = window.contentView as? SelectionView
        else { return }

        for existingWindow in windows where existingWindow != window {
            existingWindow.orderOut(nil)
        }

        selectionView.updateSelectionRect(suspendedDraft.selectionViewRect)
        selectionView.selectionSizeLabelOverride = suspendedDraft.selectionSizeLabelOverride
        selectionView.selectionLocked = suspendedDraft.selectionLocked
        selectionView.selectionInteractionEnabled = suspendedDraft.selectionInteractionEnabled

        activeSelectionView = selectionView
        activeScreen = screen

        showEditor(
            captureRect: suspendedDraft.captureRect,
            screen: screen,
            selectionRect: suspendedDraft.selectionRect,
            selectionViewRect: suspendedDraft.selectionViewRect,
            hostSelectionView: selectionView,
            preSnapshot: suspendedDraft.preSnapshot,
            overrideBaseImage: suspendedDraft.overrideBaseImage,
            windowBaseImage: suspendedDraft.windowBaseImage,
            isWindowCapture: suspendedDraft.isWindowCapture
        )
        editController?.restoreState(suspendedDraft.editorState)

        let anchorRect = convertToScreenRect(suspendedDraft.selectionViewRect, view: selectionView)
        ToastWindow.show(
            message: L10n.editSuspendedResumeToast,
            centerAnchor: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
            duration: 3.0
        )
    }

    private func screenForSuspendedDraft(_ draft: SuspendedEditDraft) -> NSScreen {
        if let displayID = draft.screenDisplayID,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
           }) {
            return screen
        }
        if let screen = NSScreen.screens.first(where: { $0.frame == draft.screenFrame }) {
            return screen
        }
        return screenForMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private func screenForMouseLocation() -> NSScreen? {
        let cursorPoint = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
    }

    private static func scaleLabelText(imageSize: NSSize, displaySize: NSSize) -> String? {
        guard imageSize.width > 0, imageSize.height > 0,
              displaySize.width > 0, displaySize.height > 0
        else {
            return nil
        }
        let ratio = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let width = Int(round(imageSize.width))
        let height = Int(round(imageSize.height))
        guard ratio < 0.999 else {
            return "\(width) x \(height)"
        }
        let percent = max(1, Int(round(ratio * 100)))
        return "\(width) x \(height) (\(percent)%)"
    }

    private struct PresetDisplayMetrics {
        let viewportSize: NSSize
        let canvasSize: NSSize
    }

    private static func displayMetrics(for imageSize: NSSize, on screen: NSScreen) -> PresetDisplayMetrics {
        let frame = screen.visibleFrame
        let maxWidthFraction: CGFloat = 0.70
        let verticalMargin: CGFloat = 120 // leave room for toolbar above/below

        guard imageSize.width > 0, imageSize.height > 0 else {
            return PresetDisplayMetrics(viewportSize: imageSize, canvasSize: imageSize)
        }
        let maxWidth = max(1, floor(frame.width * maxWidthFraction))
        let maxViewportHeight = max(1, floor(frame.height - verticalMargin))
        let ratio = min(1.0, maxWidth / imageSize.width)
        let canvasSize = NSSize(
            width: max(1, floor(imageSize.width * ratio)),
            height: max(1, floor(imageSize.height * ratio))
        )
        let viewportSize = NSSize(
            width: canvasSize.width,
            height: min(canvasSize.height, maxViewportHeight)
        )
        return PresetDisplayMetrics(viewportSize: viewportSize, canvasSize: canvasSize)
    }

    private static func visibleRectInSelectionView(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.minX - screenFrame.minX,
            y: visible.minY - screenFrame.minY,
            width: visible.width,
            height: visible.height
        )
    }

    func cancel() {
        guard !sessionEnded else { return }
        triggerContext?.finish(.cancelled)
        editController?.tearDown()
        editController = nil
        tearDown()
        onComplete(nil)
        onRequestFocusReturn?()
    }

    private func suspendCurrentEditFromMask() {
        guard let draft = makeSuspendedEditDraft() else { return }
        editController?.tearDown()
        editController = nil
        tearDown()
        onRequestFocusReturn?()
        onSuspend?(draft)
    }

    private func makeSuspendedEditDraft() -> SuspendedEditDraft? {
        guard let editController,
              !editController.blocksHistoryNavigation,
              let context = activeEditorContext,
              let editorState = editController.restorableState()
        else { return nil }

        let selectionViewState = context.hostSelectionView.map { SelectionViewState(selectionView: $0) }
            ?? context.selectionViewState
        let displayID = context.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return SuspendedEditDraft(
            captureRect: context.captureRect,
            screenDisplayID: displayID,
            screenFrame: context.screen.frame,
            selectionRect: context.selectionRect,
            selectionViewRect: context.selectionViewRect,
            selectionSizeLabelOverride: selectionViewState.selectionSizeLabelOverride,
            selectionLocked: selectionViewState.selectionLocked,
            selectionInteractionEnabled: selectionViewState.selectionInteractionEnabled,
            preSnapshot: context.preSnapshot,
            overrideBaseImage: context.overrideBaseImage,
            windowBaseImage: context.windowBaseImage,
            isWindowCapture: editController.isWindowCapture,
            editorState: editorState,
            keepsEditorAcrossSpaces: keepsEditorAcrossSpaces
        )
    }

    private var cursorPopped = false
    private var cursorWasPushed = false

    private func tearDown() {
        guard !sessionEnded else { return }
        sessionEnded = true
        presentationGeneration += 1
        snapshotCancellation?()
        snapshotCancellation = nil
        windowCaptureTask?.cancel()
        windowCaptureTask = nil
        pendingWindowCapture = nil
        pendingSelection = nil
        ToastWindow.dismiss()

        if cursorWasPushed, !cursorPopped {
            NSCursor.pop()
            cursorPopped = true
        }
        cursorWasPushed = false

        chipWindow?.dismiss()
        chipWindow = nil

        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m); escGlobalMonitor = nil }
        if let m = rightMouseLocalMonitor { NSEvent.removeMonitor(m); rightMouseLocalMonitor = nil }
        if let m = rightMouseGlobalMonitor { NSEvent.removeMonitor(m); rightMouseGlobalMonitor = nil }

        for window in windows {
            (window.contentView as? SelectionView)?.cancelFirstFramePresentationTracking()
            OverlayPanelPool.shared.recycle(window)
        }
        windows.removeAll()
        screenSnapshots.removeAll()
        selectionViewsByDisplayID.removeAll()
        expectedSnapshotDisplayIDs.removeAll()
        failedSnapshotDisplayIDs.removeAll()
        snapshotCaptureFinished = false
        firstFrameTargetDisplayID = nil
        activeSelectionView = nil
        activeScreen = nil
        activeEditorContext = nil
        currentEditHistoryDraft = nil
        historyEditorDrafts.removeAll()
        historyEntries.removeAll()
        historyEntryIndex = nil
    }

    // MARK: - Coordinate Conversion

    private func convertToScreenRect(_ viewRect: NSRect, view: NSView) -> NSRect {
        guard let window = view.window else { return viewRect }
        return window.convertToScreen(view.convert(viewRect, to: nil))
    }

    private func convertToCGRect(_ screenRect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        return CGRect(
            x: screenRect.origin.x,
            y: primaryHeight - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }
}

// MARK: - SelectionViewDelegate

extension OverlayWindowController: SelectionViewDelegate {
    func selectionDidStart() {
        chipWindow?.dismiss()
        chipWindow = nil
    }

    func selectionMaskDidDoubleClick(inView view: NSView) {
        suspendCurrentEditFromMask()
    }

    func selectionDidDoubleClickInsideSelection(inView view: NSView) {
        confirmFromKeyboard()
    }

    func selectionDidComplete(rect: NSRect, inView view: NSView, isWindowSelection: Bool, windowID: CGWindowID?) {
        guard let window = view.window, let screen = window.screen else {
            cancel()
            return
        }

        guard let selectionView = view as? SelectionView else {
            cancel()
            return
        }
        activeSelectionView = selectionView
        activeScreen = screen

        let screenRect = convertToScreenRect(rect, view: view)
        let cgRect = convertToCGRect(screenRect)

        if editController != nil {
            // Selection was adjusted — it no longer matches the clicked
            // window's bounds, so window-only effects no longer apply.
            historyEntryIndex = nil
            currentEditHistoryDraft = nil
            historyEditorDrafts.removeAll()
            editController?.isWindowCapture = false
            editController?.updateLayout(
                selectionRect: screenRect,
                selectionViewRect: rect,
                captureRect: cgRect
            )
            return
        }

        guard !sessionEnded else { return }
        lockSelectionForCompletion(activeWindow: window)

        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            finishSelectionCaptureFailure()
            return
        }

        let request = PendingSelection(
            rect: rect,
            screenRect: screenRect,
            captureRect: cgRect,
            screen: screen,
            selectionView: selectionView,
            displayID: displayID,
            isWindowSelection: isWindowSelection,
            windowID: windowID
        )

        guard shouldCaptureSnapshots else {
            completeInitialSelection(request, preSnapshot: nil)
            return
        }
        if let snapshot = screenSnapshots[displayID] {
            completeInitialSelection(request, preSnapshot: snapshot)
            return
        }
        guard expectedSnapshotDisplayIDs.contains(displayID),
              !failedSnapshotDisplayIDs.contains(displayID),
              !snapshotCaptureFinished else {
            finishSelectionCaptureFailure()
            return
        }

        selectionView.selectionInteractionEnabled = false
        pendingSelection = request
    }

    private func lockSelectionForCompletion(activeWindow: NSWindow) {
        for case let selectionView as SelectionView in windows.compactMap(\.contentView) {
            selectionView.selectionLocked = true
        }
        for existingWindow in windows where existingWindow != activeWindow {
            existingWindow.orderOut(nil)
        }
        if cursorWasPushed, !cursorPopped {
            NSCursor.pop()
            cursorPopped = true
        }
    }

    private func resumePendingSelectionIfReady(displayID: CGDirectDisplayID) {
        guard let request = pendingSelection,
              request.displayID == displayID,
              let snapshot = screenSnapshots[displayID] else { return }
        pendingSelection = nil
        request.selectionView.selectionInteractionEnabled = true
        completeInitialSelection(request, preSnapshot: snapshot)
    }

    private func completeInitialSelection(
        _ request: PendingSelection,
        preSnapshot: CGImage?
    ) {
        guard !sessionEnded else { return }
        if let windowID = directWindowCaptureID(for: request, preSnapshot: preSnapshot) {
            startWindowCapture(
                windowID: windowID,
                request: request,
                preSnapshot: preSnapshot
            )
            return
        }
        finishInitialSelection(request, preSnapshot: preSnapshot, directWindowImage: nil)
    }

    private func directWindowCaptureID(
        for request: PendingSelection,
        preSnapshot: CGImage?
    ) -> CGWindowID? {
        guard request.isWindowSelection, let windowID = request.windowID else { return nil }
        if preSnapshot != nil,
           windowDetector.usesCompositedScreenBackdrop(forWindowID: windowID) {
            return nil
        }
        return windowID
    }

    private func startWindowCapture(
        windowID: CGWindowID,
        request: PendingSelection,
        preSnapshot: CGImage?
    ) {
        request.selectionView.selectionInteractionEnabled = false
        let generation = presentationGeneration
        let captureID = UUID()
        let pointSize = request.rect.size
        let windowImageLoader = windowImageLoader
        pendingWindowCapture = PendingWindowCapture(
            id: captureID,
            generation: generation,
            request: request,
            preSnapshot: preSnapshot
        )
        windowCaptureTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<NSImage?, Error>
            do {
                result = .success(try await windowImageLoader(windowID, pointSize))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            MainRunLoopScheduler.perform {
                self?.finishWindowCapture(
                    result,
                    captureID: captureID,
                    generation: generation
                )
            }
        }
    }

    private func finishWindowCapture(
        _ result: Result<NSImage?, Error>,
        captureID: UUID,
        generation: Int
    ) {
        guard generation == presentationGeneration,
              !sessionEnded,
              let pendingWindowCapture,
              pendingWindowCapture.id == captureID,
              pendingWindowCapture.generation == generation else { return }
        windowCaptureTask = nil
        self.pendingWindowCapture = nil
        let request = pendingWindowCapture.request
        let preSnapshot = pendingWindowCapture.preSnapshot
        request.selectionView.selectionInteractionEnabled = true

        switch result {
        case .success(let image):
            finishInitialSelection(
                request,
                preSnapshot: preSnapshot,
                directWindowImage: image
            )
        case .failure(let error):
            logPreparationFailure("window-snapshot-\(request.windowID ?? 0)", error: error)
            finishInitialSelection(
                request,
                preSnapshot: preSnapshot,
                directWindowImage: nil
            )
        }
    }

    private func finishInitialSelection(
        _ request: PendingSelection,
        preSnapshot: CGImage?,
        directWindowImage: NSImage?
    ) {
        let windowBaseImage = imageForWindowSelection(
            isWindowSelection: request.isWindowSelection,
            captureRect: request.captureRect,
            screen: request.screen,
            preSnapshot: preSnapshot,
            directWindowImage: directWindowImage
        )
        let shouldApplyWindowEffects = request.isWindowSelection && windowBaseImage != nil

        switch postCaptureAction {
        case .edit:
            showEditor(
                captureRect: request.captureRect,
                screen: request.screen,
                selectionRect: request.screenRect,
                selectionViewRect: request.rect,
                hostSelectionView: request.selectionView,
                preSnapshot: preSnapshot,
                overrideBaseImage: presetImage,
                windowBaseImage: windowBaseImage,
                isWindowCapture: shouldApplyWindowEffects
            )
        case .textRecognition, .copyImageText, .screenshotTranslation:
            completeImmediateAction(request, preSnapshot: preSnapshot, windowBaseImage: windowBaseImage)
        case .record:
            tearDown()
            onComplete(nil)
            onRecordingSelection?(request.screenRect, request.screen)
        }
    }

    private func completeImmediateAction(
        _ request: PendingSelection,
        preSnapshot: CGImage?,
        windowBaseImage: NSImage?
    ) {
        let baseImage = imageForImmediateAction(
            captureRect: request.captureRect,
            screen: request.screen,
            preSnapshot: preSnapshot,
            windowBaseImage: windowBaseImage
        )
        tearDown()
        onComplete(nil)
        guard let baseImage else {
            ToastWindow.show(message: L10n.fullScreenScreenshotFailed)
            return
        }

        switch postCaptureAction {
        case .textRecognition:
            OCRTranslatePanel.presentTextRecognition(
                image: baseImage,
                anchorRect: request.screenRect,
                screen: request.screen
            )
        case .copyImageText:
            copyRecognizedTextToClipboard(
                from: baseImage,
                screen: request.screen,
                anchorRect: request.screenRect
            )
        case .screenshotTranslation:
            OCRTranslatePanel.presentScreenshotTranslation(
                image: baseImage,
                anchorRect: request.screenRect,
                screen: request.screen
            )
        case .edit, .record:
            break
        }
    }

    private func finishSelectionCaptureFailure() {
        guard !sessionEnded else { return }
        triggerContext?.finish(.failed)
        tearDown()
        onComplete(nil)
        onRequestFocusReturn?()
        ToastWindow.show(message: L10n.fullScreenScreenshotFailed)
    }

    private func showEditor(
        captureRect: CGRect,
        screen: NSScreen,
        selectionRect: NSRect,
        selectionViewRect: NSRect,
        hostSelectionView: SelectionView,
        preSnapshot: CGImage?,
        overrideBaseImage: NSImage?,
        windowBaseImage: NSImage?,
        isWindowCapture: Bool
    ) {
        activeEditorContext = ActiveEditorContext(
            captureRect: captureRect,
            screen: screen,
            selectionRect: selectionRect,
            selectionViewRect: selectionViewRect,
            hostSelectionView: hostSelectionView,
            selectionViewState: SelectionViewState(selectionView: hostSelectionView),
            preSnapshot: preSnapshot,
            overrideBaseImage: overrideBaseImage,
            windowBaseImage: windowBaseImage,
            isWindowCapture: isWindowCapture
        )
        editController = EditWindowController(
            captureRect: captureRect,
            screen: screen,
            selectionRect: selectionRect,
            selectionViewRect: selectionViewRect,
            hostSelectionView: hostSelectionView,
            preSnapshot: preSnapshot,
            overrideBaseImage: overrideBaseImage,
            windowBaseImage: windowBaseImage,
            isWindowCapture: isWindowCapture,
            onRecordingSelection: onRecordingSelection,
            onRequestFocusReturn: onRequestFocusReturn,
            keepsHostWindowAcrossSpaces: keepsEditorAcrossSpaces
        ) { [weak self] finalImage in
            self?.tearDown()
            self?.onComplete(finalImage)
        }
        editController?.show()
    }

    private func switchHistoryImageFromKeyboard(for event: NSEvent) -> Bool {
        guard postCaptureAction == .edit,
              let editController,
              !editController.blocksHistoryNavigation
        else {
            return false
        }
        if HotkeyManager.eventMatchesPreviousHistoryImageHotkey(event) {
            return switchHistoryImage(offset: 1)
        }
        if HotkeyManager.eventMatchesNextHistoryImageHotkey(event) {
            return switchHistoryImage(offset: -1)
        }
        return false
    }

    private func switchHistoryImage(offset: Int) -> Bool {
        refreshHistoryEntriesIfNeeded()
        guard !historyEntries.isEmpty else { return false }

        if historyEntryIndex == nil {
            guard offset > 0 else { return true }
            captureCurrentEditHistoryDraftIfNeeded()
        } else if historyEntryIndex == currentEditDraftIndex {
            currentEditHistoryDraft?.editorState = editController?.restorableState()
        } else {
            captureCurrentHistoryEditorDraftIfNeeded()
        }

        var nextIndex: Int
        if let currentIndex = historyEntryIndex {
            nextIndex = currentIndex + offset
        } else {
            guard offset > 0 else { return true }
            nextIndex = 0
        }
        let minimumIndex = currentEditHistoryDraft == nil ? 0 : -1
        guard nextIndex >= minimumIndex, nextIndex < historyEntries.count else { return true }

        if nextIndex == currentEditDraftIndex {
            return restoreCurrentEditHistoryDraft(at: nextIndex)
        }

        var image: NSImage?
        while nextIndex >= 0, nextIndex < historyEntries.count {
            image = HistoryManager.shared.image(for: historyEntries[nextIndex])
            if image != nil {
                break
            }
            nextIndex += offset
        }
        if nextIndex == currentEditDraftIndex {
            return restoreCurrentEditHistoryDraft(at: nextIndex)
        }
        guard let image else {
            return true
        }
        guard let screen = activeScreen ?? NSScreen.screens.first,
              let window = windows.first(where: { $0.screen == screen }),
              let selectionView = window.contentView as? SelectionView
        else { return false }

        editController?.tearDown()
        editController = nil

        let displayMetrics = Self.displayMetrics(for: image.size, on: screen)
        let visibleRect = Self.visibleRectInSelectionView(for: screen)
        let viewRect = NSRect(
            x: visibleRect.midX - displayMetrics.viewportSize.width / 2,
            y: visibleRect.midY - displayMetrics.viewportSize.height / 2,
            width: displayMetrics.viewportSize.width,
            height: displayMetrics.viewportSize.height
        )
        let screenRect = convertToScreenRect(viewRect, view: selectionView)
        let cgRect = convertToCGRect(screenRect)

        selectionView.updateSelectionRect(viewRect)
        selectionView.selectionSizeLabelOverride = Self.scaleLabelText(
            imageSize: image.size,
            displaySize: displayMetrics.canvasSize
        )
        selectionView.selectionLocked = true
        selectionView.selectionInteractionEnabled = false

        activeSelectionView = selectionView
        activeScreen = screen
        historyEntryIndex = nextIndex
        let historyDraft = historyEditorDrafts[historyEntries[nextIndex].fileURL]

        showEditor(
            captureRect: cgRect,
            screen: screen,
            selectionRect: screenRect,
            selectionViewRect: viewRect,
            hostSelectionView: selectionView,
            preSnapshot: nil,
            overrideBaseImage: image,
            windowBaseImage: nil,
            isWindowCapture: false
        )
        if let historyDraft {
            editController?.restoreState(historyDraft)
        }
        return true
    }

    private var currentEditDraftIndex: Int? {
        currentEditHistoryDraft == nil ? nil : -1
    }

    private func captureCurrentEditHistoryDraftIfNeeded() {
        guard currentEditHistoryDraft == nil,
              let editController,
              let context = activeEditorContext,
              let activeSelectionView = context.hostSelectionView
        else { return }

        currentEditHistoryDraft = CurrentEditHistoryDraft(
            captureRect: context.captureRect,
            screen: context.screen,
            selectionRect: context.selectionRect,
            selectionViewRect: context.selectionViewRect,
            hostSelectionView: activeSelectionView,
            selectionViewState: SelectionViewState(selectionView: activeSelectionView),
            preSnapshot: context.preSnapshot,
            overrideBaseImage: context.overrideBaseImage,
            windowBaseImage: context.windowBaseImage,
            isWindowCapture: editController.isWindowCapture,
            editorState: editController.restorableState()
        )
    }

    private func captureCurrentHistoryEditorDraftIfNeeded() {
        guard let historyEntryIndex,
              historyEntryIndex >= 0,
              historyEntryIndex < historyEntries.count,
              let editorState = editController?.restorableState()
        else { return }

        historyEditorDrafts[historyEntries[historyEntryIndex].fileURL] = editorState
    }

    private func restoreCurrentEditHistoryDraft(at index: Int) -> Bool {
        guard let draft = currentEditHistoryDraft,
              let selectionView = draft.hostSelectionView
        else { return true }

        editController?.tearDown()
        editController = nil

        selectionView.updateSelectionRect(draft.selectionViewRect)
        draft.selectionViewState.apply(to: selectionView)

        activeSelectionView = selectionView
        activeScreen = draft.screen
        historyEntryIndex = index

        showEditor(
            captureRect: draft.captureRect,
            screen: draft.screen,
            selectionRect: draft.selectionRect,
            selectionViewRect: draft.selectionViewRect,
            hostSelectionView: selectionView,
            preSnapshot: draft.preSnapshot,
            overrideBaseImage: draft.overrideBaseImage,
            windowBaseImage: draft.windowBaseImage,
            isWindowCapture: draft.isWindowCapture
        )
        if let editorState = draft.editorState {
            editController?.restoreState(editorState)
        }
        return true
    }

    private func refreshHistoryEntriesIfNeeded() {
        guard historyEntries.isEmpty else { return }
        historyEntries = HistoryManager.shared.imageEntries()
    }

    func selectionDidChange(rect: NSRect, inView view: NSView) {
        guard let _ = view.window else { return }
        // A resize/move drag changes the rect away from the clicked window.
        historyEntryIndex = nil
        currentEditHistoryDraft = nil
        historyEditorDrafts.removeAll()
        editController?.isWindowCapture = false
        let screenRect = convertToScreenRect(rect, view: view)
        let cgRect = convertToCGRect(screenRect)
        if let context = activeEditorContext {
            activeEditorContext = ActiveEditorContext(
                captureRect: cgRect,
                screen: context.screen,
                selectionRect: screenRect,
                selectionViewRect: rect,
                hostSelectionView: context.hostSelectionView,
                selectionViewState: SelectionViewState(
                    selectionSizeLabelOverride: nil,
                    selectionLocked: false,
                    selectionInteractionEnabled: true
                ),
                preSnapshot: context.preSnapshot,
                overrideBaseImage: context.overrideBaseImage,
                windowBaseImage: nil,
                isWindowCapture: false
            )
        }
        editController?.updateLayout(
            selectionRect: screenRect,
            selectionViewRect: rect,
            captureRect: cgRect
        )
    }

    private func imageForImmediateAction(
        captureRect: CGRect,
        screen: NSScreen,
        preSnapshot: CGImage?,
        windowBaseImage: NSImage?
    ) -> NSImage? {
        if let windowBaseImage {
            return windowBaseImage
        }
        if let preSnapshot {
            return ScreenCapturer.crop(from: preSnapshot, captureRect: captureRect, screen: screen)
        }
        return nil
    }

    private func copyRecognizedTextToClipboard(from image: NSImage, screen: NSScreen, anchorRect: NSRect) {
        let centerAnchor = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        ToastWindow.show(
            message: L10n.copyImageTextCopying,
            on: screen,
            centerAnchor: centerAnchor,
            duration: 60
        )

        Task { @MainActor in
            let text = await OCRService.recognize(image: image)
            if text.isEmpty {
                ToastWindow.show(
                    message: L10n.copyImageTextNoText,
                    on: screen,
                    centerAnchor: centerAnchor,
                    duration: 1.5
                )
            } else {
                ClipboardManager.copyToClipboard(text: text)
                ToastWindow.show(
                    message: L10n.copyImageTextCopied,
                    on: screen,
                    centerAnchor: centerAnchor,
                    duration: 1.5
                )
            }
        }
    }

    private func imageForWindowSelection(
        isWindowSelection: Bool,
        captureRect: CGRect,
        screen: NSScreen,
        preSnapshot: CGImage?,
        directWindowImage: NSImage?
    ) -> NSImage? {
        guard isWindowSelection else { return nil }
        let usableDirectImage = directWindowImage.flatMap { image in
            ScreenCapturer.isEffectivelyTransparent(image) ? nil : image
        }

        if let snapshotWindowImage = preSnapshotImage(
            captureRect: captureRect,
            screen: screen,
            preSnapshot: preSnapshot
        ) {
            if let usableDirectImage {
                let maskedImage = WindowEffects.applyingAlphaMask(from: usableDirectImage, to: snapshotWindowImage)
                if let maskedImage {
                    return maskedImage
                }
            }
            return WindowEffects.roundedCorners(snapshotWindowImage)
        }

        return usableDirectImage
    }

    private func preSnapshotImage(
        captureRect: CGRect,
        screen: NSScreen,
        preSnapshot: CGImage?
    ) -> NSImage? {
        guard let preSnapshot,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return nil
        }

        // A pre-overlay screen snapshot can only supply pixels that were
        // visible on this display. For partially off-screen windows, keep the
        // direct window capture path so the full window content and size survive.
        guard CGDisplayBounds(displayID).contains(captureRect) else {
            return nil
        }

        return ScreenCapturer.crop(from: preSnapshot, captureRect: captureRect, screen: screen)
    }
}
