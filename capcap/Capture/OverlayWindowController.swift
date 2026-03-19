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
    private let onComplete: (CaptureResult?) -> Void

    init(onComplete: @escaping (CaptureResult?) -> Void) {
        self.onComplete = onComplete
    }

    func activate() {
        // Create overlay window for each screen
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
            window.sharingType = .none  // Exclude from screen capture

            let selectionView = SelectionView(frame: screen.frame)
            selectionView.delegate = self
            window.contentView = selectionView

            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        // Show cursor chip
        chipWindow = CursorChipWindow()
        chipWindow?.show()

        // Monitor Escape to cancel (both local and global)
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
        tearDown()
        onComplete(nil)
    }

    private func tearDown() {
        NSCursor.pop()

        chipWindow?.dismiss()
        chipWindow = nil

        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m); escGlobalMonitor = nil }

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

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

        // Convert from view coordinates to screen coordinates
        let screenRect = window.convertToScreen(view.convert(rect, to: nil))

        // Convert to CG coordinates (top-left origin)
        let primaryHeight = NSScreen.screens[0].frame.height
        let cgRect = CGRect(
            x: screenRect.origin.x,
            y: primaryHeight - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )

        let result = CaptureResult(rect: cgRect, screen: screen, screenRect: screenRect)

        // Hide overlay windows FIRST so macOS restores underlying window rendering
        // (otherwise system UI like toggles appear dimmed/gray)
        for w in windows {
            w.orderOut(nil)
        }

        // Wait one frame for the system to finish compositing without overlays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            tearDown()
            onComplete(result)
        }
    }
}
