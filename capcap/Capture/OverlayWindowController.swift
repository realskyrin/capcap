import AppKit
import QuartzCore

struct CaptureResult {
    let rect: CGRect       // In CG coordinates (top-left origin) for capture
    let screen: NSScreen   // The screen where selection was made
    let screenRect: NSRect // In AppKit coordinates for editor positioning
}

class OverlayWindowController {
    private var windows: [NSWindow] = []
    private var chipWindow: CursorChipWindow?
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    private var editController: EditWindowController?
    private var activeSelectionView: SelectionView?
    private let windowDetector = WindowDetector()
    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]
    private let onComplete: (NSImage?) -> Void

    init(onComplete: @escaping (NSImage?) -> Void) {
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
            window.sharingType = .none
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
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            if event.keyCode == 36 { // Enter — confirm screenshot
                self?.editController?.confirmFromKeyboard()
                return nil
            }
            return event
        }
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
            }
        }

        NSCursor.crosshair.push()
    }

    func cancel() {
        editController?.tearDown()
        editController = nil
        tearDown()
        onComplete(nil)
    }

    private var cursorPopped = false

    private func tearDown() {
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

            // Pop the crosshair cursor pushed during activate()
            NSCursor.pop()
            cursorPopped = true

            // First time selection complete — show editor
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let preSnapshot = displayID.flatMap { screenSnapshots[$0] }

            editController = EditWindowController(
                captureRect: cgRect,
                screen: screen,
                selectionRect: screenRect,
                selectionViewRect: rect,
                hostSelectionView: selectionView,
                preSnapshot: preSnapshot
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
