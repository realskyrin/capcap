import AppKit
import ApplicationServices

/// Drives a constant-speed automatic scroll over a screen region by posting
/// synthetic scroll-wheel events, so long-screenshot capture no longer needs
/// the user to scroll by hand. Uniform steps mean evenly-spaced frames, which
/// the stitcher can align far more reliably than uneven manual scrolling.
///
/// The loop posts one fixed scroll step, waits for the screen to settle, asks
/// the caller to capture a frame, and repeats. When several consecutive frames
/// report no new content, the page has bottomed out and the loop finishes.
final class AutoScroller {
    /// What a single capture step revealed, reported back by the caller.
    enum StepResult {
        /// The step revealed fresh content — keep scrolling.
        case progressed
        /// No new content this step (duplicate / tiny delta).
        case stalled
        /// 本帧不可靠，应在原位置重试，避免滚动后失去重叠区域
        case retry
        /// Capturing must stop now (e.g. the frame budget is exhausted).
        case finished
    }

    enum FinishReason { case completed, failed }

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
        self.stepPixels = max(20, stepPixels)
        self.settleDelay = settleDelay
        self.stallThreshold = stallThreshold
        self.onKeyPressed = onKeyPressed
    }

    /// Begins the scroll loop on a background queue.
    /// - Parameters:
    ///   - captureStep: invoked off the main thread after each scroll step;
    ///     should capture a frame and report what it revealed.
    ///   - onFinished: 在主线程区分正常停止与连续失败，取消后不再回调
    func start(
        captureStep: @escaping () -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        installInputBlocker()
        queue.async { [weak self] in
            self?.runLoop(captureStep: captureStep, onFinished: onFinished)
        }
    }

    /// Cancels the loop. The loop exits at its next checkpoint (within roughly
    /// `settleDelay`); `onFinished` will not fire afterwards.
    func stop() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
        removeInputBlockerOnMain()
    }

    private func runLoop(
        captureStep: @escaping () -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        var policy = StepPolicy(stallThreshold: stallThreshold)
        var shouldScroll = true

        while true {
            if cancelled { return }
            if shouldScroll { postScrollStep() }
            Thread.sleep(forTimeInterval: settleDelay)
            if cancelled { return }

            switch policy.accept(captureStep()) {
            case .scrollAgain:
                shouldScroll = true
            case .retryCapture:
                shouldScroll = false
            case .finish:
                if !cancelled {
                    let reason: FinishReason = policy.failed ? .failed : .completed
                    DispatchQueue.main.async { [weak self] in
                        guard self?.cancelled == false else { return }
                        onFinished(reason)
                    }
                }
                return
            }
        }
    }

    /// 区分确认静止与匹配失败；重试也有上限，防止永久占用输入
    struct StepPolicy {
        enum Action: Equatable { case scrollAgain, retryCapture, finish }
        let stallThreshold: Int
        private var stalls = 0
        private var retries = 0
        private(set) var failed = false

        init(stallThreshold: Int) { self.stallThreshold = stallThreshold }

        mutating func accept(_ result: StepResult) -> Action {
            switch result {
            case .progressed:
                stalls = 0
                retries = 0
            case .stalled:
                stalls += 1
                retries = 0
            case .retry:
                stalls = 0
                retries += 1
                failed = retries >= stallThreshold
                return failed ? .finish : .retryCapture
            case .finished:
                return .finish
            }
            return stalls >= stallThreshold ? .finish : .scrollAgain
        }
    }

    private func postScrollStep() {
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
            return
        }

        // Stamp the event so the input-blocking tap recognises it as capcap's
        // own scroll and lets it through (untagged scroll over the region is
        // the user's, and gets dropped).
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.location = location
        event.post(tap: .cghidEventTap)
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
