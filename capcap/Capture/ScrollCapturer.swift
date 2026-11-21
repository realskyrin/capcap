import AppKit
import OSLog

final class ScrollCapturer {
    private static let logger = Logger(subsystem: "cn.skyrin.capcap", category: "ScrollCapture")
    private struct ImageFormat {
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let bitmapInfo: CGBitmapInfo
        let colorSpace: CGColorSpace
    }

    private struct CapturedFrame {
        let image: NSImage
        let bitmap: BitmapData
    }

    struct StitchResult {
        let image: NSImage?
        let isIncomplete: Bool
    }

    /// Result of a single capture attempt, used by auto-scroll to decide
    /// whether the page kept producing fresh content or has bottomed out.
    enum FrameOutcome {
        /// A new frame with fresh content was stitched in.
        case appended
        /// The visible content has not advanced beyond the last accepted frame.
        case noNewContent
        /// Alignment failed; retry without scrolling farther.
        case retry
        /// No usable capture was obtained; this is not evidence to roll back.
        case captureUnavailable
        /// The capture source has terminated; preserve the partial result.
        case captureFailed
        /// The output bitmap budget is exhausted; capturing should stop.
        case atCapacity
    }

    var onPreviewUpdated: ((NSImage) -> Void)? {
        get {
            previewDeliveryLock.lock()
            defer { previewDeliveryLock.unlock() }
            return previewCallback
        }
        set {
            previewDeliveryLock.lock()
            previewCallback = newValue
            previewDeliveryGeneration &+= 1
            pendingPreviewImage = nil
            previewDeliveryLock.unlock()
        }
    }

    private let previewDeliveryLock = NSLock()
    private var previewCallback: ((NSImage) -> Void)?
    private var pendingPreviewImage: NSImage?
    private var previewDeliveryScheduled = false
    private var previewDeliveryGeneration: UInt = 0
    private var previewUpdatesFinished = false

    private let captureRect: CGRect
    private let screen: NSScreen
    /// capcap's own scroll-capture chrome (e.g. the hint toast) — excluded
    /// from every captured frame so it never appears in the stitched image.
    private let excludedWindowNumbers: [CGWindowID]
    private let captureFrameImage: (() -> NSImage?)?
    private let usesFrameStream: Bool
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let maximumBitmapBytes = 256 * 1024 * 1024
    private let maximumImageHeight = 100_000
    private let initialCaptureTimeout: TimeInterval = 3.0
    private let settledCaptureTimeout: TimeInterval = 1.5

    private var firstFrameImage: NSImage?
    private var lastAcceptedFrame: CapturedFrame?
    private let frameMatcher = ScrollFrameMatcher()
    private var hasUnmatchedContent = false
    private var lastReportedFailure: String?
    private var isFinished = false
    private var frameStream: (any ScrollFrameSource)?
    private var captureStreamFailed = false
    private var consumedFrameSequence: UInt64 = 0
    private var unmatchedFrameSequences = Set<UInt64>()

    // Incremental preview state
    private var previewBitmap: BitmapData?
    private var previewHeightPixels: Int = 0
    private var previewScale: CGFloat = 1
    private var previewPointWidth: CGFloat = 0
    private var previewRightInsetPixels = 0

    init(
        rect: CGRect,
        screen: NSScreen,
        excludingWindowNumbers: [CGWindowID] = [],
        onPreviewUpdated: ((NSImage) -> Void)? = nil,
        capturesInitialFrame: Bool = true,
        captureImage: (() -> NSImage?)? = nil,
        frameSource: (any ScrollFrameSource)? = nil
    ) {
        self.captureRect = rect
        self.screen = screen
        self.excludedWindowNumbers = excludingWindowNumbers
        self.previewCallback = onPreviewUpdated
        self.captureFrameImage = captureImage
        self.frameStream = frameSource
        self.usesFrameStream = frameSource != nil || captureImage == nil

        if capturesInitialFrame {
            captureQueue.sync {
                _ = captureFrame(expectedShiftPoints: 0, waitsForSettledFrame: false)
            }
        }
    }

