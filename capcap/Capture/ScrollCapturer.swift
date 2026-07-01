import AppKit
import Vision

final class ScrollCapturer {
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

    /// Result of a single capture attempt, used by auto-scroll to decide
    /// whether the page kept producing fresh content or has bottomed out.
    enum FrameOutcome {
        /// A new frame with fresh content was stitched in.
        case appended
        /// The frame was a duplicate, too similar, or failed — no progress.
        case noNewContent
        /// The frame budget is exhausted; capturing should stop.
        case atFrameLimit

        var diagnosticName: String {
            switch self {
            case .appended: return "appended"
            case .noNewContent: return "no-new-content"
            case .atFrameLimit: return "at-frame-limit"
            }
        }
    }

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let screen: NSScreen
    /// capcap's own scroll-capture chrome (e.g. the hint toast) — excluded
    /// from every captured frame so it never appears in the stitched image.
    private let excludedWindowNumbers: [CGWindowID]
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let maxFrames = 100
    private let diagnosticID: String
    private let initialCaptureTimeout: TimeInterval = 3.0
    private let settledCaptureTimeout: TimeInterval = 1.5

    private var frames: [CapturedFrame] = []
    private var overlaps: [Int] = []
    private var captureAttemptCount = 0
    private var consecutiveNoNewContentCount = 0

    // MARK: - Sticky element exclusion state
    //
    // Pages with persistent UI (scrollbars on the right, sticky nav bars
    // at the top) confuse Vision's translational image registration: the
    // scrollbar slider sits in a different place between frames at a
    // different rate than page content, and a sticky header doesn't move
    // at all. Vision treats both regions as evidence and reports a
    // translation that splits the difference — typically much smaller
    // than the page's actual scroll offset. We detect both regions once
    // per session from the first usable frame pair and crop them out of
    // every image fed into Vision afterwards.
    private var scrollbarWidthPx: Int = 0
    private var scrollbarDetected: Bool = false
    private var stickyHeaderPx: Int = 0
    private var stickyHeaderDetectionDone: Bool = false
    private var stickyHeaderSamplesTaken: Int = 0

    // Incremental preview state
    private var previewBitmap: BitmapData?
    private var previewHeightPixels: Int = 0
    private var previewScale: CGFloat = 1
    private var previewPointWidth: CGFloat = 0

    init(
        rect: CGRect,
        screen: NSScreen,
        excludingWindowNumbers: [CGWindowID] = [],
        diagnosticID: String? = nil
    ) {
        self.captureRect = rect
        self.screen = screen
        self.excludedWindowNumbers = excludingWindowNumbers
        self.diagnosticID = diagnosticID ?? String(UUID().uuidString.prefix(8))

        log(
            "init-begin",
            metadata: [
                "captureRect": Self.diagnosticRect(rect),
                "screenName": screen.localizedName,
                "screenScale": Self.diagnosticNumber(screen.backingScaleFactor),
                "excludedWindowNumbers": excludingWindowNumbers.map { String($0) }.joined(separator: ","),
            ]
        )
        if
            let image = ScreenCapturer.capture(
                rect: rect,
                screen: screen,
                excludingWindowNumbers: excludingWindowNumbers,
                timeout: initialCaptureTimeout
            ),
            let bitmap = bitmapData(from: image)
        {
            let firstFrame = CapturedFrame(image: image, bitmap: bitmap)
            frames.append(firstFrame)
            log(
                "init-first-frame",
                metadata: [
                    "imageSize": Self.diagnosticSize(image.size),
                    "bitmap": Self.diagnosticBitmap(bitmap),
                ]
            )
            initPreview(from: firstFrame)
        } else {
            log("init-first-frame-failed")
        }
    }

