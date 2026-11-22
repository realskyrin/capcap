import AppKit

final class ScrollCapturer {
    /// Installed and invoked on the main thread.
    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let screen: NSScreen
    private let excludedWindowNumbers: [CGWindowID]
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let automaticSettleWindow: TimeInterval = 0.45
    private let settledCaptureTimeout: TimeInterval = 1.5
    private let stitcher = ScrollImageStitcher()
    private var isFinished = false
    private var finalImage: NSImage?
    private var isIncomplete = false

    init?(rect: CGRect, screen: NSScreen, excludingWindowNumbers: [CGWindowID] = []) {
        captureRect = rect
        self.screen = screen
        excludedWindowNumbers = excludingWindowNumbers

        guard let image = captureViewport(timeout: 3), stitcher.append(image) == .appended else { return nil }
        publishPreview()
    }

    func stopAndStitch(captureFinalFrame: Bool = true, completion: @escaping (NSImage?, Bool) -> Void) {
        captureQueue.async {
            if !self.isFinished {
                if captureFinalFrame {
                    _ = self.captureFrame(
                        expectedShiftPoints: 0, settleWindow: self.settledCaptureTimeout, updatePreview: false
                    )
                }
                self.finalImage = self.stitcher.takeImage()
                self.isFinished = true
            }
            let image = self.finalImage
            let incomplete = self.isIncomplete
            DispatchQueue.main.async { completion(image, incomplete) }
        }
    }

    func captureSynchronously(automaticStepPoints: CGFloat? = nil) -> ScrollFrameOutcome {
        captureQueue.sync {
            guard !isFinished else { return .atFrameLimit }
            return autoreleasepool {
                captureFrame(
                    expectedShiftPoints: automaticStepPoints ?? 0,
                    settleWindow: automaticStepPoints == nil ? 0 : automaticSettleWindow, updatePreview: true
                )
            }
        }
    }

    private func captureFrame(
        expectedShiftPoints: CGFloat, settleWindow: TimeInterval, updatePreview: Bool
    ) -> ScrollFrameOutcome {
        guard !stitcher.reachedFrameLimit else {
            isIncomplete = true
            return .atFrameLimit
        }
        // A trackpad can move more than a viewport while waiting for two
        // identical frames. Sample manual motion immediately and verify the overlap.
        let waitForSettlement = settleWindow > 0
        let sample = waitForSettlement
            ? captureSettledFrame(settleWindow: settleWindow)
            : captureViewport(timeout: settledCaptureTimeout)
        guard let image = sample else {
            isIncomplete = true
            return .unmatched
        }
        let outcome = stitcher.append(image, expectedShiftPoints: expectedShiftPoints)
        isIncomplete = outcome == .unmatched || outcome == .atFrameLimit
        if updatePreview && outcome == .appended { publishPreview() }
        if stitcher.reachedFrameLimit {
            isIncomplete = true
            return .atFrameLimit
        }
        return outcome
    }

    private func publishPreview() {
        guard let thumbnail = stitcher.thumbnail() else { return }
        DispatchQueue.main.async { [weak self] in self?.onPreviewUpdated?(thumbnail) }
    }

    private func captureViewport(timeout: TimeInterval) -> NSImage? {
        ScreenCapturer.capture(
            rect: captureRect, screen: screen, excludingWindowNumbers: excludedWindowNumbers, timeout: timeout
        )
    }

    /// Returns identical consecutive captures early, or uses the latest sample
    /// after the settle window. The first successful sample gets the full timeout.
    private func captureSettledFrame(settleWindow: TimeInterval) -> NSImage? {
        var previousData: Data? = nil
        var lastImage: NSImage? = nil
        var waitNs: UInt64 = 12_000_000   // start polling at 12ms
        let start = ProcessInfo.processInfo.systemUptime
        let settleDeadline = start + settleWindow
        let captureDeadline = start + settledCaptureTimeout
        func remainingTime() -> TimeInterval {
            let deadline = lastImage == nil ? captureDeadline : settleDeadline
            return deadline - ProcessInfo.processInfo.systemUptime
        }

        while true {
            let remaining = remainingTime()
            guard remaining > 0 else { break }
            guard let image = captureViewport(timeout: remaining) else {
                sleepUntilDeadline(min(0.03, remainingTime()))
                continue
            }

            // Compare raw pixel bytes from the CGImage's data provider —
            // a deterministic per-pixel signature. Two consecutive identical
            // signatures mean the compositor isn't drawing anything new, so
            // the page is settled. Using raw bytes avoids the encode /
            // compress overhead of tiffRepresentation, which matters on
            // high-DPI displays where the loop runs many times per step.
            let signature = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?
                .dataProvider?.data as Data?

            if let prev = previousData, prev == signature {
                return image
            }

            previousData = signature
            lastImage = image
            sleepUntilDeadline(min(Double(waitNs) / 1_000_000_000, remainingTime()))
            // Geometric backoff so we don't busy-poll for long animations.
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        // A page with animations may never settle. The matcher still has to
        // verify this sample against the last accepted viewport.
        return lastImage
    }

    private func sleepUntilDeadline(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}
