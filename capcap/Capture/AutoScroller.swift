import AppKit
import ApplicationServices
import Carbon
import os

/// Activates the window under the selected region and moves the real pointer
/// into its content before posting pixel scroll events. Each step waits for
/// capture/alignment to finish before another scroll is posted.
final class AutoScroller {
    private static let logger = Logger(subsystem: "cn.skyrin.capcap", category: "AutoScroll")
    private static let modifierFlagsByKeyCode: [CGKeyCode: CGEventFlags] = [
        CGKeyCode(kVK_Command): .maskCommand,
        CGKeyCode(kVK_RightCommand): .maskCommand,
        CGKeyCode(kVK_Shift): .maskShift,
        CGKeyCode(kVK_RightShift): .maskShift,
        CGKeyCode(kVK_Option): .maskAlternate,
        CGKeyCode(kVK_RightOption): .maskAlternate,
        CGKeyCode(kVK_Control): .maskControl,
        CGKeyCode(kVK_RightControl): .maskControl,
        CGKeyCode(kVK_Function): .maskSecondaryFn
    ]
    /// What a single capture step revealed, reported back by the caller.
    enum StepResult {
        /// The step revealed fresh content — keep scrolling.
        case progressed
        /// No new content this step (duplicate / tiny delta).
        case stalled
        /// The frame could not be aligned; capture again at this position.
        case retry
        /// No usable frame was captured; do not interpret this as a mismatch.
        case captureUnavailable
        /// The capture source stopped permanently; finish without more input.
        case captureFailed
        /// Capturing must stop now (e.g. the frame budget is exhausted).
        case finished
    }

    enum FinishReason {
        /// No step ever revealed new content; this is not proof of page end.
        case noProgress
        /// A vertical scrollbar confirms that the content reached its end.
        case noNewContent
        /// Frames stopped changing, but there is no evidence of page end.
        case movementUnconfirmed
        case alignmentFailed
        case captureUnavailable
        case capacity
        case targetUnavailable
        case permissionDenied
    }

    /// Preflight only: requesting a permission belongs to the permission UI.
    static var isPermitted: Bool {
        let accessibility = AXIsProcessTrusted()
        let posting = CGPreflightPostEventAccess()
        if !accessibility || !posting {
            logger.notice("permission blocked accessibility=\(accessibility) posting=\(posting)")
        }
        return accessibility && posting
    }

    private struct TargetWindow: Equatable {
        let number: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
    }

    private struct ScrollTarget {
        let location: CGPoint
        let area: AXUIElement
        let visibleArea: CGFloat
        let frameArea: CGFloat
    }

    private var location: CGPoint           // main queue, global CG coords (top-left origin)
    private let captureRect: CGRect?
    private var targetScrollArea: AXUIElement? // capture queue, after preparation
    private let excludedWindowNumbers: Set<CGWindowID>
    private let stepPixels: Int
    private let settleDelay: TimeInterval
    private let stallThreshold: Int
    private let queue = DispatchQueue(label: "capcap.auto-scroll", qos: .userInitiated)
    private let eventSource = CGEventSource(stateID: .combinedSessionState)
    private let onKeyPressed: (() -> Void)?
    private let onRecoveryChanged: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var previousModifierFlags: CGEventFlags = []
    private var pressedModifierKeys = Set<CGKeyCode>()

    private let lock = NSLock()
    private var startedFlag = false
    private var cancelledFlag = false
    private var keyFinishPending = false
    private var recoveringFlag = false
    private var recoveryGeneration: UInt64 = 0

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// - Parameters:
    ///   - centerPoint: where to aim the scroll events, in global CG coords.
    ///   - captureRect: selected content bounds, used to locate its scroll area.
    ///   - excludingWindowNumbers: selection and capture chrome, not source windows.
    ///   - stepPixels: how far to scroll per step (also the overlap hint).
    ///   - settleDelay: pause after each step so the screen finishes redrawing.
    ///   - stallThreshold: consecutive frames without new content before stopping.
    init(
        centerPoint: CGPoint,
        stepPixels: Int,
        captureRect: CGRect? = nil,
        excludingWindowNumbers: [CGWindowID] = [],
        settleDelay: TimeInterval = 0.12,
        stallThreshold: Int = 4,
        onKeyPressed: (() -> Void)? = nil,
        onRecoveryChanged: ((Bool) -> Void)? = nil
    ) {
        self.location = centerPoint
        self.captureRect = captureRect?.standardized
        self.excludedWindowNumbers = Set(excludingWindowNumbers)
        self.stepPixels = max(1, min(stepPixels, Int(Int32.max)))
        self.settleDelay = max(0, settleDelay)
        self.stallThreshold = max(1, stallThreshold)
        self.onRecoveryChanged = onRecoveryChanged
        self.onKeyPressed = onKeyPressed
    }

