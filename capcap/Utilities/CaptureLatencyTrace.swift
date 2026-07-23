import Foundation
import os.signpost

/// Carries one screenshot trigger's identity and monotonic event timestamp
/// across callback, run-loop, capture preparation, and overlay presentation.
struct CaptureTriggerContext: @unchecked Sendable {
    enum Source: String, Sendable {
        case keyboardShortcut = "keyboard-shortcut"
        case doubleCommand = "double-command"
        case menu
        case countdown
        case programmatic
    }

    let sessionID: UUID
    let source: Source
    let eventUptime: TimeInterval
    let trace: CaptureLatencyTrace

    init(
        source: Source,
        eventUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let sessionID = UUID()
        self.sessionID = sessionID
        self.source = source
        self.eventUptime = eventUptime
        self.trace = CaptureLatencyTrace(
            sessionID: sessionID,
            source: source,
            eventUptime: eventUptime
        )
    }

    func mark(_ stage: CaptureLatencyTrace.Stage) {
        trace.mark(stage)
    }

    func finish(_ outcome: CaptureLatencyTrace.Outcome) {
        trace.finish(outcome)
    }
}

/// Low-overhead signpost trace for the user-visible screenshot startup path.
/// DiagnosticLog is intentionally touched only after `finish`, on a dedicated
/// background queue, so synchronous file I/O can never delay the first frame.
final class CaptureLatencyTrace: @unchecked Sendable {
    enum Stage: String, Sendable {
        case carbonEventReceived = "carbon-event-received"
        case doubleCommandDetected = "double-command-detected"
        case mainRunLoopCallback = "main-run-loop-callback"
        case handleTrigger = "handle-trigger"
        case startCapture = "start-capture"
        case overlayInitialized = "overlay-initialized"
        case activateRequested = "activate-requested"
        case backgroundPreparationStarted = "background-preparation-started"
        case windowEnumerationReady = "window-enumeration-ready"
        case windowEnumerationApplied = "window-enumeration-applied"
        case snapshotCaptureStarted = "snapshot-capture-started"
        case snapshotResultReady = "snapshot-result-ready"
        case snapshotResultApplied = "snapshot-result-applied"
        case overlayOrderedFront = "overlay-ordered-front"
        case firstDrawCompleted = "first-draw-completed"
        case firstFrame = "first-frame"
    }

    enum Outcome: String, Sendable {
        case presented
        case cancelled
        case superseded
        case failed
        case ignored
        case rerouted
    }

    private struct StageSample {
        let stage: Stage
        let uptime: TimeInterval
        let thread: String
    }

    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.capcap.capture",
        category: "CaptureLatency"
    )
    private static let diagnosticQueue = DispatchQueue(
        label: "com.capcap.capture-latency-log",
        qos: .utility
    )

    let sessionID: UUID
    let source: CaptureTriggerContext.Source
    let eventUptime: TimeInterval

    private let signpostID: OSSignpostID
    private let lock = NSLock()
    private var samples: [StageSample] = []
    private var isFinished = false

    init(
        sessionID: UUID,
        source: CaptureTriggerContext.Source,
        eventUptime: TimeInterval
    ) {
        self.sessionID = sessionID
        self.source = source
        self.eventUptime = eventUptime
        self.signpostID = OSSignpostID(log: Self.signpostLog)

        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "CaptureTrigger",
            signpostID: signpostID,
            "session=%{public}@ source=%{public}@ eventUptime=%.6f",
            sessionID.uuidString,
            source.rawValue,
            eventUptime
        )
    }

    func mark(_ stage: Stage) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsedMs = max(0, now - eventUptime) * 1_000

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        samples.append(
            StageSample(
                stage: stage,
                uptime: now,
                thread: Thread.isMainThread ? "main" : "background"
            )
        )
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "CaptureStage",
            signpostID: signpostID,
            "session=%{public}@ source=%{public}@ stage=%{public}@ elapsedMs=%.1f",
            sessionID.uuidString,
            source.rawValue,
            stage.rawValue,
            elapsedMs
        )
        lock.unlock()
    }

    func finish(_ outcome: Outcome) {
        let finishedUptime = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let completedSamples = samples
        lock.unlock()

        let totalMs = max(0, finishedUptime - eventUptime) * 1_000
        os_signpost(
            .end,
            log: Self.signpostLog,
            name: "CaptureTrigger",
            signpostID: signpostID,
            "session=%{public}@ source=%{public}@ outcome=%{public}@ totalMs=%.1f",
            sessionID.uuidString,
            source.rawValue,
            outcome.rawValue,
            totalMs
        )

        let stageSummary = completedSamples.map { sample in
            let elapsedMs = max(0, sample.uptime - eventUptime) * 1_000
            return "\(sample.stage.rawValue)=\(String(format: "%.1f", elapsedMs))@\(sample.thread)"
        }.joined(separator: ",")
        let metadata: [String: Any] = [
            "session": sessionID.uuidString,
            "source": source.rawValue,
            "eventUptime": String(format: "%.6f", eventUptime),
            "outcome": outcome.rawValue,
            "totalMs": String(format: "%.1f", totalMs),
            "stages": stageSummary,
        ]

        Self.diagnosticQueue.async {
            DiagnosticLog.log("capture-latency", "trace-finished", metadata: metadata)
        }
    }
}
