import AppKit

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
    private var activeScreen: NSScreen?
    private let onComplete: (NSImage?) -> Void

    init(onComplete: @escaping (NSImage?) -> Void) {
        self.onComplete = onComplete
    }

    func activate() {
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
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

            let selectionView = SelectionView(frame: screen.frame)
            selectionView.delegate = self
            window.contentView = selectionView

            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        chipWindow = CursorChipWindow()
        chipWindow?.show()

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
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

        activeSelectionView = view as? SelectionView
        activeScreen = screen

        let screenRect = convertToScreenRect(rect, view: view)
        let cgRect = convertToCGRect(screenRect)

        if editController == nil {
            // Lock selection so clicking outside won't reset it
            activeSelectionView?.selectionLocked = true

            // Pop the crosshair cursor pushed during activate()
            NSCursor.pop()
            cursorPopped = true

            // First time selection complete — show editor
            editController = EditWindowController(
                captureRect: cgRect,
                screen: screen,
                selectionRect: screenRect
            ) { [weak self] finalImage in
                self?.tearDown()
                self?.onComplete(finalImage)
            }
            editController?.show()
        } else {
            // Selection was adjusted — update editor layout
            editController?.updateLayout(selectionRect: screenRect, captureRect: cgRect)
        }
    }

    func selectionDidChange(rect: NSRect, inView view: NSView) {
        guard let _ = view.window else { return }
        let screenRect = convertToScreenRect(rect, view: view)
        let cgRect = convertToCGRect(screenRect)
        editController?.updateLayout(selectionRect: screenRect, captureRect: cgRect)
    }
}