    deinit {
        frameStream?.stop()
    }

    /// Automatic mode calls this after activation and pointer routing settle,
    /// before sending any scroll input. Never replace an established anchor.
    func prepareInitialFrameSynchronously() -> Bool {
        captureQueue.sync {
            guard !isFinished else { return false }
            if lastAcceptedFrame != nil { return previewBitmap != nil }
            _ = captureFrame(expectedShiftPoints: 0)
            guard let frame = lastAcceptedFrame else {
                Self.logger.error("prepared initial frame unavailable")
                return false
            }
            Self.logger.notice("prepared initial frame width=\(frame.bitmap.width) height=\(frame.bitmap.height)")
            return true
        }
    }

    private func acceptInitialFrame(_ frame: CapturedFrame) -> Bool {
        guard initPreview(from: frame) else { return false }
        firstFrameImage = frame.image
        lastAcceptedFrame = frame
        hasUnmatchedContent = false
        lastReportedFailure = nil
        return true
    }

    func stopAndStitch(completion: @escaping (StitchResult) -> Void) {
        // Invalidate queued UI work before waiting for the final sample. The
        // tail is composed at full quality, but needs no intermediate preview.
        previewDeliveryLock.lock()
        previewUpdatesFinished = true
        previewCallback = nil
        pendingPreviewImage = nil
        previewDeliveryGeneration &+= 1
        previewDeliveryLock.unlock()

        captureQueue.async {
            // One last frame so the final scrolled state is never missed.
            self.captureFrame(expectedShiftPoints: 0)
            if self.usesFrameStream {
                // The last input can arrive between stream deliveries. Query
                // the compositor once at stop instead of silently accepting a
                // cached frame as proof that the tail has already been seen.
                let finalImage = self.captureSingleFrame(timeout: self.settledCaptureTimeout)
                _ = self.processFrame(self.normalizedStreamImage(finalImage), expectedShiftPoints: 0)
            }
            self.isFinished = true
            self.frameStream?.stop()
            self.frameStream = nil
            let image = self.stitchedImage()
            let result = StitchResult(
                image: image ?? self.firstFrameImage,
                isIncomplete: self.captureStreamFailed || self.hasUnmatchedContent || image == nil
            )
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Captures a frame synchronously and reports the outcome. Used by the
    /// auto-scroll loop: it scrolls a fixed step, then calls this to learn
    /// whether the step revealed new content (keep going) or not (page end).
    func captureSynchronously(
        expectedShiftPoints: CGFloat,
        waitsForSettledFrame: Bool = true
    ) -> FrameOutcome {
        var outcome: FrameOutcome = .noNewContent
        captureQueue.sync {
            outcome = captureFrame(
                expectedShiftPoints: expectedShiftPoints,
                waitsForSettledFrame: waitsForSettledFrame
            )
        }
        return outcome
    }

    /// Synchronous injected sources retain the settling helper. Live capture
    /// uses a continuous stream and validates motion without waiting for every
    /// pixel (including blinking cursors and animations) to become identical.
    /// Captures a frame, polling until two consecutive captures produce
    /// byte-identical raw pixel data (the page has stopped re-rendering)
    /// or a timeout elapses. This guards the Vision-based overlap detector
    /// against measuring an in-progress smooth-scroll animation — without
    /// it, fast synthetic scrolls catch the page mid-render and Vision
    /// reports partial offsets that defeat the stitching loop.
    ///
    /// Returns the settled image, or the most-recent capture if settlement
    /// times out (so the loop still progresses rather than failing hard).
    private func captureSettledFrame() -> NSImage? {
        var previousData: Data? = nil
        var lastImage: NSImage? = nil
        var waitNs: UInt64 = 12_000_000   // start polling at 12ms
        let deadline = Date().addingTimeInterval(settledCaptureTimeout)

        // ~20 iterations × 12–80ms backoff ≈ up to ~1s total wait, which is
        // more than enough for typical smooth-scroll animations (150–300ms).
        for _ in 0..<20 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let image = captureSingleFrame(timeout: remaining) else {
                sleepUntilDeadline(min(0.03, deadline.timeIntervalSinceNow))
                continue
            }

            // Compare raw pixel bytes from the CGImage's data provider —
            // a deterministic per-pixel signature. Two consecutive identical
            // signatures mean the compositor isn't drawing anything new, so
            // the page is settled. Using raw bytes avoids the encode /
            // compress overhead of tiffRepresentation, which matters on
            // high-DPI displays where the loop runs many times per step.
            guard
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                let signature = cgImage.dataProvider?.data as Data?
            else {
                sleepUntilDeadline(min(Double(waitNs) / 1_000_000_000, deadline.timeIntervalSinceNow))
                continue
            }

            if let prev = previousData, prev == signature {
                return image
            }

            previousData = signature
            lastImage = image
            sleepUntilDeadline(min(Double(waitNs) / 1_000_000_000, deadline.timeIntervalSinceNow))
            // Geometric backoff so we don't busy-poll for long animations.
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        // Animated content may never become byte-identical. The overlap
        // verifier still has to validate this frame before it can be appended.
        return lastImage
    }

    private func sleepUntilDeadline(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }

    private func captureSingleFrame(timeout: TimeInterval) -> NSImage? {
        if let captureFrameImage { return captureFrameImage() }
        return ScreenCapturer.capture(
            rect: captureRect,
            screen: screen,
            excludingWindowNumbers: excludedWindowNumbers,
            timeout: timeout
        )
    }

    @discardableResult
    private func captureFrame(
        expectedShiftPoints: CGFloat,
        waitsForSettledFrame: Bool = true
    ) -> FrameOutcome {
        guard !isFinished else { return .noNewContent }
        guard !captureStreamFailed else { return .captureFailed }
        if !usesFrameStream {
            let image = waitsForSettledFrame
                ? captureSettledFrame()
                : captureSingleFrame(timeout: settledCaptureTimeout)
            return processFrame(image, expectedShiftPoints: expectedShiftPoints)
        }
        if frameStream == nil {
            frameStream = ScrollFrameStream(
                rect: captureRect,
                displayID: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                scale: max(screen.backingScaleFactor, 1),
                excludingWindowNumbers: excludedWindowNumbers + ToastWindow.captureExcludedWindowNumbers
            )
        }
        guard let stream = frameStream else { return .captureUnavailable }
        let snapshot = stream.snapshot(
            after: consumedFrameSequence,
            timeout: lastAcceptedFrame == nil ? initialCaptureTimeout : 0.2,
            waitsForNewFrame: waitsForSettledFrame
        )
        let frames: [ScrollFrameStream.Frame]
        switch snapshot {
        case .frames(let available):
            frames = available
        case .unavailable:
            return processFrame(nil, expectedShiftPoints: expectedShiftPoints)
        case .failed:
            captureStreamFailed = true
            hasUnmatchedContent = true
            stream.stop()
            return .captureFailed
        }
        guard let newest = frames.last else {
            return processFrame(nil, expectedShiftPoints: expectedShiftPoints)
        }
        if newest.sequence == consumedFrameSequence { return .noNewContent }
        unmatchedFrameSequences.formIntersection(Set(frames.map(\.sequence)))

        var remaining = frames
        if lastAcceptedFrame == nil, let first = remaining.first {
            let outcome = processStreamFrame(first, expectedShiftPoints: 0)
            guard case .appended = outcome else { return outcome }
            consumedFrameSequence = first.sequence
            stream.discard(through: first.sequence)
            remaining.removeFirst()
            if remaining.isEmpty { return .appended }
        }

        // Prefer the newest frame to keep latency down. If it cannot connect,
        // walk back through the retained intermediate frames, never rebasing
        // the output on an unverified image. Every accepted bridge is stitched
        // before another candidate may advance the anchor.
        var attempts = 0
        var appendedBridge = false
        while !remaining.isEmpty, attempts < 6 {
            // Matchability is not monotonic: an animated middle frame can
            // fail while a later frame overlaps perfectly. Try every retained
            // frame across calls instead of binary-searching past a bridge.
            let index: Int
            if !unmatchedFrameSequences.contains(newest.sequence) {
                index = remaining.count - 1
            } else if let untried = remaining.firstIndex(where: { !unmatchedFrameSequences.contains($0.sequence) }) {
                index = untried
            } else {
                break
            }
            attempts += 1
            let frame = remaining[index]
            let outcome = processStreamFrame(frame, expectedShiftPoints: expectedShiftPoints)
            switch outcome {
            case .appended, .noNewContent:
                if case .appended = outcome {
                    appendedBridge = true
                    // The anchor moved, so rejected later frames may now fit.
                    unmatchedFrameSequences.removeAll()
                }
                consumedFrameSequence = frame.sequence
                stream.discard(through: frame.sequence)
                if frame.sequence == newest.sequence { return appendedBridge ? .appended : outcome }
                remaining.removeFirst(index + 1)
            case .retry:
                unmatchedFrameSequences.insert(frame.sequence)
            case .captureUnavailable, .captureFailed, .atCapacity:
                return outcome
            }
        }
        // A bridge may have been accepted while the newest content is still
        // disconnected. Auto-scroll must not post another downward step yet.
        hasUnmatchedContent = true
        return .retry
    }

    private func processStreamFrame(_ frame: ScrollFrameStream.Frame, expectedShiftPoints: CGFloat) -> FrameOutcome {
        let image = NSImage(cgImage: frame.image, size: captureRect.size)
        return processFrame(image, expectedShiftPoints: expectedShiftPoints)
    }

    private func processFrame(_ image: NSImage?, expectedShiftPoints: CGFloat) -> FrameOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        var status = "capture-failed"
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            // Persist the first failure and changes of cause without logging
            // every sample while an unresolved frame is being retried.
            if hasUnmatchedContent && lastReportedFailure != status {
                Self.logger.notice("sample failure=\(status, privacy: .public) output=\(self.previewHeightPixels) processingMs=\(elapsed)")
            } else {
                Self.logger.debug("sample status=\(status, privacy: .public) output=\(self.previewHeightPixels) processingMs=\(elapsed)")
            }
            lastReportedFailure = hasUnmatchedContent ? status : nil
        }
        guard
            let image,
            let bitmap = bitmapData(from: image)
        else {
            hasUnmatchedContent = true
            return .captureUnavailable
        }

        let candidateFrame = CapturedFrame(image: image, bitmap: bitmap)

        guard let previousFrame = lastAcceptedFrame else {
            guard acceptInitialFrame(candidateFrame) else {
                hasUnmatchedContent = true
                status = "initial-buffer-failed"
                return .captureUnavailable
            }
            status = "initial"
            return .appended
        }
        guard previousFrame.bitmap.width == bitmap.width,
              previousFrame.bitmap.height == bitmap.height,
              previousFrame.bitmap.imageFormat.bitsPerComponent == bitmap.imageFormat.bitsPerComponent,
              previousFrame.bitmap.imageFormat.bitsPerPixel == bitmap.imageFormat.bitsPerPixel,
              previousFrame.bitmap.imageFormat.bitmapInfo == bitmap.imageFormat.bitmapInfo,
              let previousCG = previousFrame.bitmap.rep.cgImage,
              let currentCG = bitmap.rep.cgImage else {
            hasUnmatchedContent = true
            status = "format-changed"
            return .captureUnavailable
        }
        let pixelScale = CGFloat(bitmap.height) / max(image.size.height, 1)
        let expectedShift = expectedShiftPoints > 0 ? expectedShiftPoints * pixelScale : nil
        switch frameMatcher.match(previous: previousCG, current: currentCG, expectedShift: expectedShift) {
        case .unchanged:
            hasUnmatchedContent = false
            status = "unchanged"
            return .noNewContent
        case .unmatched:
            // Keep the last accepted frame as the anchor. Manual scrolling
            // back into overlap can recover without ever stitching a gap.
            hasUnmatchedContent = true
            status = "unmatched"
            return .retry
        case .aligned(let alignment):
            let sourceStart = bitmap.height - alignment.fixedBottom - alignment.shift
            guard alignment.shift > 0,
                  alignment.fixedTop >= 0,
                  alignment.fixedBottom >= 0,
                  alignment.fixedBottom < bitmap.height,
                  sourceStart >= alignment.fixedTop,
                  sourceStart > 0 else {
                hasUnmatchedContent = true
                status = "invalid-alignment"
                return .retry
            }
            let rightInset: Int
            if previewRightInsetPixels == 0 {
                rightInset = ScrollCaptureChrome.contentRightInset(
                    previous: previousCG, current: currentCG,
                    shift: alignment.shift, scale: pixelScale
                )
            } else {
                rightInset = previewRightInsetPixels
            }
            guard appendToPreview(bitmap, alignment: alignment, rightInset: rightInset) else {
                hasUnmatchedContent = true
                status = "append-failed"
                return previewHeightPixels + alignment.shift > maximumHeight(for: bitmap) ? .atCapacity : .captureUnavailable
            }
            lastAcceptedFrame = candidateFrame
            hasUnmatchedContent = false
            status = "appended-\(alignment.shift)-top-\(alignment.fixedTop)-bottom-\(alignment.fixedBottom)"
            return .appended
        }
    }

