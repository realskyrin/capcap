import AppKit

class KeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCommandPressTime: TimeInterval = 0
    private var commandIsDown = false
    private var otherKeyPressed = false
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        // Monitor flag changes (modifier keys) globally
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Also monitor locally when app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // Monitor regular key presses to invalidate double-tap sequence
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
    }

    private func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let commandPressed = event.modifierFlags.contains(.command)

        // Only care about Command with no other modifiers
        let otherModifiers: NSEvent.ModifierFlags = [.shift, .option, .control]
        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if hasOtherModifiers {
            otherKeyPressed = true
            commandIsDown = commandPressed
            return
        }

        if commandPressed && !commandIsDown {
            // Command key just went down
            let now = ProcessInfo.processInfo.systemUptime

            if !otherKeyPressed && (now - lastCommandPressTime) < Defaults.doubleTapInterval {
                // Double-tap detected!
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger()
                }
                lastCommandPressTime = 0
            } else {
                lastCommandPressTime = now
            }
            otherKeyPressed = false
        }

        commandIsDown = commandPressed
    }
}