    /// Prepares the target on the main queue, then captures on a background queue.
    /// - Parameters:
    ///   - prepareCapture: captures the initial settled frame after the target
    ///     is ready, before any automatic scroll is sent
    ///   - captureStep: invoked off the main thread after each scroll step;
    ///     receives the most recent downward step as a hint, or zero after rollback
    ///   - onFinished: invoked on the main queue with the observed stop reason
    ///     (not called if `stop()` cancels this one-shot scroller first).
    func start(
        prepareCapture: @escaping () -> Bool = { true },
        captureStep: @escaping (Int) -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        lock.lock()
        let canStart = !startedFlag && !cancelledFlag
        startedFlag = true
        lock.unlock()
        guard canStart else { return }

        DispatchQueue.main.async { [weak self] in
            self?.prepareTarget(
                prepareCapture: prepareCapture,
                captureStep: captureStep,
                onFinished: onFinished
            )
        }
    }

    /// Cancels at the next checkpoint. An in-flight capture may still finish,
    /// but neither completion callback is delivered after cancellation.
    func stop() {
        lock.lock()
        cancelledFlag = true
        keyFinishPending = false
        lock.unlock()
        removeKeyStopTapOnMain()
    }

    private func prepareTarget(
        prepareCapture: @escaping () -> Bool,
        captureStep: @escaping (Int) -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        guard !cancelled else { return }
        guard Self.isPermitted else {
            finish(.permissionDenied, onFinished: onFinished)
            return
        }
        guard eventSource != nil,
              let target = windowAtLocation(),
              let app = NSRunningApplication(processIdentifier: target.ownerPID),
              !app.isTerminated else {
            Self.logger.notice("target resolution failed x=\(Int(self.location.x)) y=\(Int(self.location.y))")
            finish(.targetUnavailable, onFinished: onFinished)
            return
        }
        Self.logger.notice("target window=\(target.number) pid=\(target.ownerPID) active=\(app.isActive) x=\(Int(self.location.x)) y=\(Int(self.location.y)) step=\(self.stepPixels)")

        let isOwnApplication = target.ownerPID == ProcessInfo.processInfo.processIdentifier
        if !isOwnApplication && !app.isActive {
            // macOS 14's cooperative activation avoids relying on the deprecated
            // ignoringOtherApps option. Do not activate ourselves when capturing
            // capcap Settings: that could reorder the capture panels.
            NSApp.yieldActivation(to: app)
            guard app.activate(from: .current, options: []) else {
                Self.logger.notice("target activation rejected pid=\(target.ownerPID)")
                finish(.targetUnavailable, onFinished: onFinished)
                return
            }
        }

        guard installKeyStopTap() else {
            Self.logger.notice("key stop tap installation failed")
            finish(.targetUnavailable, onFinished: onFinished)
            return
        }

        // AX requests can involve another process. Bound the search and keep
        // it off main so the stop gesture and capture controls stay responsive.
        let originalLocation = location
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            let scrollTarget = self.resolveScrollTarget(target, center: originalLocation)
            self.targetScrollArea = scrollTarget?.area
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                if let scrollTarget {
                    self.location = scrollTarget.location
                    Self.logger.notice("scroll area located x=\(Int(scrollTarget.location.x)) y=\(Int(scrollTarget.location.y))")
                } else {
                    Self.logger.notice("scroll area unavailable; retaining selected center")
                }
                self.preparePointer(
                    target: target,
                    application: app,
                    prepareCapture: prepareCapture,
                    captureStep: captureStep,
                    onFinished: onFinished
                )
            }
        }
    }

    private func preparePointer(
        target: TargetWindow,
        application app: NSRunningApplication,
        prepareCapture: @escaping () -> Bool,
        captureStep: @escaping (Int) -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        guard !cancelled else { return }
        guard windowAtLocation() == target else {
            finish(.targetUnavailable, onFinished: onFinished)
            return
        }
        let isOwnApplication = target.ownerPID == ProcessInfo.processInfo.processIdentifier
        let warpResult = CGWarpMouseCursorPosition(location)
        guard warpResult == .success else {
            Self.logger.notice("pointer move failed code=\(warpResult.rawValue)")
            finish(.targetUnavailable, onFinished: onFinished)
            return
        }
        // Activation and cursor hit testing are asynchronous. Event.location
        // alone does not move the pointer or establish its receiving view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.cancelled else { return }
            let currentTarget = self.windowAtLocation()
            guard !app.isTerminated,
                  isOwnApplication || app.isActive,
                  currentTarget == target else {
                Self.logger.notice("target not ready active=\(app.isActive) terminated=\(app.isTerminated) currentWindow=\(currentTarget?.number ?? 0) expectedWindow=\(target.number)")
                self.finish(.targetUnavailable, onFinished: onFinished)
                return
            }
            self.queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                let prepared = prepareCapture()
                guard !self.cancelled else { return }
                guard prepared else {
                    self.finish(.captureUnavailable, onFinished: onFinished)
                    return
                }
                self.runLoop(
                    target: target,
                    application: app,
                    captureStep: captureStep,
                    onFinished: onFinished
                )
            }
        }
    }

    /// WindowServer returns front-to-back order. Resolve only ordinary content
    /// windows and explicitly exclude capture chrome; a capcap source window is
    /// allowed, so excluding this process wholesale would be incorrect.
    private func windowAtLocation() -> TargetWindow? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in windows {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  !excludedWindowNumbers.contains(number),
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID > 0,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(location) else { continue }
            return TargetWindow(number: number, ownerPID: ownerPID, frame: frame)
        }
        return nil
    }

    /// Select only a scroll area that covers most of the chosen content in the
    /// already resolved window. Do not try arbitrary points in sibling panes.
    /// Missing/ambiguous AX data leaves the original center as the fallback.
    private func resolveScrollTarget(_ target: TargetWindow, center: CGPoint) -> ScrollTarget? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        let application = AXUIElementCreateApplication(target.ownerPID)
        let windows = axChildren(application, attribute: kAXWindowsAttribute, limit: 24, deadline: deadline)
        let matchingWindows = windows.filter {
            guard let frame = axFrame($0, deadline: deadline) else { return false }
            return abs(frame.minX - target.frame.minX) < 2
                && abs(frame.minY - target.frame.minY) < 2
                && abs(frame.width - target.frame.width) < 2
                && abs(frame.height - target.frame.height) < 2
        }
        guard matchingWindows.count == 1, let window = matchingWindows.first else { return nil }
        let selected = (captureRect ?? CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
            .intersection(target.frame)
        guard !selected.isNull, selected.width > 0, selected.height > 0 else { return nil }
        let selectedArea = selected.width * selected.height
        var pending: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var candidates: [ScrollTarget] = []

        while visited < pending.count, visited < 96,
              !cancelled, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = pending[visited]
            visited += 1
            let frame = axFrame(element, deadline: deadline)
            if let frame, !frame.intersects(selected) { continue }
            let role = axAttribute(element, name: kAXRoleAttribute, deadline: deadline) as? String
            if role == kAXScrollAreaRole,
               let frame, frame.width >= 48, frame.height >= 48 {
                let visible = frame.intersection(selected)
                let visibleArea = visible.width * visible.height
                if !visible.isNull, visibleArea > selectedArea * 0.5 {
                    candidates.append(ScrollTarget(
                        location: CGPoint(x: visible.midX, y: visible.midY),
                        area: element,
                        visibleArea: visibleArea,
                        frameArea: frame.width * frame.height
                    ))
                }
            }
            guard depth < 10, pending.count < 96 else { continue }
            let children = axChildren(
                element, attribute: kAXChildrenAttribute,
                limit: min(32, 96 - pending.count), deadline: deadline
            )
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        // More coverage wins; for nested scroll areas showing the same content,
        // use the innermost one rather than its broad container.
        return candidates.sorted {
            if abs($0.visibleArea - $1.visibleArea) > 1 { return $0.visibleArea > $1.visibleArea }
            return $0.frameArea < $1.frameArea
        }.first
    }

    private func axAttribute(_ element: AXUIElement, name: String, deadline: TimeInterval) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !cancelled, remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func axChildren(
        _ element: AXUIElement, attribute: String, limit: Int, deadline: TimeInterval
    ) -> [AXUIElement] {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !cancelled, remaining > 0, limit > 0 else { return [] }
        AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit, &values) == .success,
              let values else { return [] }
        return (values as? [AXUIElement]) ?? []
    }

    private func axFrame(_ element: AXUIElement, deadline: TimeInterval) -> CGRect? {
        guard let position = axAttribute(element, name: kAXPositionAttribute, deadline: deadline),
              CFGetTypeID(position) == AXValueGetTypeID(),
              let size = axAttribute(element, name: kAXSizeAttribute, deadline: deadline),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = position as! AXValue
        let sizeValue = size as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Duplicate images alone cannot distinguish page end from undelivered
    /// input. Only an exposed vertical scrollbar at its maximum confirms it.
    private func hasConfirmedPageEnd() -> Bool {
        guard let targetScrollArea else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let value = axAttribute(targetScrollArea, name: kAXVerticalScrollBarAttribute, deadline: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let scrollbar = value as! AXUIElement
        guard let current = axAttribute(scrollbar, name: kAXValueAttribute, deadline: deadline) as? NSNumber,
              let minimum = axAttribute(scrollbar, name: kAXMinValueAttribute, deadline: deadline) as? NSNumber,
              let maximum = axAttribute(scrollbar, name: kAXMaxValueAttribute, deadline: deadline) as? NSNumber
        else { return false }
        let lower = minimum.doubleValue
        let upper = maximum.doubleValue
        let position = current.doubleValue
        guard lower.isFinite, upper.isFinite, position.isFinite, upper > lower else { return false }
        let tolerance = (upper - lower) * 0.001
        return position >= upper - tolerance && position <= upper + tolerance
    }

    private func runLoop(
        target: TargetWindow,
        application: NSRunningApplication,
        captureStep: @escaping (Int) -> StepResult,
        onFinished: @escaping (FinishReason) -> Void
    ) {
        var stallCount = 0
        var retryCount = 0
        var captureFailureCount = 0
        var consecutiveSuccesses = 0
        var hasProgressed = false
        var postedSteps = 0
        var sampleDelay = settleDelay
        var stalledSince: TimeInterval?
        let minimumStep = min(stepPixels, 12)
        // Prove that the chosen content moves before taking a full-sized step.
        let probeStep = min(stepPixels, max(minimumStep, min(48, stepPixels / 4)))
        var activeStep = probeStep
        var lastDownStep = probeStep
        var captureHint = probeStep
        var nextScrollDelta: Int? = -probeStep
        var isRecovering = false
        var rollbackCount = 0
        var rollbackTotal = 0
        var rollbackBudget = probeStep
        var recoveryForwardCount = 0

        while true {
            if cancelled { return }
            if let delta = nextScrollDelta {
                let failure: FinishReason? = DispatchQueue.main.sync {
                    guard !self.cancelled else { return nil }
                    return self.postScrollStep(
                        target: target,
                        application: application,
                        delta: delta,
                        isFirstStep: postedSteps == 0
                    )
                }
                if cancelled { return }
                if let failure {
                    Self.logger.notice("step rejected afterPosted=\(postedSteps)")
                    finish(failure, onFinished: onFinished)
                    return
                }
                postedSteps += 1
                if delta < 0 {
                    lastDownStep = -delta
                    captureHint = lastDownStep
                    if isRecovering { recoveryForwardCount += 1 }
                } else {
                    captureHint = 0
                }
                nextScrollDelta = nil
            }
            Thread.sleep(forTimeInterval: sampleDelay)
            if cancelled { return }

            switch captureStep(captureHint) {
            case .progressed:
                if !hasProgressed { Self.logger.notice("first content progress afterPosted=\(postedSteps)") }
                hasProgressed = true
                stallCount = 0
                stalledSince = nil
                retryCount = 0
                captureFailureCount = 0
                consecutiveSuccesses += 1
                if consecutiveSuccesses >= 2 {
                    activeStep = min(stepPixels, activeStep + max(minimumStep, activeStep / 2))
                    consecutiveSuccesses = 0
                }
                nextScrollDelta = -activeStep
                sampleDelay = settleDelay
                isRecovering = false
                rollbackCount = 0
                rollbackTotal = 0
                rollbackBudget = activeStep
                recoveryForwardCount = 0
                setRecovering(false)
            case .stalled:
                captureFailureCount = 0
                consecutiveSuccesses = 0
                if isRecovering {
                    // A verified return to the accepted frame permits a smaller
                    // forward attempt. It does not establish the end of the page.
                    retryCount = 0
                    stallCount = 0
                    stalledSince = nil
                    guard recoveryForwardCount < 4 else {
                        finish(.alignmentFailed, onFinished: onFinished)
                        return
                    }
                    nextScrollDelta = -activeStep
                    sampleDelay = max(settleDelay, 0.35)
                    continue
                }
                // The caller has verified that we are back at the accepted
                // frame. A retry sequence cannot contribute to page-end stalls.
                if retryCount > 0 {
                    stallCount = 0
                    stalledSince = nil
                }
                stallCount += 1
                if stalledSince == nil {
                    stalledSince = ProcessInfo.processInfo.systemUptime
                }
                retryCount = 0
                nextScrollDelta = -activeStep
                sampleDelay = max(settleDelay, 0.35)
            case .retry:
                captureFailureCount = 0
                consecutiveSuccesses = 0
                // Sample the same position before attempting any recovery.
                retryCount = min(retryCount + 1, 3)
                stallCount = 0
                stalledSince = nil
                nextScrollDelta = nil
                switch retryCount {
                case 1: sampleDelay = max(settleDelay, 0.25)
                case 2: sampleDelay = max(settleDelay, 0.5)
                default:
                    if !isRecovering { rollbackBudget = lastDownStep }
                    let remainingRollback = rollbackBudget - rollbackTotal
                    guard rollbackCount < 2, remainingRollback > 0,
                          recoveryForwardCount < 4 else {
                        finish(.alignmentFailed, onFinished: onFinished)
                        return
                    }
                    // This limits requested input, not measured document travel.
                    // The original matcher anchor is retained through rollback.
                    let rollback = min(max(1, lastDownStep / 2), remainingRollback)
                    rollbackCount += 1
                    rollbackTotal += rollback
                    activeStep = max(minimumStep, activeStep / 2)
                    retryCount = 0
                    isRecovering = true
                    setRecovering(true)
                    nextScrollDelta = rollback
                    sampleDelay = max(settleDelay, 0.35)
                    Self.logger.notice("recovery rollback=\(rollback) count=\(rollbackCount) total=\(rollbackTotal) nextStep=\(activeStep)")
                }
            case .captureUnavailable:
                // A capture timeout or malformed frame says nothing about the
                // content position. Retry in place and never roll back for it.
                captureFailureCount += 1
                consecutiveSuccesses = 0
                stallCount = 0
                stalledSince = nil
                nextScrollDelta = nil
                guard captureFailureCount < 4 else {
                    finish(.captureUnavailable, onFinished: onFinished)
                    return
                }
                sampleDelay = max(settleDelay, 0.25 * Double(captureFailureCount))
            case .captureFailed:
                finish(.captureUnavailable, onFinished: onFinished)
                return
            case .finished:
                finish(.capacity, onFinished: onFinished)
                return
            }

            if stallCount >= stallThreshold,
               let stalledSince,
               ProcessInfo.processInfo.systemUptime - stalledSince >= 1.5 {
                let reason: FinishReason
                if hasConfirmedPageEnd() {
                    reason = .noNewContent
                } else {
                    reason = hasProgressed ? .movementUnconfirmed : .noProgress
                }
                finish(reason, onFinished: onFinished)
                return
            }
        }
    }

    private func setRecovering(_ recovering: Bool) {
        lock.lock()
        guard !cancelledFlag, recoveringFlag != recovering else {
            lock.unlock()
            return
        }
        recoveringFlag = recovering
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldNotify = !self.cancelledFlag && self.recoveryGeneration == generation
            self.lock.unlock()
            guard shouldNotify else { return }
            Self.logger.notice("recovering=\(recovering)")
            self.onRecoveryChanged?(recovering)
        }
    }

    private func finish(_ reason: FinishReason, onFinished: @escaping (FinishReason) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldNotify = !self.cancelledFlag
            self.cancelledFlag = true
            self.lock.unlock()
            self.removeKeyStopTap()
            guard shouldNotify else { return }
            Self.logger.notice("finished reason=\(String(describing: reason), privacy: .public)")
            onFinished(reason)
        }
    }

    private func postScrollStep(
        target: TargetWindow,
        application: NSRunningApplication,
        delta: Int,
        isFirstStep: Bool
    ) -> FinishReason? {
        guard Self.isPermitted else { return .permissionDenied }
        guard !application.isTerminated,
              application.processIdentifier == ProcessInfo.processInfo.processIdentifier || application.isActive,
              windowAtLocation() == target else { return .targetUnavailable }

        // Build the complete gesture before posting anything, so an allocation
        // failure cannot leave a began gesture without its matching end.
        func makeEvent(delta: Int32, phase: CGScrollPhase) -> CGEvent? {
            guard let eventSource,
                  let event = CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 1,
                wheel1: delta,
                wheel2: 0,
                wheel3: 0
                  ) else { return nil }
            event.flags = []
            event.location = location
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            return event
        }

        guard let began = makeEvent(delta: 0, phase: .began),
              let changed = makeEvent(delta: Int32(delta), phase: .changed),
              let ended = makeEvent(delta: 0, phase: .ended) else {
            return .targetUnavailable
        }

        // Each step is a complete continuous-pixel gesture without momentum.
        // Post all three together on main, including the end if stop() races
        // this step. Wheel events remain untouched by our keyboard-only tap.
        for event in [began, changed, ended] {
            event.post(tap: .cghidEventTap)
        }
        if isFirstStep {
            Self.logger.notice("first scroll gesture posted flags=\(changed.flags.rawValue) continuous=1")
        }
        // CGEventPost has no delivery result. Only the subsequent capture can
        // establish that the receiving content actually moved.
        return nil
    }

    // MARK: - Keyboard Stop

    /// Any new key press finishes capture and is swallowed. Pointer and wheel
    /// events remain untouched, including events replaced by scroll utilities.
    private func installKeyStopTap() -> Bool {
        previousModifierFlags = CGEventSource.flagsState(.combinedSessionState)
        pressedModifierKeys = Set(Self.modifierFlagsByKeyCode.keys.filter {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        })
        let types: [CGEventType] = [.keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let scroller = Unmanaged<AutoScroller>.fromOpaque(refcon).takeUnretainedValue()
                return scroller.handleKeyEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    /// Decides each tapped event's fate. Runs on the main run loop.
    private func handleKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        guard !cancelled else { return passthrough }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return passthrough

        case .keyDown:
            break
        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let previousFlags = previousModifierFlags
            previousModifierFlags = event.flags
            if keyCode == CGKeyCode(kVK_CapsLock) {
                // Caps Lock toggling off is also a key press.
                guard event.flags.contains(.maskAlphaShift) != previousFlags.contains(.maskAlphaShift)
                else { return passthrough }
            } else {
                guard let flag = Self.modifierFlagsByKeyCode[keyCode] else { return passthrough }
                // Track individual left/right keys: releasing a startup hotkey
                // must pass, but pressing the other side of a held group stops.
                if pressedModifierKeys.remove(keyCode) != nil { return passthrough }
                guard event.flags.contains(flag) else { return passthrough }
                pressedModifierKeys.insert(keyCode)
            }
        default:
            return passthrough
        }

        lock.lock()
        let wasCancelled = cancelledFlag
        cancelledFlag = true
        keyFinishPending = !wasCancelled
        lock.unlock()

        if !wasCancelled {
            Self.logger.notice("stopped by key code=\(event.getIntegerValueField(.keyboardEventKeycode))")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.removeKeyStopTap()
                self.lock.lock()
                let shouldNotify = self.keyFinishPending
                self.keyFinishPending = false
                self.lock.unlock()
                guard shouldNotify else { return }
                self.onKeyPressed?()
            }
        }
        return nil
    }

    private func removeKeyStopTapOnMain() {
        if Thread.isMainThread {
            removeKeyStopTap()
        } else {
            DispatchQueue.main.async {
                self.removeKeyStopTap()
            }
        }
    }

    private func removeKeyStopTap() {
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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }
}