    func stopAndStitch(completion: @escaping (NSImage?) -> Void) {
        log("stop-and-stitch-enter")
        captureQueue.async {
            var result: NSImage?

            // One last frame so the final scrolled state is never missed.
            let finalFrameOutcome = self.captureFrame(expectedShiftPoints: 0)
            self.log(
                "stop-and-stitch-final-frame",
                metadata: ["outcome": finalFrameOutcome.diagnosticName]
            )

            guard !self.frames.isEmpty else {
                self.log("stop-and-stitch-no-frames")
                result = nil
                self.log("stop-and-stitch-leave")
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }

            if self.frames.count == 1 {
                self.log("stop-and-stitch-single-frame")
                result = self.frames[0].image
                self.log("stop-and-stitch-leave")
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }

            self.log("final-stitch-begin")
            result = self.stitchAcceptedFrames()
            self.log(
                "final-stitch-end",
                metadata: [
                    "result": result.map { Self.diagnosticSize($0.size) } ?? "nil",
                ]
            )

            self.log("stop-and-stitch-leave")
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Captures a frame synchronously and reports the outcome. Used by the
    /// auto-scroll loop: it scrolls a fixed step, then calls this to learn
    /// whether the step revealed new content (keep going) or not (page end).
    func captureSynchronously(expectedShiftPoints: CGFloat) -> FrameOutcome {
        var outcome: FrameOutcome = .noNewContent
        captureQueue.sync {
            outcome = captureFrame(expectedShiftPoints: expectedShiftPoints)
        }
        return outcome
    }

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
        var captureFailures = 0
        var signatureFailures = 0
        let deadline = Date().addingTimeInterval(settledCaptureTimeout)

        // ~20 iterations × 12–80ms backoff ≈ up to ~1s total wait, which is
        // more than enough for typical smooth-scroll animations (150–300ms).
        for _ in 0..<20 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let image = ScreenCapturer.capture(
                rect: captureRect,
                screen: screen,
                excludingWindowNumbers: excludedWindowNumbers,
                timeout: remaining
            ) else {
                captureFailures += 1
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
                signatureFailures += 1
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

        // Timeout — return whatever we have. The caller's dedup check
        // (imagesAreNearlyIdentical) will still catch the no-progress case
        // and report .noNewContent appropriately.
        log(
            "settled-capture-timeout",
            metadata: [
                "captureFailures": captureFailures,
                "signatureFailures": signatureFailures,
                "hasLastImage": lastImage != nil,
            ]
        )
        return lastImage
    }

    private func sleepUntilDeadline(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }

    @discardableResult
    private func captureFrame(expectedShiftPoints: CGFloat) -> FrameOutcome {
        captureAttemptCount += 1
        let attempt = captureAttemptCount
        log(
            "capture-frame-begin",
            metadata: [
                "attempt": attempt,
                "expectedShiftPoints": Self.diagnosticNumber(expectedShiftPoints),
            ]
        )

        guard frames.count < maxFrames else {
            log("capture-frame-limit", metadata: ["attempt": attempt])
            return .atFrameLimit
        }
        guard
            let image = captureSettledFrame(),
            let bitmap = bitmapData(from: image)
        else {
            logNoNewContent(reason: "capture-or-bitmap-failed", attempt: attempt)
            return .noNewContent
        }

        let candidateFrame = CapturedFrame(image: image, bitmap: bitmap)

        if let previousFrame = frames.last,
           imagesAreNearlyIdentical(previousFrame.bitmap, candidateFrame.bitmap) {
            logNoNewContent(
                reason: "nearly-identical",
                attempt: attempt,
                metadata: ["bitmap": Self.diagnosticBitmap(bitmap)]
            )
            return .noNewContent
        }

        guard let previousFrame = frames.last else {
            frames.append(candidateFrame)
            initPreview(from: candidateFrame)
            consecutiveNoNewContentCount = 0
            log(
                "capture-frame-appended",
                metadata: [
                    "attempt": attempt,
                    "reason": "first-frame",
                    "bitmap": Self.diagnosticBitmap(bitmap),
                ]
            )
            return .appended
        }

        let scale = CGFloat(candidateFrame.bitmap.height) / max(candidateFrame.image.size.height, 1)
        let expectedShiftPixels: Int?
        if expectedShiftPoints > 0 {
            expectedShiftPixels = Int((expectedShiftPoints * scale).rounded())
        } else {
            expectedShiftPixels = nil
        }

        let overlap = findOverlap(
            previous: previousFrame.bitmap,
            current: candidateFrame.bitmap,
            expectedNewContentPixels: expectedShiftPixels
        )

        let minimumNewRows = max(8, candidateFrame.bitmap.height / 200)
        let newRows = candidateFrame.bitmap.height - overlap
        guard newRows >= minimumNewRows else {
            logNoNewContent(
                reason: "new-rows-below-threshold",
                attempt: attempt,
                metadata: [
                    "overlap": overlap,
                    "newRows": newRows,
                    "minimumNewRows": minimumNewRows,
                ]
            )
            return .noNewContent
        }

        frames.append(candidateFrame)
        overlaps.append(overlap)
        appendToPreview(candidateFrame.bitmap, overlapPixels: overlap)
        consecutiveNoNewContentCount = 0
        log(
            "capture-frame-appended",
            metadata: [
                "attempt": attempt,
                "overlap": overlap,
                "newRows": newRows,
                "bitmap": Self.diagnosticBitmap(bitmap),
                "previewHeightPixels": previewHeightPixels,
            ]
        )
        return .appended
    }

    // MARK: - Incremental Preview

    private func initPreview(from frame: CapturedFrame) {
        previewScale = CGFloat(frame.bitmap.height) / max(frame.image.size.height, 1)
        previewPointWidth = frame.image.size.width

        let initialCapacity = frame.bitmap.height * 10
        guard let output = makeOutputBitmap(from: frame.bitmap, totalHeightPixels: initialCapacity) else {
            log(
                "preview-init-bitmap-failed",
                metadata: ["initialCapacity": initialCapacity]
            )
            return
        }

        copyRows(
            from: frame.bitmap,
            sourceStartRow: 0,
            rowCount: frame.bitmap.height,
            to: output,
            destinationStartRow: 0
        )

        previewBitmap = output
        previewHeightPixels = frame.bitmap.height
        log(
            "preview-init",
            metadata: [
                "initialCapacity": initialCapacity,
                "previewHeightPixels": previewHeightPixels,
            ]
        )
        emitPreviewImage()
    }

    private func appendToPreview(_ bitmap: BitmapData, overlapPixels: Int) {
        guard var previewBitmap else {
            log("preview-append-missing-bitmap")
            return
        }

        let newRows = bitmap.height - overlapPixels
        guard newRows > 0 else {
            log(
                "preview-append-no-rows",
                metadata: [
                    "overlap": overlapPixels,
                    "bitmap": Self.diagnosticBitmap(bitmap),
                ]
            )
            return
        }

        let neededHeight = previewHeightPixels + newRows
        if neededHeight > previewBitmap.height {
            let newCapacity = neededHeight + bitmap.height * 5
            log(
                "preview-grow-begin",
                metadata: [
                    "neededHeight": neededHeight,
                    "newCapacity": newCapacity,
                    "oldCapacity": previewBitmap.height,
                ]
            )
            guard let grown = makeOutputBitmap(from: bitmap, totalHeightPixels: newCapacity) else {
                log("preview-grow-failed", metadata: ["newCapacity": newCapacity])
                return
            }
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
            sourceStartRow: overlapPixels,
            rowCount: newRows,
            to: previewBitmap,
            destinationStartRow: previewHeightPixels
        )

        previewHeightPixels += newRows
        log(
            "preview-append",
            metadata: [
                "newRows": newRows,
                "overlap": overlapPixels,
                "previewHeightPixels": previewHeightPixels,
            ]
        )
        emitPreviewImage()
    }

    private func emitPreviewImage() {
        guard let previewBitmap, previewHeightPixels > 0 else {
            log("preview-emit-skipped")
            return
        }

        let totalHeightPoints = CGFloat(previewHeightPixels) / previewScale
        guard let image = previewBitmap.makeImage(
            pointSize: NSSize(width: previewPointWidth, height: totalHeightPoints),
            pixelHeight: previewHeightPixels
        ) else {
            log(
                "preview-image-failed",
                metadata: [
                    "previewHeightPixels": previewHeightPixels,
                    "totalHeightPoints": Self.diagnosticNumber(totalHeightPoints),
                ]
            )
            return
        }

        log(
            "preview-image-dispatch",
            metadata: [
                "imageSize": Self.diagnosticSize(image.size),
                "pixelHeight": previewHeightPixels,
            ]
        )
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            self?.onPreviewUpdated?(image)
        }
    }

    // MARK: - Final Stitch

    private func stitchAcceptedFrames() -> NSImage? {
        guard let firstFrame = frames.first else { return nil }

        let bitmapHeight = firstFrame.bitmap.height
        let scale = CGFloat(bitmapHeight) / max(firstFrame.image.size.height, 1)

        let totalHeightPixels = overlaps.reduce(bitmapHeight) { partialResult, overlap in
            partialResult + (bitmapHeight - overlap)
        }
        let totalHeightPoints = CGFloat(totalHeightPixels) / scale

        guard let stitchedBitmap = makeOutputBitmap(from: firstFrame.bitmap, totalHeightPixels: totalHeightPixels) else {
            log(
                "final-stitch-bitmap-failed",
                metadata: ["totalHeightPixels": totalHeightPixels]
            )
            return firstFrame.image
        }
        log(
            "final-stitch-copy-begin",
            metadata: [
                "frameCount": frames.count,
                "totalHeightPixels": totalHeightPixels,
                "totalHeightPoints": Self.diagnosticNumber(totalHeightPoints),
            ]
        )

        var destinationRow = 0

        for index in frames.indices {
            let sourceStartRow = index == 0 ? 0 : overlaps[index - 1]
            let rowsToCopy = bitmapHeight - sourceStartRow

            copyRows(
                from: frames[index].bitmap,
                sourceStartRow: sourceStartRow,
                rowCount: rowsToCopy,
                to: stitchedBitmap,
                destinationStartRow: destinationRow
            )

            destinationRow += rowsToCopy
        }

        let image = stitchedBitmap.makeImage(
            pointSize: NSSize(width: firstFrame.image.size.width, height: totalHeightPoints),
            pixelHeight: totalHeightPixels
        )
        log(
            "final-stitch-image",
            metadata: [
                "result": image.map { Self.diagnosticSize($0.size) } ?? "nil",
                "destinationRow": destinationRow,
            ]
        )
        return image
    }

    // MARK: - Overlap Detection

    /// Computes how many rows at the top of `current` overlap with the bottom of
    /// `previous`, using Apple Vision's translational image registration. Vision
    /// is significantly more accurate than per-row pixel matching on content
    /// where neighbouring rows look nearly identical (text, code, chat logs):
    /// it considers the whole image as a 2D signal rather than scoring rows
    /// independently, so it doesn't snap to wrong-but-locally-plausible offsets.
    ///
    /// The returned value is in pixels and lies in `0...min(previous.height, current.height)`.
    /// `expectedNewContentPixels` is retained in the signature for source
    /// compatibility with the caller but is no longer consulted — Vision needs
    /// no hint.
    private func findOverlap(
        previous: BitmapData,
        current: BitmapData,
        expectedNewContentPixels: Int?
    ) -> Int {
        let height = min(previous.height, current.height)
        guard height > 0 else {
            log("overlap-empty")
            return 0
        }

        // One-time scrollbar detection on the first usable frame pair.
        // Once cached, the right `scrollbarWidthPx` columns of every frame
        // are kept out of Vision's view to stop the moving slider from
        // poisoning the translation estimate.
        if !scrollbarDetected {
            detectScrollbar(current: current, previous: previous)
        }

        guard let previousCG = previous.makeCGImage(pixelHeight: previous.height),
              let currentCG = current.makeCGImage(pixelHeight: current.height) else {
            log("overlap-cgimage-failed")
            return height
        }

        // Crop sticky-UI regions out of the Vision inputs. The X crop is
        // safe because Vision measures Y translation independently per
        // column. The Y crop is safe because both images get the same
        // top trimmed — the residual Y shift Vision reports is therefore
        // the shift of post-header content, which is exactly the scroll
        // distance we want.
        // Use the common extent (min of both CGImages) so the crop is
        // always in-bounds for both — guarantees `cropping(to:)`
        // succeeds and Vision sees same-sized inputs.
        let commonWidth = min(currentCG.width, previousCG.width)
        let commonHeight = min(currentCG.height, previousCG.height)
        let cropWidth = max(0, commonWidth - scrollbarWidthPx)
        let cropY = stickyHeaderDetectionDone
            ? min(stickyHeaderPx, commonHeight / 5)
            : 0
        let cropHeight = commonHeight - cropY

        let visionPrevious: CGImage
        let visionCurrent: CGImage
        if cropWidth >= 50 && cropHeight >= 50 && (scrollbarWidthPx > 0 || cropY > 0) {
            let cropRect = CGRect(x: 0, y: cropY, width: cropWidth, height: cropHeight)
            visionPrevious = previousCG.cropping(to: cropRect) ?? previousCG
            visionCurrent = currentCG.cropping(to: cropRect) ?? currentCG
        } else {
            visionPrevious = previousCG
            visionCurrent = currentCG
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: visionPrevious)
        let handler = VNImageRequestHandler(cgImage: visionCurrent, options: [:])

        var visionMetadata: [String: Any] = [
            "commonWidth": commonWidth,
            "commonHeight": commonHeight,
            "cropWidth": cropWidth,
            "cropY": cropY,
            "cropHeight": cropHeight,
            "scrollbarWidthPx": scrollbarWidthPx,
            "stickyHeaderPx": stickyHeaderPx,
        ]
        if let expectedNewContentPixels {
            visionMetadata["expectedNewContentPixels"] = expectedNewContentPixels
        }
        log("vision-registration-begin", metadata: visionMetadata)

        do {
            try handler.perform([request])
        } catch {
            var metadata = visionMetadata
            metadata["error"] = error.localizedDescription
            log("vision-registration-error", metadata: metadata)
            return height
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            log("vision-registration-no-result", metadata: visionMetadata)
            return height
        }

        // alignmentTransform.ty is the pixel distance the source (current frame)
        // must be shifted to align with the target (previous frame). For a page
        // that scrolled DOWN between frames, this comes out positive and equals
        // the height of newly-revealed content at the bottom of `current`.
        // Because both Vision inputs were cropped identically, ty is the same
        // shift we would see in the original frame coordinates — apply directly.
        let newContentPx = Int(observation.alignmentTransform.ty.rounded())
        visionMetadata["newContentPx"] = newContentPx

        // First time we see a real shift, try to learn where the sticky
        // header ends so subsequent frames can crop it out.
        if newContentPx > 5 && !stickyHeaderDetectionDone {
            detectStickyHeader(current: current, previous: previous)
            visionMetadata["stickyHeaderAfterDetection"] = stickyHeaderPx
            visionMetadata["stickyHeaderDetectionDone"] = stickyHeaderDetectionDone
        }

        guard newContentPx > 0 else {
            log("vision-registration-no-positive-shift", metadata: visionMetadata)
            return height
        }

        let overlap = height - newContentPx
        let clamped = max(0, min(height, overlap))
        visionMetadata["overlap"] = clamped
        log("vision-registration-end", metadata: visionMetadata)
        return clamped
    }

    // MARK: - Sticky element detection

    /// Scans the right edge of the frame pair looking for columns whose
    /// pixels differ between the two captures. Those columns are where the
    /// scrollbar slider lives — it moves while the page scrolls, while
    /// page content shifts vertically. Identifying and cropping it out
    /// keeps Vision from anchoring on the slider's bounding box.
    private func detectScrollbar(current: BitmapData, previous: BitmapData) {
        defer { scrollbarDetected = true }

        let width = min(current.width, previous.width)
        let height = min(current.height, previous.height)
        guard width > 80, height > 40 else { return }

        let maxScan = min(50, width / 8)
        let sampleStart = height / 5
        let sampleEnd = (height * 4) / 5
        let sampleStep = max(1, (sampleEnd - sampleStart) / 30)

        var detectedWidth = 0
        var sawQuietAfterMoving = false

        for offset in 0..<maxScan {
            let column = width - 1 - offset
            var totalDiff = 0
            var samples = 0

            var row = sampleStart
            while row < sampleEnd {
                let lhs = current.pixel(x: column, y: row)
                let rhs = previous.pixel(x: column, y: row)
                totalDiff +=
                    abs(Int(lhs.r) - Int(rhs.r)) +
                    abs(Int(lhs.g) - Int(rhs.g)) +
                    abs(Int(lhs.b) - Int(rhs.b))
                samples += 1
                row += sampleStep
            }

            guard samples > 0 else { continue }
            let avg = totalDiff / samples

            if avg > 8 {
                detectedWidth = offset + 1
            } else if detectedWidth > 0 {
                // First quiet column past the moving region — scrollbar
                // edge found, stop scanning.
                sawQuietAfterMoving = true
                break
            }
        }

        // Only commit a width if the scan actually observed a moving →
        // quiet transition at the edge. Without that boundary, the
        // "moving" region might just be content (e.g., an animation
        // taking up the whole right area), not a scrollbar.
        if sawQuietAfterMoving && detectedWidth >= 3 && detectedWidth <= 40 {
            // Small buffer past the detected edge to absorb anti-aliasing
            // fringe and any 1–2 px misalignment in our column sampling.
            scrollbarWidthPx = detectedWidth + 4
        }
        log(
            "scrollbar-detection",
            metadata: [
                "detectedWidth": detectedWidth,
                "committedWidth": scrollbarWidthPx,
                "sawQuietAfterMoving": sawQuietAfterMoving,
            ]
        )
    }

    /// Scans top-to-bottom looking for the first row that genuinely differs
    /// between the two captures. Rows above that boundary held identical
    /// pixels in both frames, which is the signature of a sticky element
    /// (top nav bar, toolbar, banner). Multiple samples are required to
    /// agree before the value is locked in — a single observation could
    /// be coincidental on a content-light page.
    private func detectStickyHeader(current: BitmapData, previous: BitmapData) {
        let width = min(current.width, previous.width)
        let height = min(current.height, previous.height)
        guard width > 80, height > 40 else {
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-skipped",
                metadata: [
                    "width": width,
                    "height": height,
                ]
            )
            return
        }

        // Exclude the right margin (scrollbar) from sampling so its
        // motion doesn't fool the per-row diff into thinking a header
        // row is non-sticky.
        let scanWidth = max(40, width - scrollbarWidthPx)
        let columnStart = width / 10
        let columnEnd = min(scanWidth - 1, (scanWidth * 9) / 10)
        let columnStep = max(1, (columnEnd - columnStart) / 20)

        var firstMovingRow = -1
        for row in 0..<height {
            var totalDiff = 0
            var samples = 0

            var column = columnStart
            while column <= columnEnd {
                let lhs = current.pixel(x: column, y: row)
                let rhs = previous.pixel(x: column, y: row)
                totalDiff +=
                    abs(Int(lhs.r) - Int(rhs.r)) +
                    abs(Int(lhs.g) - Int(rhs.g)) +
                    abs(Int(lhs.b) - Int(rhs.b))
                samples += 1
                column += columnStep
            }

            guard samples > 0 else { continue }
            if totalDiff / samples > 8 {
                firstMovingRow = row
                break
            }
        }

        guard firstMovingRow >= 0 else {
            // Whole frame is frozen — page didn't actually scroll. Don't
            // make any decision yet; wait for a later frame pair.
            log("sticky-header-detection-frozen-frame")
            return
        }

        let frozenRows = firstMovingRow
        let maxPlausibleHeader = (height * 6) / 10  // 60% of height

        stickyHeaderSamplesTaken += 1

        if frozenRows < 10 {
            // Too small to be a real sticky element. Lock in "no header".
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-none",
                metadata: ["frozenRows": frozenRows]
            )
            return
        }

