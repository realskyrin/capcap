import AppKit
import ApplicationServices

/// 小步滚动与后台采帧分开运行，拼接耗时不会使正常滚动一顿一顿
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
    private let captureInterval: TimeInterval = 0.12
    private let stallThreshold: Int
    private let queue = DispatchQueue(label: "capcap.auto-scroll", qos: .userInitiated)
    private let motionQueue = DispatchQueue(label: "capcap.auto-scroll-motion", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let onKeyPressed: (() -> Void)?
    private var motionTimer: DispatchSourceTimer?

    /// Stamped onto capcap's synthetic scroll events so the input-blocking
    /// tap can tell them apart from the user's real trackpad / wheel input
    /// and let only capcap's own events through.
    private static let syntheticTag: Int64 = 0x6361_7063_0001  // "capc" + marker

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let lock = NSLock()
    private var cancelledFlag = false
    private var motion: MotionState
    private var lastTick: TimeInterval = 0
    private var gestureActive = false

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// - Parameters:
    ///   - centerPoint: where to aim the scroll events, in global CG coords.
    ///   - blockingRect: the capture region (global CG coords); the user's own
    ///     mouse input over this region is dropped while auto-scroll runs.
    ///   - speedPointsPerSecond: 每秒移动的屏幕点数，与 Retina 像素倍率无关
    ///   - stallThreshold: consecutive no-progress steps that mean "page end".
    init(
        centerPoint: CGPoint,
        blockingRect: CGRect,
        speedPointsPerSecond: Double,
        stallThreshold: Int = 4,
        onKeyPressed: (() -> Void)? = nil
    ) {
        self.location = centerPoint
        self.blockingRect = blockingRect
        self.motion = MotionState(
            speed: speedPointsPerSecond,
            maximumUnconfirmedTravel: max(1, Int(blockingRect.height * 0.35))
        )
        self.stallThreshold = stallThreshold
        self.onKeyPressed = onKeyPressed
    }

    /// Begins the scroll loop on a background queue.
    /// - Parameters:
    ///   - captureStep: 后台采集当前帧，不应等待持续滚动的画面静止
    ///   - onFinished: 在主线程区分正常停止与连续失败，取消后不再回调
    func start(
        captureStep: @escaping () -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        installInputBlocker()
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: motionQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        motionTimer = timer
        timer.resume()
        queue.async { [weak self] in
            self?.runLoop(captureStep: captureStep, onFinished: onFinished)
        }
    }

    /// 锁内停止投递并结束手势，后台采帧即使晚返回也不能重新开始滚动
    func stop() {
        lock.lock()
        cancelledFlag = true
        endGesture()
        lock.unlock()
        motionTimer?.cancel()
        removeInputBlockerOnMain()
    }

    private func runLoop(
        captureStep: @escaping () -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        var policy = StepPolicy(stallThreshold: stallThreshold)
        var lastCaptureTravel = 0

        while true {
            if cancelled { return }
            Thread.sleep(forTimeInterval: captureInterval)
            if cancelled { return }

            // 只确认采帧开始前的位移，保留采帧/匹配期间新增的位移额度
            lock.lock()
            let sampledTravel = motion.totalTravel
            lock.unlock()
            let hadScroll = sampledTravel > lastCaptureTravel
            lastCaptureTravel = sampledTravel
            let result = captureStep()
            lock.lock()
            guard !cancelledFlag else { lock.unlock(); return }
            switch policy.accept(result, hadScroll: hadScroll) {
            case .scrollAgain:
                motion.acknowledge(sampledTravel)
                lock.unlock()
            case .retryCapture:
                motion.pause()
                endGesture()
                lock.unlock()
            case .finish:
                motion.pause()
                endGesture()
                lock.unlock()
                motionTimer?.cancel()
                let reason: FinishReason = policy.failed ? .failed : .completed
                DispatchQueue.main.async { [weak self] in
                    guard self?.cancelled == false else { return }
                    onFinished(reason)
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

        mutating func accept(_ result: StepResult, hadScroll: Bool = true) -> Action {
            switch result {
            case .progressed:
                stalls = 0
                retries = 0
            case .stalled:
                // 暂停重试期间没有新滚动，静止画面不能作为到达底部的新证据
                if hadScroll { stalls += 1 }
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

    /// 累积小数点位移，并限制尚未被截图确认的距离，防止慢机丢掉重叠内容
    struct MotionState {
        let speed: Double
        let maximumUnconfirmedTravel: Int
        private(set) var totalTravel = 0
        private var confirmedTravel = 0
        private var fractionalTravel = 0.0
        private var paused = false

        var isBackpressured: Bool {
            totalTravel - confirmedTravel >= maximumUnconfirmedTravel
        }

        init(speed: Double, maximumUnconfirmedTravel: Int) {
            self.speed = max(1, speed)
            self.maximumUnconfirmedTravel = max(1, maximumUnconfirmedTravel)
        }

        mutating func advance(elapsed: TimeInterval) -> Int {
            guard !paused else { return 0 }
            // 调度延迟只慢下来，不把欠下的时间补成一次大跳
            fractionalTravel += speed * min(max(0, elapsed), 1.0 / 30)
            let available = maximumUnconfirmedTravel - (totalTravel - confirmedTravel)
            let delta = min(Int(fractionalTravel), available)
            fractionalTravel -= Double(delta)
            if delta == available { fractionalTravel = 0 }
            totalTravel += delta
            return delta
        }

        mutating func acknowledge(_ travel: Int) {
            confirmedTravel = max(confirmedTravel, min(totalTravel, travel))
            paused = false
        }

        mutating func pause() {
            paused = true
            fractionalTravel = 0
        }
    }

    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelledFlag else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = motion.advance(elapsed: now - lastTick)
        lastTick = now
        guard delta > 0 else {
            if motion.isBackpressured { endGesture() }
            return
        }
        let phase: CGScrollPhase = gestureActive ? .changed : .began
        guard let event = makeScrollEvent(delta: -delta, phase: phase) else { return }
        event.post(tap: .cghidEventTap)
        gestureActive = true
    }

    // 调用方持有 lock，结束手势与停止非零位移按同一顺序生效
    private func endGesture() {
        guard gestureActive else { return }
        makeScrollEvent(delta: 0, phase: .ended)?.post(tap: .cghidEventTap)
        gestureActive = false
    }

    func makeScrollEvent(delta: Int, phase: CGScrollPhase) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(clamping: delta),
            wheel2: 0,
            wheel3: 0
        ) else {
            return nil
        }

        // 使用连续像素滚动和 CG 阶段值，避免应用把小步事件按离散滚轮加速
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.location = location
        return event
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
        motionTimer?.cancel()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }
}
