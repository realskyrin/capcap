import AppKit
import ApplicationServices

/// 小步滚动与后台采帧分开运行，拼接耗时不会使正常滚动一顿一顿
final class AutoScroller {
    /// What a single capture step revealed, reported back by the caller.
    enum StepResult {
        /// The step revealed fresh content — keep scrolling.
        case progressed
        /// 画面移动，但仍在已拼接范围内，不能当作新增内容
        case revisited
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
    private let interactiveRect: CGRect?
    // 滚动仍以 60 Hz 连续发送，采帧保留足够重叠，同时避免短间隔过早耗尽 100 帧上限
    private let captureInterval: TimeInterval = 0.2
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

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// - Parameters:
    ///   - centerPoint: where to aim the scroll events, in global CG coords.
    ///   - blockingRect: the capture region (global CG coords); the user's own
    ///     mouse input over this region is dropped while auto-scroll runs.
    ///   - interactiveRect: 选区内控制条的全局 CG 坐标区域，保留其鼠标交互
    ///   - speedPointsPerSecond: 每秒移动的屏幕点数，与 Retina 像素倍率无关
    ///   - stallThreshold: consecutive no-progress steps that mean "page end".
    init(
        centerPoint: CGPoint,
        blockingRect: CGRect,
        interactiveRect: CGRect? = nil,
        speedPointsPerSecond: Double,
        stallThreshold: Int = 4,
        onKeyPressed: (() -> Void)? = nil
    ) {
        self.location = centerPoint
        self.blockingRect = blockingRect
        self.interactiveRect = interactiveRect
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

    /// 锁内停止投递，后台采帧即使晚返回也不能重新开始滚动
    func stop() {
        lock.lock()
        cancelledFlag = true
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
        var cadence = CaptureCadence(interval: captureInterval, now: ProcessInfo.processInfo.systemUptime)

        while true {
            if cancelled { return }
            let delay = cadence.delay(at: ProcessInfo.processInfo.systemUptime)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if cancelled { return }
            cadence.didStart(at: ProcessInfo.processInfo.systemUptime)

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
                lock.unlock()
            case .finish:
                motion.pause()
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

    /// 按实际采帧起点计时，处理耗时抵扣等待；过期周期直接丢弃，避免补采突发
    struct CaptureCadence {
        let interval: TimeInterval
        private var nextStart: TimeInterval

        init(interval: TimeInterval, now: TimeInterval) {
            self.interval = interval
            nextStart = now + interval
        }

        func delay(at now: TimeInterval) -> TimeInterval { max(0, nextStart - now) }

        mutating func didStart(at now: TimeInterval) { nextStart = now + interval }
    }

    /// 区分确认静止与匹配失败；重试也有上限，防止永久占用输入
    struct StepPolicy {
        enum Action: Equatable { case scrollAgain, retryCapture, finish }
        let stallThreshold: Int
        private var stalls = 0
        private var retries = 0
        private var noProgressSteps = 0
        private var hasUnreliableFrame = false
        private(set) var failed = false

        init(stallThreshold: Int) { self.stallThreshold = stallThreshold }

        mutating func accept(_ result: StepResult, hadScroll: Bool = true) -> Action {
            var action = Action.scrollAgain
            switch result {
            case .progressed:
                stalls = 0
                retries = 0
                noProgressSteps = 0
                hasUnreliableFrame = false
            case .stalled, .revisited:
                // 页尾回弹仍在已拼接范围内，不能重置停滞计数；无新输入则不重复计数
                if hadScroll { stalls += 1 }
                if hadScroll || hasUnreliableFrame { noProgressSteps += 1 }
                retries = 0
            case .retry:
                stalls = 0
                retries += 1
                noProgressSteps += 1
                hasUnreliableFrame = true
                failed = retries >= stallThreshold
                if failed { return .finish }
                action = .retryCapture
            case .finished:
                return .finish
            }
            // 失败与静止交替时也必须结束；缺少可靠新增帧不能冒充已到页底
            if hasUnreliableFrame && noProgressSteps >= stallThreshold * 2 {
                failed = true
                return .finish
            }
            return stalls >= stallThreshold ? .finish : action
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
        guard delta > 0, let event = makeScrollEvent(delta: -delta) else { return }
        event.post(tap: .cghidEventTap)
    }

    func makeScrollEvent(delta: Int) -> CGEvent? {
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

        // 保留连续像素小步，但不模拟触控板手势，避免页尾弹性拉伸被误拼为新增内容
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.location = location
        return event
    }

    // MARK: - Manual Input Blocking

    /// Installs a session-level event tap that drops the user's own mouse
    /// events while the pointer is inside the capture region, so manual
    /// scrolling or clicking can't disturb the page mid-capture.
    /// 空格交给会话监听切换模式，其他按键结束截图且不会传给底层页面
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
            // 空格交给整个截图会话的切换监听，不能先取消自动滚动并结束长图
            if let keyEvent = NSEvent(cgEvent: event), ScrollCaptureKeyState.isModeSwitchKey(keyEvent) {
                return passthrough
            }
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
            // 选区内的控制条仍须接收点击，正文区域继续拦截，避免打断自动滚动
            return blocksMouseInput(at: event.location) ? nil : passthrough
        }
    }

    func blocksMouseInput(at point: CGPoint) -> Bool {
        blockingRect.contains(point) && !(interactiveRect?.contains(point) ?? false)
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