        if frozenRows > maxPlausibleHeader {
            // Implausibly large frozen region — give up rather than
            // chop away real content.
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-implausible",
                metadata: [
                    "frozenRows": frozenRows,
                    "maxPlausibleHeader": maxPlausibleHeader,
                ]
            )
            return
        }

        if stickyHeaderSamplesTaken == 1 {
            stickyHeaderPx = frozenRows
        } else if abs(frozenRows - stickyHeaderPx) <= 5 {
            stickyHeaderPx = min(stickyHeaderPx, frozenRows)
        } else {
            // Sample disagrees with the previous one by too much.
            // Detection isn't stable on this page; bail out without
            // applying any header crop.
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-unstable",
                metadata: [
                    "frozenRows": frozenRows,
                    "sampleCount": stickyHeaderSamplesTaken,
                ]
            )
            return
        }

        // Two consistent samples is enough to commit.
        if stickyHeaderSamplesTaken >= 2 {
            stickyHeaderDetectionDone = true
        }
        log(
            "sticky-header-detection-sample",
            metadata: [
                "frozenRows": frozenRows,
                "stickyHeaderPx": stickyHeaderPx,
                "sampleCount": stickyHeaderSamplesTaken,
                "done": stickyHeaderDetectionDone,
            ]
        )
    }

    // MARK: - Image Helpers

    private func logNoNewContent(
        reason: String,
        attempt: Int,
        metadata: [String: Any] = [:]
    ) {
        consecutiveNoNewContentCount += 1
        guard consecutiveNoNewContentCount == 1 || consecutiveNoNewContentCount.isMultiple(of: 5) else {
            return
        }

        var fields = metadata
        fields["attempt"] = attempt
        fields["reason"] = reason
        fields["consecutiveNoNewContent"] = consecutiveNoNewContentCount
        log("capture-frame-no-new-content", metadata: fields)
    }

    private func log(_ event: String, metadata: [String: Any] = [:]) {
        var fields = metadata
        fields["session"] = diagnosticID
        fields["frames"] = frames.count
        fields["overlaps"] = overlaps.count
        fields["attempts"] = captureAttemptCount
        fields["previewHeightPixels"] = previewHeightPixels
        DiagnosticLog.log("scroll-stitch", event, metadata: fields)
    }

    private static func diagnosticRect(_ rect: CGRect) -> String {
        "x=\(diagnosticNumber(rect.origin.x)) y=\(diagnosticNumber(rect.origin.y)) w=\(diagnosticNumber(rect.width)) h=\(diagnosticNumber(rect.height))"
    }

    private static func diagnosticSize(_ size: NSSize) -> String {
        "w=\(diagnosticNumber(size.width)) h=\(diagnosticNumber(size.height))"
    }

    private static func diagnosticBitmap(_ bitmap: BitmapData) -> String {
        "w=\(bitmap.width) h=\(bitmap.height) bpr=\(bitmap.bytesPerRow)"
    }

    private static func diagnosticNumber(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func imagesAreNearlyIdentical(_ lhs: BitmapData, _ rhs: BitmapData) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return false
        }

        let numCols = min(32, max(16, lhs.width / 20))
        let numRows = min(32, max(16, lhs.height / 20))
        let sampleCols = sampledColumns(width: lhs.width, count: numCols)
        let sampleRows = sampledRows(height: lhs.height, count: numRows)

        var diff = 0
        var comparisons = 0

        for row in sampleRows {
            for col in sampleCols {
                diff += pixelDiff(lhs.pixel(x: col, y: row), rhs.pixel(x: col, y: row))
                comparisons += 1
            }
        }

        guard comparisons > 0 else { return false }
        return diff / comparisons < 3
    }

    private func sampledColumns(width: Int, count: Int) -> [Int] {
        guard width > 0, count > 0 else { return [] }

        let inset = min(max(4, width / 12), max(4, width / 4))
        let lowerBound = min(width - 1, inset)
        let upperBound = max(lowerBound, width - inset - 1)
        let span = max(1, upperBound - lowerBound + 1)

        var result: [Int] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let column = lowerBound + min(span - 1, span * (index * 2 + 1) / max(1, count * 2))
            if result.last != column {
                result.append(column)
            }
        }

        return result
    }

    private func sampledRows(height: Int, count: Int) -> [Int] {
        guard height > 0, count > 0 else { return [] }

        var rows: [Int] = []
        rows.reserveCapacity(count)

        for index in 0..<count {
            let row = min(height - 1, height * (index * 2 + 1) / max(1, count * 2))
            if rows.last != row {
                rows.append(row)
            }
        }

        return rows
    }

    private func pixelDiff(_ lhs: (r: UInt8, g: UInt8, b: UInt8), _ rhs: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        abs(Int(lhs.r) - Int(rhs.r)) +
        abs(Int(lhs.g) - Int(rhs.g)) +
        abs(Int(lhs.b) - Int(rhs.b))
    }

    private func bitmapData(from image: NSImage) -> BitmapData? {
        guard let rep = image.bitmapImageRepPreservingBacking() else { return nil }
        return BitmapData(rep: rep)
    }

    private func makeOutputBitmap(from source: BitmapData, totalHeightPixels: Int) -> BitmapData? {
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
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        return BitmapData(rep: rep, format: source.imageFormat)
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

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return (0, 0, 0)
            }

            let offset = y * bytesPerRow + x * bytesPerPixel
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        func makeImage(pointSize: NSSize, pixelHeight: Int) -> NSImage? {
            guard let cgImage = makeCGImage(pixelHeight: pixelHeight) else { return nil }
            return NSImage(cgImage: cgImage, size: pointSize)
        }

        /// Builds a CGImage covering the top `pixelHeight` rows of this bitmap.
        /// Shared by `makeImage(pointSize:pixelHeight:)` (the preview/output
        /// pipeline) and by `findOverlap` (Apple Vision input).
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