    // MARK: - Incremental Preview

    private func initPreview(from frame: CapturedFrame) -> Bool {
        let initialCapacity = min(frame.bitmap.height * 2, maximumHeight(for: frame.bitmap))
        guard initialCapacity >= frame.bitmap.height else { return false }
        guard let output = makeOutputBitmap(
            from: frame.bitmap,
            totalHeightPixels: initialCapacity
        ) else { return false }

        copyRows(
            from: frame.bitmap,
            sourceStartRow: 0,
            rowCount: frame.bitmap.height,
            to: output,
            destinationStartRow: 0
        )

        previewScale = CGFloat(frame.bitmap.height) / max(frame.image.size.height, 1)
        previewPointWidth = frame.image.size.width
        previewBitmap = output
        previewHeightPixels = frame.bitmap.height
        emitPreviewImage()
        return true
    }

    private func appendToPreview(_ bitmap: BitmapData, alignment: ScrollFrameMatcher.Alignment, rightInset: Int) -> Bool {
        guard var previewBitmap else { return false }
        let overlapEnd = bitmap.height - alignment.fixedBottom - alignment.shift
        // Join inside the verified overlap and replace the old lower tail.
        // A rounded viewport clips only the sides of its last document rows:
        // these rows are not a wholly stationary footer, but must still be
        // replaced with unobscured content from the next frame. Joining at the
        // old bottom would bake those corners into the middle of the result.
        let sourceStart = alignment.fixedTop + (overlapEnd - alignment.fixedTop) / 2
        let destinationStart = previewHeightPixels - bitmap.height + sourceStart + alignment.shift
        let rowsToCopy = bitmap.height - sourceStart
        let neededHeight = destinationStart + rowsToCopy
        guard neededHeight <= maximumHeight(for: bitmap) else { return false }
        if neededHeight > previewBitmap.height {
            let newCapacity = min(neededHeight + bitmap.height * 2, maximumHeight(for: bitmap))
            guard let grown = makeOutputBitmap(
                from: bitmap,
                totalHeightPixels: newCapacity
            ) else { return false }
            copyRows(
                from: previewBitmap,
                sourceStartRow: 0,
                rowCount: previewHeightPixels,
                to: grown,
                destinationStartRow: 0
            )
            self.previewBitmap = grown
            previewBitmap = grown
        }

        copyRows(
            from: bitmap,
            sourceStartRow: sourceStart,
            rowCount: rowsToCopy,
            to: previewBitmap,
            destinationStartRow: destinationStart
        )
        previewHeightPixels = neededHeight
        previewRightInsetPixels = rightInset
        emitPreviewImage()
        return true
    }

