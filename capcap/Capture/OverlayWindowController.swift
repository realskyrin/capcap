import AppKit
import QuartzCore

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
    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]
    private let onComplete: (NSImage?) -> Void
    private let onRequestFocusReturn: (() -> Void)?
    private let onRecordingSelection: ((NSRect, NSScreen) -> Void)?
    private let postCaptureAction: PostCaptureAction

    /// Image-edit mode: when set, `activate()` skips the user's drag-to-select
    /// step and immediately opens the editor on the supplied image, sized to
    /// fit the screen with margins.
    private let presetImage: NSImage?
    /// In image-edit mode, where `presetImage` came from. nil otherwise.
    private let presetSource: PresetSource?
    private let keepsEditorAcrossSpaces: Bool
    private var presentationScheduled = false

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

    /// Route the default copy-to-clipboard hotkey (double-tap ⌘) into the
    /// editor while the overlay is active. No-op when the editor isn't up yet.
    func confirmFromKeyboard() {
        editController?.confirmFromKeyboard()
    }

    init(
        postCaptureAction: PostCaptureAction = .edit,
        onRecordingSelection: ((NSRect, NSScreen) -> Void)? = nil,
        onRequestFocusReturn: (() -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.presetImage = nil
        self.presetSource = nil
        self.keepsEditorAcrossSpaces = false
        self.postCaptureAction = postCaptureAction
        self.onRecordingSelection = onRecordingSelection
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onComplete = onComplete
    }

    init(
        presetImage: NSImage,
        presetSource: PresetSource,
        keepsEditorAcrossSpaces: Bool = false,
        onRequestFocusReturn: (() -> Void)? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.presetImage = presetImage
        self.presetSource = presetSource
        self.keepsEditorAcrossSpaces = keepsEditorAcrossSpaces
        self.postCaptureAction = .edit
        self.onRecordingSelection = nil
        self.onRequestFocusReturn = onRequestFocusReturn
        self.onComplete = onComplete
    }

    func activate() {
        guard !presentationScheduled else { return }
        presentationScheduled = true

        prepareScreenContext()

        if Self.isRunningEventTrackingMode {
            Self.dismissActiveEventTrackingSurface()
            MainRunLoopScheduler.performInDefaultMode { [weak self] in
                self?.presentOverlay()
            }
        } else {
            presentOverlay()
        }
    }

    private func prepareScreenContext() {
        // Snapshot visible windows before our overlays appear
        windowDetector.refresh()

        // Pre-capture all screen content before overlay panels appear,
        // so transient menus and popups are preserved in the snapshot.
        // Use CGWindowListCreateImage with .bestResolution so the image
        // matches the display's effective resolution (not the native panel
        // resolution), avoiding a visible scale shift on scaled displays.
        screenSnapshots.removeAll()
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                let displayBounds = CGDisplayBounds(displayID)
                if let image = CGWindowListCreateImage(
                    displayBounds,
                    .optionOnScreenOnly,
                    kCGNullWindowID,
                    .bestResolution
                ) {
                    screenSnapshots[displayID] = image
                }
            }
        }
    }

    private func presentOverlay() {
        guard windows.isEmpty else { return }
        // Create all overlay windows and pre-render their content before
        // showing any of them, so there is no visible flash or zoom.
        for screen in NSScreen.screens {
            let window = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
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
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               let snapshot = screenSnapshots[displayID] {
                selectionView.backgroundSnapshot = NSImage(cgImage: snapshot, size: screen.frame.size)
            }
            window.contentView = selectionView

            // Pre-render the snapshot into the backing store before the window
            // becomes visible, so the first on-screen frame already has content.
            selectionView.display()

            windows.append(window)
        }

        // Show all overlay windows in one batch with animations disabled.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in windows {
            window.orderFront(nil)
        }
        windows.first?.makeKey()
        CATransaction.commit()

        if presetImage == nil {
            for case let selectionView as SelectionView in windows.compactMap(\.contentView) {
                selectionView.refreshHoverAtCurrentMouseLocation()
            }
        }

        chipWindow = CursorChipWindow(text: postCaptureAction.cursorChipText)
        chipWindow?.show()

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.editController?.isTextEditing == true {
                return event
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

        if presetImage == nil {
            NSCursor.crosshair.push()
        } else {
            // Skip cursor push so tearDown's pop doesn't strip an unrelated cursor.
            cursorPopped = true
            // The chip is a "drag to select" hint — irrelevant in image-edit mode.
            chipWindow?.dismiss()
            chipWindow = nil
            enterPresetSelection()
        }
    }

    private static var isRunningEventTrackingMode: Bool {
        guard let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) else {
            return false
        }
        return mode.rawValue as String == RunLoop.Mode.eventTracking.rawValue
    }

    private static func dismissActiveEventTrackingSurface() {
        NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
        keyDown?.flags = []
        keyUp?.flags = []
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
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
        editController?.tearDown()
        editController = nil
        tearDown()
        onComplete(nil)
        onRequestFocusReturn?()
    }

    private var cursorPopped = false

    private func tearDown() {
        ToastWindow.dismiss()

        if !cursorPopped {
            NSCursor.pop()
            cursorPopped = true
        }

        chipWindow?.dismiss()
        chipWindow = nil

        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m); escGlobalMonitor = nil }
        if let m = rightMouseLocalMonitor { NSEvent.removeMonitor(m); rightMouseLocalMonitor = nil }
        if let m = rightMouseGlobalMonitor { NSEvent.removeMonitor(m); rightMouseGlobalMonitor = nil }

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        screenSnapshots.removeAll()
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

        if editController == nil {
            // Lock selection so clicking outside won't reset it
            for case let selectionView as SelectionView in windows.compactMap(\.contentView) {
                selectionView.selectionLocked = true
            }

            // Keep only the active screen overlay alive for editing. Other
            // screens can stop intercepting input once the region is chosen.
            for existingWindow in windows where existingWindow != window {
                existingWindow.orderOut(nil)
            }

            // Pop the crosshair cursor pushed during activate(). In image-edit
            // (preset) mode we never pushed one, so the flag handles that.
            if !cursorPopped {
                NSCursor.pop()
                cursorPopped = true
            }

            // First time selection complete — show editor
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let preSnapshot = displayID.flatMap { screenSnapshots[$0] }
            let windowBaseImage = imageForWindowSelection(
                isWindowSelection: isWindowSelection,
                windowID: windowID,
                pointSize: rect.size,
                captureRect: cgRect,
                screen: screen,
                preSnapshot: preSnapshot
            )
            let shouldApplyWindowEffects = isWindowSelection && windowBaseImage != nil

            switch postCaptureAction {
            case .edit:
                break
            case .textRecognition, .copyImageText, .screenshotTranslation:
                let baseImage = imageForImmediateAction(
                    captureRect: cgRect,
                    screen: screen,
                    preSnapshot: preSnapshot,
                    windowBaseImage: windowBaseImage
                )
                tearDown()
                onComplete(nil)
                guard let baseImage else { return }
                switch postCaptureAction {
                case .edit:
                    break
                case .textRecognition:
                    OCRTranslatePanel.presentTextRecognition(
                        image: baseImage, anchorRect: screenRect, screen: screen
                    )
                case .copyImageText:
                    copyRecognizedTextToClipboard(
                        from: baseImage,
                        screen: screen,
                        anchorRect: screenRect
                    )
                case .screenshotTranslation:
                    OCRTranslatePanel.presentScreenshotTranslation(
                        image: baseImage, anchorRect: screenRect, screen: screen
                    )
                case .record:
                    break
                }
                return
            case .record:
                tearDown()
                onComplete(nil)
                onRecordingSelection?(screenRect, screen)
                return
            }

            showEditor(
                captureRect: cgRect,
                screen: screen,
                selectionRect: screenRect,
                selectionViewRect: rect,
                hostSelectionView: selectionView,
                preSnapshot: preSnapshot,
                overrideBaseImage: presetImage,
                windowBaseImage: windowBaseImage,
                isWindowCapture: shouldApplyWindowEffects
            )
        } else {
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
        }
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
        let overlayWindowIDs = windows.map { CGWindowID($0.windowNumber) }
        return ScreenCapturer.capture(
            rect: captureRect,
            screen: screen,
            excludingWindowNumbers: overlayWindowIDs
        )
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
        windowID: CGWindowID?,
        pointSize: NSSize,
        captureRect: CGRect,
        screen: NSScreen,
        preSnapshot: CGImage?
    ) -> NSImage? {
        guard isWindowSelection else { return nil }

        // High-layer system surfaces such as menus and popups are often only
        // translucent foreground windows. Keep those on the composited screen
        // backdrop path when a pre-overlay snapshot is available.
        if preSnapshot != nil,
           windowID.map({ windowDetector.usesCompositedScreenBackdrop(forWindowID: $0) }) == true {
            return nil
        }

        let directWindowImage = windowID
            .flatMap { ScreenCapturer.capture(windowID: $0, pointSize: pointSize) }
            .flatMap { image in
                ScreenCapturer.isEffectivelyTransparent(image) ? nil : image
            }

        if let snapshotWindowImage = preSnapshotImage(
            captureRect: captureRect,
            screen: screen,
            preSnapshot: preSnapshot
        ) {
            if let directWindowImage,
               let maskedImage = WindowEffects.applyingAlphaMask(from: directWindowImage, to: snapshotWindowImage) {
                return maskedImage
            }
            return WindowEffects.roundedCorners(snapshotWindowImage)
        }

        return directWindowImage
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

// MARK: - Non-activating Overlay Panel

/// A borderless panel that becomes key without activating the app,
/// so other apps' transient popups (menus, download panels, etc.) stay visible.
private class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
