import AppKit
import ApplicationServices

/// Drives a constant-speed automatic scroll over a screen region by posting
/// synthetic scroll-wheel events, so long-screenshot capture no longer needs
/// the user to scroll by hand. Uniform steps mean evenly-spaced frames, which
/// the stitcher can align far more reliably than uneven manual scrolling.
///
/// The loop posts a scroll step, waits for the screen to redraw, and asks the
/// caller to capture a frame. An uncertain overlap gets one in-place retry,
/// then scrolling continues to bring more content into view. The loop
/// finishes after several consecutive captures without verified progress.
final class AutoScroller {
    /// What a single capture step revealed, reported back by the caller.
    enum StepResult {
        /// The step revealed fresh content — keep scrolling.
        case progressed
        /// No new content this step (duplicate / tiny delta).
        case stalled
        /// The overlap was uncertain. Retry once in place, then scroll again.
        case retry
        /// Capturing must stop now (e.g. the frame budget is exhausted).
        case finished
    }

    /// Auto-scroll posts events into other apps, which requires the process to
    /// be trusted for Accessibility. Without it, posting silently no-ops.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    private let location: CGPoint           // global CG coords (top-left origin)
    private let blockingRect: CGRect        // global CG coords; manual input here is dropped
    private let stepPixels: Int
    private let settleDelay: TimeInterval
    private let stallThreshold: Int
    private let queue = DispatchQueue(label: "capcap.auto-scroll", qos: .userInitiated)
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let onKeyPressed: (() -> Void)?

    /// Stamped onto capcap's synthetic scroll events so the input-blocking
    /// tap can tell them apart from the user's real trackpad / wheel input
    /// and let only capcap's own events through.
    private static let syntheticTag: Int64 = 0x6361_7063_0001  // "capc" + marker

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let lock = NSLock()
    private var cancelledFlag = false
    private var pendingScrollStep = false

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// - Parameters:
    ///   - centerPoint: where to aim the scroll events, in global CG coords.
    ///   - blockingRect: the capture region (global CG coords); the user's own
    ///     mouse input over this region is dropped while auto-scroll runs.
    ///   - stepPixels: how far to scroll per step (also the overlap hint).
    ///   - settleDelay: pause after each step so the screen finishes redrawing.
    ///   - stallThreshold: consecutive no-progress steps that mean "page end".
    init(
        centerPoint: CGPoint,
        blockingRect: CGRect,
        stepPixels: Int,
        settleDelay: TimeInterval = 0.12,
        stallThreshold: Int = 4,
        onKeyPressed: (() -> Void)? = nil
    ) {
        self.location = centerPoint
        self.blockingRect = blockingRect
        self.stepPixels = max(1, stepPixels)
        self.settleDelay = settleDelay
        self.stallThreshold = stallThreshold
        self.onKeyPressed = onKeyPressed
    }

    /// Begins the scroll loop on a background queue.
    /// - Parameters:
    ///   - captureStep: captures a frame off the main thread and reports what it
    ///     revealed. Receives the number of steps posted since the last progress.
    ///   - onFinished: invoked on the main queue when the loop finishes on its own.
    func start(
        captureStep: @escaping (_ scrolledSteps: Int) -> StepResult,
        onFinished: @escaping () -> Void
    ) {
        installInputBlocker()
        queue.async { [weak self] in
            self?.runLoop(captureStep: captureStep, onFinished: onFinished)
        }
    }

    /// Cancels the loop and reports whether a posted step still needs capture.
    @discardableResult
    func stop() -> Bool {
        lock.lock()
        cancelledFlag = true
        let needsCapture = pendingScrollStep
        lock.unlock()
        removeInputBlockerOnMain()
        return needsCapture
    }

    static func nextCapture(
        after result: StepResult, consecutiveRetries: Int
    ) -> (shouldScroll: Bool, consecutiveRetries: Int) {
        let retries = result == .retry ? consecutiveRetries + 1 : 0
        return (shouldScroll: retries != 1, consecutiveRetries: retries)
    }

    private func runLoop(
        captureStep: @escaping (_ scrolledSteps: Int) -> StepResult,
        onFinished: @escaping () -> Void
    ) {
        var stallCount = 0
        var scrolledSteps = 0
        var nextCapture = (shouldScroll: true, consecutiveRetries: 0)

        while true {
            lock.lock()
            guard !cancelledFlag else {
                lock.unlock()
                return
            }
            if nextCapture.shouldScroll {
                guard postScrollStep() else {
                    lock.unlock()
                    break
                }
                pendingScrollStep = true
                scrolledSteps += 1
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: settleDelay)

            lock.lock()
            guard !cancelledFlag else {
                lock.unlock()
                return
            }
            pendingScrollStep = false
            lock.unlock()
            let result = captureStep(scrolledSteps)

            switch result {
            case .progressed:
                stallCount = 0
                scrolledSteps = 0
            case .stalled, .retry:
                stallCount += 1
            case .finished:
                stallCount = stallThreshold
            }

            if stallCount >= stallThreshold { break }
            // The stitcher checks every new frame against the last appended
            // frame, so stepping again can reveal more detail without a gap.
            nextCapture = Self.nextCapture(after: result, consecutiveRetries: nextCapture.consecutiveRetries)
        }
        if !cancelled {
            DispatchQueue.main.async { [weak self] in
                guard self?.cancelled == false else { return }
                onFinished()
            }
        }
    }

    private func postScrollStep() -> Bool {
        // Negative wheel1 scrolls the page content downward, revealing content
        // further down — the direction long-screenshot stitching expects.
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-stepPixels),
            wheel2: 0,
            wheel3: 0
        ) else {
            return false
        }

        // Stamp the event so the input-blocking tap recognises it as capcap's
        // own scroll and lets it through (untagged scroll over the region is
        // the user's, and gets dropped).
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.location = location
        event.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Manual Input Blocking

    /// Installs a session-level event tap that drops the user's own mouse
    /// events while the pointer is inside the capture region, so manual
    /// scrolling or clicking can't disturb the page mid-capture. Any key press
    /// finishes the capture and is swallowed so it does not affect the page.
    /// capcap's own synthetic scroll carries `syntheticTag` and is always let
    /// through.
    private func installInputBlocker() {
        let types: [CGEventType] = [
            .keyDown,
            .scrollWheel,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let scroller = Unmanaged<AutoScroller>.fromOpaque(refcon).takeUnretainedValue()
                return scroller.handleTappedEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // No tap (shouldn't happen — Accessibility is already granted).
            // Auto-scroll still works; the user just isn't blocked.
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    /// Decides each tapped event's fate. Runs on the main run loop.
    private func handleTappedEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return passthrough

        case .scrollWheel:
            // capcap's synthetic auto-scroll is tagged — it must pass, or the
            // page never moves. Untagged scroll over the region is the user's.
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
                return passthrough
            }
            return blockingRect.contains(event.location) ? nil : passthrough

        case .keyDown:
            lock.lock()
            let wasCancelled = cancelledFlag
            cancelledFlag = true
            lock.unlock()

            if !wasCancelled {
                let onKeyPressed = onKeyPressed
                DispatchQueue.main.async {
                    onKeyPressed?()
                }
            }
            return nil

        default:
            // Mouse clicks / drags: capcap posts no synthetic ones, so anything
            // inside the capture region is the user's — drop it.
            return blockingRect.contains(event.location) ? nil : passthrough
        }
    }

    private func removeInputBlockerOnMain() {
        if Thread.isMainThread {
            removeInputBlocker()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.removeInputBlocker()
            }
        }
    }

    private func removeInputBlocker() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }
}
