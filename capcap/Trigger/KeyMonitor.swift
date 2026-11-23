import AppKit

/// Double-tap ⌘ state machine. Kept free of event plumbing so the interruption
/// rules can be exercised without an event tap.
struct DoubleTapCommandSequence {
    enum Outcome: Equatable {
        /// Nothing to act on.
        case idle
        /// First ⌘ press recorded, waiting for a second one.
        case armed
        /// Second ⌘ press inside the window: regular screenshot.
        case doubleTap
        /// Second ⌥⌘ press inside the window: countdown screenshot.
        case countdown
    }

    private(set) var lastPressTime: TimeInterval = 0
    private(set) var lastPressOption = false
    private(set) var commandIsDown = false
    private(set) var otherKeyPressed = false

    mutating func reset() {
        lastPressTime = 0
        commandIsDown = false
        otherKeyPressed = false
    }

    /// A key press or modifier that is not a bare ⌘ press interrupts the sequence.
    mutating func registerInterruption() {
        otherKeyPressed = true
    }

    mutating func handle(
        commandIsDown: Bool,
        optionIsDown: Bool,
        hasDisruptiveModifiers: Bool,
        at time: TimeInterval,
        interval: TimeInterval
    ) -> Outcome {
        if hasDisruptiveModifiers {
            otherKeyPressed = true
            self.commandIsDown = commandIsDown
            return .idle
        }

        var outcome = Outcome.idle
        if commandIsDown && !self.commandIsDown {
            let withinWindow = (time - lastPressTime) < interval
            // Both presses must share the same Option state — a sequence that
            // mixes ⌘ then ⌥⌘ is treated as a fresh first press, not a double-tap.
            let isDoubleTap = !otherKeyPressed
                && withinWindow
                && lastPressOption == optionIsDown

            if isDoubleTap {
                outcome = optionIsDown ? .countdown : .doubleTap
                lastPressTime = 0
            } else {
                lastPressTime = time
                lastPressOption = optionIsDown
                outcome = .armed
            }
            otherKeyPressed = false
        }

        self.commandIsDown = commandIsDown
        return outcome
    }
}

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
    private var appActivationObserver: NSObjectProtocol?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var sequence = DoubleTapCommandSequence()
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
        // ⌘-Tab is consumed by the system app switcher, so its Tab keyDown never
        // reaches this process: `otherKeyPressed` would stay false and the next
        // single ⌘ tap would look like the second tap of a double-tap. Reset the
        // sequence whenever the frontmost app changes instead.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetSequence()
        }

        guard !startEventTapMonitoring() else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.sequence.registerInterruption()
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
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
    }

    private func resetSequence() {
        sequence.reset()
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
            sequence.registerInterruption()
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

        let outcome = sequence.handle(
            commandIsDown: sample.commandIsDown,
            optionIsDown: sample.optionIsDown,
            hasDisruptiveModifiers: sample.hasDisruptiveModifiers,
            at: sample.eventUptime,
            interval: Defaults.doubleTapInterval
        )

        switch outcome {
        case .doubleTap:
            guard isRegularDoubleTapEnabled else { return }
            let context = CaptureTriggerContext(
                source: .doubleCommand,
                eventUptime: sample.eventUptime
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
        case .countdown:
            MainRunLoopScheduler.perform { [weak self] in self?.onCountdownTrigger() }
        case .armed, .idle:
            break
        }
    }
}