    private func emitPreviewImage() {
        previewDeliveryLock.lock()
        let generation = previewDeliveryGeneration
        let needsPreview = !previewUpdatesFinished && previewCallback != nil
        previewDeliveryLock.unlock()
        guard needsPreview, let image = previewThumbnail() else { return }

        previewDeliveryLock.lock()
        guard !previewUpdatesFinished,
              previewCallback != nil,
              generation == previewDeliveryGeneration else {
            previewDeliveryLock.unlock()
            return
        }
        pendingPreviewImage = image
        let shouldSchedule = !previewDeliveryScheduled
        previewDeliveryScheduled = true
        previewDeliveryLock.unlock()
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewDeliveryLock.lock()
            let image = self.pendingPreviewImage
            let callback = self.previewCallback
            self.pendingPreviewImage = nil
            self.previewDeliveryScheduled = false
            self.previewDeliveryLock.unlock()
            if let image { callback?(image) }
        }
    }

    private func previewThumbnail() -> NSImage? {
        guard let previewBitmap, previewHeightPixels > 0 else { return nil }
        let contentWidth = previewBitmap.width - previewRightInsetPixels
        guard contentWidth > 0 else { return nil }
        let scale = min(1, min(240 / CGFloat(contentWidth), 800 / CGFloat(previewHeightPixels)))
        let width = max(1, Int((CGFloat(contentWidth) * scale).rounded(.down)))
        let height = max(1, Int((CGFloat(previewHeightPixels) * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // This image only borrows the canvas while captureQueue is drawing
        // synchronously. No large Data snapshot or borrowed image escapes;
        // the returned thumbnail owns the small context's independent pixels.
        return withExtendedLifetime(previewBitmap) {
            guard let provider = CGDataProvider(
                dataInfo: nil,
                data: previewBitmap.data,
                size: previewHeightPixels * previewBitmap.bytesPerRow,
                releaseData: { _, _, _ in }
            ), let source = CGImage(
                width: contentWidth,
                height: previewHeightPixels,
                bitsPerComponent: previewBitmap.imageFormat.bitsPerComponent,
                bitsPerPixel: previewBitmap.imageFormat.bitsPerPixel,
                bytesPerRow: previewBitmap.bytesPerRow,
                space: previewBitmap.imageFormat.colorSpace,
                bitmapInfo: previewBitmap.imageFormat.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let thumbnail = context.makeImage() else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(
                width: previewPointWidth - CGFloat(previewRightInsetPixels) / previewScale,
                height: CGFloat(previewHeightPixels) / previewScale
            ))
        }
    }

    // MARK: - Final Stitch

    private func stitchedImage() -> NSImage? {
        // Preview and export share one authoritative canvas, including every
        // accepted footer replacement. Only the last source frame is retained
        // for matching; slow manual scrolling cannot exhaust a frame counter.
        guard let previewBitmap, previewHeightPixels > 0 else { return nil }
        guard let raster = previewBitmap.makeCGImage(pixelHeight: previewHeightPixels) else { return nil }
        let image: CGImage
        if previewRightInsetPixels > 0 {
            guard let cropped = raster.cropping(to: CGRect(
                x: 0, y: 0, width: raster.width - previewRightInsetPixels, height: raster.height
            )) else { return nil }
            image = cropped
        } else {
            image = raster
        }
        return NSImage(cgImage: image, size: NSSize(
            width: previewPointWidth - CGFloat(previewRightInsetPixels) / previewScale,
            height: CGFloat(previewHeightPixels) / previewScale
        ))
    }

    // MARK: - Image Helpers

    /// ScreenshotManager can choose a different pixel layout than SCStream.
    /// Normalize only the final still so format differences cannot prevent a
    /// valid last overlap from being appended to the continuous capture.
    private func normalizedStreamImage(_ image: NSImage?) -> NSImage? {
        guard let image, let source = image.cgImagePreservingBacking(),
              let context = CGContext(
                data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let normalized = context.makeImage() else { return nil }
        return NSImage(cgImage: normalized, size: image.size)
    }

    private func bitmapData(from image: NSImage) -> BitmapData? {
        guard let rep = image.bitmapImageRepPreservingBacking() else { return nil }
        return BitmapData(rep: rep)
    }

    private func makeOutputBitmap(from source: BitmapData, totalHeightPixels: Int) -> BitmapData? {
        guard totalHeightPixels > 0, totalHeightPixels <= maximumHeight(for: source) else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: totalHeightPixels,
            bitsPerSample: source.rep.bitsPerSample,
            samplesPerPixel: source.rep.samplesPerPixel,
            hasAlpha: source.rep.hasAlpha,
            isPlanar: false,
            colorSpaceName: source.rep.colorSpaceName,
            bitmapFormat: source.rep.bitmapFormat,
            bytesPerRow: source.bytesPerRow,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        return BitmapData(rep: rep, format: source.imageFormat)
    }

    private func maximumHeight(for bitmap: BitmapData) -> Int {
        min(maximumImageHeight, maximumBitmapBytes / max(1, bitmap.bytesPerRow))
    }

    private func copyRows(
        from source: BitmapData,
        sourceStartRow: Int,
        rowCount: Int,
        to destination: BitmapData,
        destinationStartRow: Int
    ) {
        guard rowCount > 0 else { return }

        let bytesPerRow = min(source.width * source.bytesPerPixelValue, min(source.bytesPerRow, destination.bytesPerRow))

        for rowOffset in 0..<rowCount {
            let sourceOffset = (sourceStartRow + rowOffset) * source.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * destination.bytesPerRow
            memcpy(
                destination.data.advanced(by: destinationOffset),
                source.data.advanced(by: sourceOffset),
                bytesPerRow
            )
        }
    }

    private final class BitmapData {
        let rep: NSBitmapImageRep
        let data: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let imageFormat: ImageFormat
        private let bytesPerPixel: Int

        init?(rep: NSBitmapImageRep, format: ImageFormat? = nil) {
            guard let data = rep.bitmapData else { return nil }

            let resolvedFormat: ImageFormat
            if let format {
                resolvedFormat = format
            } else {
                let cgImage = rep.cgImage
                guard
                    let cgImage,
                    let colorSpace = cgImage.colorSpace
                else {
                    return nil
                }

                resolvedFormat = ImageFormat(
                    bitsPerComponent: cgImage.bitsPerComponent,
                    bitsPerPixel: cgImage.bitsPerPixel,
                    bitmapInfo: cgImage.bitmapInfo,
                    colorSpace: colorSpace
                )
            }

            self.rep = rep
            self.data = data
            self.bytesPerRow = rep.bytesPerRow
            self.width = rep.pixelsWide
            self.height = rep.pixelsHigh
            self.imageFormat = resolvedFormat
            self.bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        }

        func makeImage(pointSize: NSSize, pixelHeight: Int) -> NSImage? {
            guard let cgImage = makeCGImage(pixelHeight: pixelHeight) else { return nil }
            return NSImage(cgImage: cgImage, size: pointSize)
        }

        /// Builds a CGImage covering the top `pixelHeight` rows of this bitmap.
        /// Used for immutable final output and by the overlap verifier.
        /// Preview thumbnails borrow the canvas only during synchronous drawing.
        func makeCGImage(pixelHeight: Int) -> CGImage? {
            guard pixelHeight > 0, pixelHeight <= height else { return nil }

            let byteCount = pixelHeight * bytesPerRow
            let buffer = UnsafeBufferPointer(start: data, count: byteCount)
            let imageData = Data(buffer: buffer)

            guard let provider = CGDataProvider(data: imageData as CFData) else { return nil }
            return CGImage(
                width: width,
                height: pixelHeight,
                bitsPerComponent: imageFormat.bitsPerComponent,
                bitsPerPixel: imageFormat.bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: imageFormat.colorSpace,
                bitmapInfo: imageFormat.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        var bytesPerPixelValue: Int { bytesPerPixel }

    }
}
