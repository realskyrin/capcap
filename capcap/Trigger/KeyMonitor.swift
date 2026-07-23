import AppKit

class KeyMonitor {
    /// Master switch. When false, neither trigger fires (used during shortcut recording).
    var isEnabled: Bool = true {
        didSet {
            if !isEnabled { resetSequence() }
        }
    }

    /// Plain double-tap ⌘ → regular screenshot. Disabled when a custom hotkey is registered.
    var isRegularDoubleTapEnabled: Bool = true {
        didSet { if !isRegularDoubleTapEnabled { resetSequence() } }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastCommandPressTime: TimeInterval = 0
    private var lastCommandPressOption: Bool = false
    private var commandIsDown = false
    private var otherKeyPressed = false
    private let onTrigger: (CaptureTriggerContext) -> Void
    private let onCountdownTrigger: () -> Void

    private struct ModifierSample {
        let commandIsDown: Bool
        let optionIsDown: Bool
        let hasDisruptiveModifiers: Bool
        let eventUptime: TimeInterval
    }

    init(onTrigger: @escaping (CaptureTriggerContext) -> Void,
         onCountdownTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        self.onCountdownTrigger = onCountdownTrigger
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        guard !startEventTapMonitoring() else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
    }

    private func stopMonitoring() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        if let m = keyDownMonitor {
            NSEvent.removeMonitor(m)
            keyDownMonitor = nil
        }
    }

    private func resetSequence() {
        lastCommandPressTime = 0
        commandIsDown = false
        otherKeyPressed = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        handleModifierSample(ModifierSample(
            commandIsDown: event.modifierFlags.contains(.command),
            optionIsDown: event.modifierFlags.contains(.option),
            hasDisruptiveModifiers: event.modifierFlags.contains(.shift)
                || event.modifierFlags.contains(.control),
            eventUptime: event.timestamp
        ))
    }

    @discardableResult
    private func startEventTapMonitoring() -> Bool {
        let types: [CGEventType] = [.flagsChanged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleTappedEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private func handleTappedEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        case .keyDown:
            otherKeyPressed = true
        case .flagsChanged:
            let flags = event.flags
            handleModifierSample(ModifierSample(
                commandIsDown: flags.contains(.maskCommand),
                optionIsDown: flags.contains(.maskAlternate),
                hasDisruptiveModifiers: flags.contains(.maskShift)
                    || flags.contains(.maskControl),
                eventUptime: Double(event.timestamp) / 1_000_000_000
            ))
        default:
            break
        }
    }

    private func handleModifierSample(_ sample: ModifierSample) {
        guard isEnabled else { return }

        if sample.hasDisruptiveModifiers {
            otherKeyPressed = true
            commandIsDown = sample.commandIsDown
            return
        }

        if sample.commandIsDown && !commandIsDown {
            let now = sample.eventUptime
            let withinWindow = (now - lastCommandPressTime) < Defaults.doubleTapInterval
            // Both presses must share the same Option state — a sequence that
            // mixes ⌘ then ⌥⌘ is treated as a fresh first press, not a double-tap.
            let isDoubleTap = !otherKeyPressed
                && withinWindow
                && lastCommandPressOption == sample.optionIsDown

            if isDoubleTap {
                if sample.optionIsDown {
                    MainRunLoopScheduler.perform { [weak self] in self?.onCountdownTrigger() }
                } else if isRegularDoubleTapEnabled {
                    let context = CaptureTriggerContext(
                        source: .doubleCommand,
                        eventUptime: now
                    )
                    context.mark(.doubleCommandDetected)
                    MainRunLoopScheduler.perform { [weak self] in
                        context.mark(.mainRunLoopCallback)
                        guard let self else {
                            context.finish(.ignored)
                            return
                        }
                        self.onTrigger(context)
                    }
                }
                lastCommandPressTime = 0
            } else {
                lastCommandPressTime = now
                lastCommandPressOption = sample.optionIsDown
            }
            otherKeyPressed = false
        }

        commandIsDown = sample.commandIsDown
    }
}
