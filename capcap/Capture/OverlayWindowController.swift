import AppKit
import QuartzCore

struct CaptureResult {
    let rect: CGRect       // In CG coordinates (top-left origin) for capture
    let screen: NSScreen   // The screen where selection was made
    let screenRect: NSRect // In AppKit coordinates for editor positioning
}

class OverlayWindowController {
    /// Where a preset image came from — drives the X-key bail-out behavior.
    enum PresetSource {
        case finder
        case clipboard
    }

    private var windows: [NSWindow] = []
    private var chipWindow: CursorChipWindow?
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    private var editController: EditWindowController?
    private var activeSelectionView: SelectionView?
    private let windowDetector = WindowDetector()
    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]
    private let onComplete: (NSImage?) -> Void

    /// Image-edit mode only: called when the user presses X to abandon the
    /// preset editor and start the normal drag-to-select screenshot flow.
    private let onSwitchToCapture: (() -> Void)?

    /// Image-edit mode: when set, `activate()` skips the user's drag-to-select
    /// step and immediately opens the editor on the supplied image, sized to
    /// fit the screen with margins.
    private let presetImage: NSImage?
    /// In image-edit mode, where `presetImage` came from. nil otherwise.
    private let presetSource: PresetSource?

    init(onComplete: @escaping (NSImage?) -> Void) {
        self.presetImage = nil
        self.presetSource = nil
        self.onSwitchToCapture = nil
        self.onComplete = onComplete
    }

    init(
        presetImage: NSImage,
        presetSource: PresetSource,
        onComplete: @escaping (NSImage?) -> Void,
        onSwitchToCapture: @escaping () -> Void
    ) {
        self.presetImage = presetImage
        self.presetSource = presetSource
        self.onSwitchToCapture = onSwitchToCapture
        self.onComplete = onComplete
    }

    func activate() {
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

        chipWindow = CursorChipWindow()
        chipWindow?.show()

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.editController?.isTextEditing == true {
                return event
            }
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            if event.keyCode == 36 { // Enter — confirm screenshot
                self?.editController?.confirmFromKeyboard()
                return nil
            }
            // Image-edit mode only: X bails out of an editor that opened by
            // mistake. Clear the source it came from — the stale Finder
            // selection or the clipboard image — so it isn't re-opened, then
            // switch straight into the normal drag-to-select screenshot flow.
            if let source = self?.presetSource, event.keyCode == 7 {
                switch source {
                case .finder:
                    FinderSelection.clearSelection()
                case .clipboard:
                    ClipboardImageSource.clear()
                }
                self?.switchToCaptureMode()
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

        let imageSize = presetImage.size
        let viewBounds = selectionView.bounds
        let centeredOrigin = NSPoint(
            x: (viewBounds.width - imageSize.width) / 2,
            y: (viewBounds.height - imageSize.height) / 2
        )
        let viewRect = NSRect(origin: centeredOrigin, size: imageSize)

        selectionView.updateSelectionRect(viewRect)
        // Lock immediately so user can't drag/resize a fixed-image canvas.
        selectionView.selectionLocked = true
        selectionView.selectionInteractionEnabled = false

        // Drive the same path as a real selection completion. The captureRect
        // is irrelevant because the editor uses overrideBaseImage, but we
        // pass a sensible value derived from the selection rect.
        selectionDidComplete(rect: viewRect, inView: selectionView)

        // Pin a hint to the top-center of the loaded image: if this editor
        // opened by mistake, X bails out of it.
        let anchorRect = convertToScreenRect(viewRect, view: selectionView)
        let hint = presetSource == .clipboard
            ? L10n.clipboardEditSwitchHint
            : L10n.finderEditSwitchHint
        ToastWindow.show(
            message: hint,
            topAnchor: NSPoint(x: anchorRect.midX, y: anchorRect.maxY),
            duration: 3.0
        )
    }

    func cancel() {
        editController?.tearDown()
        editController = nil
        tearDown()
        onComplete(nil)
    }

    /// Image-edit mode: tear down the preset editor and overlays, then hand
    /// back to the caller so it can start a fresh normal screenshot capture.
    private func switchToCaptureMode() {
        editController?.tearDown()
        editController = nil
        tearDown() // also dismisses the "press X" hint toast

        // Hand off on the next runloop turn: `tearDown()` orders the hint
        // toast out, but the window server hasn't recomposited the screen
        // yet. Starting capture synchronously would snapshot the display
        // with the toast still on it, baking it into the screenshot.
        let switchHandler = onSwitchToCapture
        DispatchQueue.main.async {
            switchHandler?()
        }
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

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        screenSnapshots.removeAll()
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

    func selectionDidComplete(rect: NSRect, inView view: NSView) {
        guard let window = view.window, let screen = window.screen else {
            cancel()
            return
        }

        guard let selectionView = view as? SelectionView else {
            cancel()
            return
        }
        activeSelectionView = selectionView

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

            editController = EditWindowController(
                captureRect: cgRect,
                screen: screen,
                selectionRect: screenRect,
                selectionViewRect: rect,
                hostSelectionView: selectionView,
                preSnapshot: preSnapshot,
                overrideBaseImage: presetImage
            ) { [weak self] finalImage in
                self?.tearDown()
                self?.onComplete(finalImage)
            }
            editController?.show()
        } else {
            // Selection was adjusted — update editor layout
            editController?.updateLayout(
                selectionRect: screenRect,
                selectionViewRect: rect,
                captureRect: cgRect
            )
        }
    }

    func selectionDidChange(rect: NSRect, inView view: NSView) {
        guard let _ = view.window else { return }
        let screenRect = convertToScreenRect(rect, view: view)
        let cgRect = convertToCGRect(screenRect)
        editController?.updateLayout(
            selectionRect: screenRect,
            selectionViewRect: rect,
            captureRect: cgRect
        )
    }
}

// MARK: - Non-activating Overlay Panel

/// A borderless panel that becomes key without activating the app,
/// so other apps' transient popups (menus, download panels, etc.) stay visible.
private class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
