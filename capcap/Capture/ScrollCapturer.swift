import AppKit
import Vision

final class ScrollCapturer {
    struct ImageFormat {
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
    }

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let screen: NSScreen
    /// capcap's own scroll-capture chrome (e.g. the hint toast) — excluded
    /// from every captured frame so it never appears in the stitched image.
    private let excludedWindowNumbers: [CGWindowID]
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let maxFrames = 100
    private let initialCaptureTimeout: TimeInterval = 3.0
    private let settledCaptureTimeout: TimeInterval = 1.5
    private let overlapSearchRadius = 4
    private let seamBlendRows = 6

    private var frames: [CapturedFrame] = []
    private var overlaps: [Int] = []

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
        excludingWindowNumbers: [CGWindowID] = []
    ) {
        self.captureRect = rect
        self.screen = screen
        self.excludedWindowNumbers = excludingWindowNumbers

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
            initPreview(from: firstFrame)
        }
    }

    func stopAndStitch(completion: @escaping (NSImage?) -> Void) {
        captureQueue.async {
            var result: NSImage?

            // One last frame so the final scrolled state is never missed.
            self.captureFrame(expectedShiftPoints: 0)

            guard !self.frames.isEmpty else {
                result = nil
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }

            if self.frames.count == 1 {
                result = self.frames[0].image
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }

            result = self.stitchAcceptedFrames()

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

        // Timeout — return whatever we have. The caller's dedup check
        // (imagesAreNearlyIdentical) will still catch the no-progress case
        // and report .noNewContent appropriately.
        return lastImage
    }

    private func sleepUntilDeadline(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }

    @discardableResult
    private func captureFrame(expectedShiftPoints _: CGFloat) -> FrameOutcome {
        guard frames.count < maxFrames else {
            return .atFrameLimit
        }
        guard
            let image = captureSettledFrame(),
            let bitmap = bitmapData(from: image)
        else {
            return .noNewContent
        }

        let candidateFrame = CapturedFrame(image: image, bitmap: bitmap)

        if let previousFrame = frames.last,
           imagesAreNearlyIdentical(previousFrame.bitmap, candidateFrame.bitmap) {
            return .noNewContent
        }

        guard let previousFrame = frames.last else {
            frames.append(candidateFrame)
            initPreview(from: candidateFrame)
            return .appended
        }

        let overlap = findOverlap(
            previous: previousFrame.bitmap,
            current: candidateFrame.bitmap
        )

        let minimumNewRows = max(8, candidateFrame.bitmap.height / 200)
        let newRows = candidateFrame.bitmap.height - overlap
        guard newRows >= minimumNewRows else {
            return .noNewContent
        }

        frames.append(candidateFrame)
        overlaps.append(overlap)
        appendToPreview(candidateFrame.bitmap, overlapPixels: overlap)
        return .appended
    }

    // MARK: - Incremental Preview

    private func initPreview(from frame: CapturedFrame) {
        previewScale = CGFloat(frame.bitmap.height) / max(frame.image.size.height, 1)
        previewPointWidth = frame.image.size.width

        let initialCapacity = frame.bitmap.height * 10
        guard let output = makeOutputBitmap(
            from: frame.bitmap,
            totalHeightPixels: initialCapacity
        ) else { return }

        copyRows(
            from: frame.bitmap,
            sourceStartRow: 0,
            rowCount: frame.bitmap.height,
            to: output,
            destinationStartRow: 0
        )

        previewBitmap = output
        previewHeightPixels = frame.bitmap.height
        emitPreviewImage()
    }

    private func appendToPreview(_ bitmap: BitmapData, overlapPixels: Int) {
        guard var previewBitmap else { return }

        let newRows = bitmap.height - overlapPixels
        guard newRows > 0 else { return }

        let neededHeight = previewHeightPixels + newRows
        if neededHeight > previewBitmap.height {
            let newCapacity = neededHeight + bitmap.height * 5
            guard let grown = makeOutputBitmap(
                from: bitmap,
                totalHeightPixels: newCapacity
            ) else { return }
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
        emitPreviewImage()
    }

    private func emitPreviewImage() {
        guard let previewBitmap, previewHeightPixels > 0 else { return }

        let totalHeightPoints = CGFloat(previewHeightPixels) / previewScale
        guard let image = previewBitmap.makeImage(
            pointSize: NSSize(width: previewPointWidth, height: totalHeightPoints),
            pixelHeight: previewHeightPixels
        ) else { return }

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

        guard let stitchedBitmap = makeOutputBitmap(
            from: firstFrame.bitmap,
            totalHeightPixels: totalHeightPixels
        ) else {
            return firstFrame.image
        }

        var destinationRow = 0

        for index in frames.indices {
            let sourceStartRow = index == 0 ? 0 : overlaps[index - 1]
            let rowsToCopy = bitmapHeight - sourceStartRow

            if index == 0 {
                copyRows(
                    from: frames[index].bitmap,
                    sourceStartRow: sourceStartRow,
                    rowCount: rowsToCopy,
                    to: stitchedBitmap,
                    destinationStartRow: destinationRow
                )
            } else {
                ScrollStitchQuality.blendSeam(
                    from: frames[index].bitmap,
                    sourceStartRow: sourceStartRow,
                    rowCount: rowsToCopy,
                    to: stitchedBitmap,
                    destinationStartRow: destinationRow,
                    blendRows: seamBlendRows
                )
            }

            destinationRow += rowsToCopy
        }

        return stitchedBitmap.makeImage(
            pointSize: NSSize(width: firstFrame.image.size.width, height: totalHeightPoints),
            pixelHeight: totalHeightPixels
        )
    }

    // MARK: - Overlap Detection

    /// Computes how many rows at the top of `current` overlap with the bottom of
    /// `previous`, using Apple Vision's translational image registration. Vision
    /// is significantly more accurate than per-row pixel matching on content
    /// where neighbouring rows look nearly identical (text, code, chat logs):
    /// it considers the whole image as a 2D signal rather than scoring rows
    /// independently, so it doesn't snap to wrong-but-locally-plausible offsets.
    ///
    /// The returned value is in pixels and lies in
    /// `0...min(previous.height, current.height)`.
    private func findOverlap(
        previous: BitmapData,
        current: BitmapData
    ) -> Int {
        let height = min(previous.height, current.height)
        guard height > 0 else { return 0 }

        // One-time scrollbar detection on the first usable frame pair.
        // Once cached, the right `scrollbarWidthPx` columns of every frame
        // are kept out of Vision's view to stop the moving slider from
        // poisoning the translation estimate.
        if !scrollbarDetected {
            detectScrollbar(current: current, previous: previous)
        }

        guard let previousCG = previous.makeCGImage(pixelHeight: previous.height),
              let currentCG = current.makeCGImage(pixelHeight: current.height) else {
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

        do {
            try handler.perform([request])
        } catch {
            return height
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return height
        }

        // alignmentTransform.ty is the pixel distance the source (current frame)
        // must be shifted to align with the target (previous frame). For a page
        // that scrolled DOWN between frames, this comes out positive and equals
        // the height of newly-revealed content at the bottom of `current`.
        // Because both Vision inputs were cropped identically, ty is the same
        // shift we would see in the original frame coordinates — apply directly.
        let newContentPx = Int(observation.alignmentTransform.ty.rounded())

        // First time we see a real shift, try to learn where the sticky
        // header ends so subsequent frames can crop it out.
        if newContentPx > 5 && !stickyHeaderDetectionDone {
            detectStickyHeader(current: current, previous: previous)
        }

        guard newContentPx > 0 else { return height }

        let preliminaryOverlap = height - newContentPx
        let overlap = ScrollStitchQuality.refinedOverlap(
            previous: previous,
            current: current,
            preliminary: preliminaryOverlap,
            searchRadius: overlapSearchRadius
        )
        return max(0, min(height, overlap))
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
            return
        }

        let frozenRows = firstMovingRow
        let maxPlausibleHeader = (height * 6) / 10  // 60% of height

        stickyHeaderSamplesTaken += 1

        if frozenRows < 10 {
            // Too small to be a real sticky element. Lock in "no header".
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            return
        }

        if frozenRows > maxPlausibleHeader {
            // Implausibly large frozen region — give up rather than
            // chop away real content.
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
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
            return
        }

        // Two consistent samples is enough to commit.
        if stickyHeaderSamplesTaken >= 2 {
            stickyHeaderDetectionDone = true
        }
    }

    // MARK: - Image Helpers

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

    final class BitmapData {
        let rep: NSBitmapImageRep
        let data: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let imageFormat: ImageFormat
        internal let bytesPerPixel: Int

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

/// Pixel-level quality helpers for scroll stitching.
///
/// Vision establishes the rough translation; these helpers handle the integer
/// row boundary and seam blending that Vision intentionally does not model.
enum ScrollStitchQuality {
    /// Refines Vision's rounded translation with a bounded row-similarity search.
    /// Rounding or slight registration noise can be off by a few pixels, which
    /// becomes a visible horizontal seam after a hard row cut.
    static func refinedOverlap(
        previous: ScrollCapturer.BitmapData,
        current: ScrollCapturer.BitmapData,
        preliminary: Int,
        searchRadius: Int
    ) -> Int {
        let height = min(previous.height, current.height)
        guard searchRadius > 0, preliminary > 0, preliminary < height else {
            return preliminary
        }

        let lowerBound = max(0, preliminary - searchRadius)
        let upperBound = min(height - 1, preliminary + searchRadius)
        var bestOverlap = preliminary
        var bestScore = overlapMatchScore(
            previous: previous,
            current: current,
            overlap: preliminary
        )

        for overlap in lowerBound...upperBound {
            let score = overlapMatchScore(
                previous: previous,
                current: current,
                overlap: overlap
            )
            if score < bestScore {
                bestScore = score
                bestOverlap = overlap
            }
        }

        return bestOverlap
    }

    /// Mean absolute RGB error over sampled pixels in the overlapping strip.
    /// The candidate overlap maps the top of current to the bottom of previous.
    private static func overlapMatchScore(
        previous: ScrollCapturer.BitmapData,
        current: ScrollCapturer.BitmapData,
        overlap: Int
    ) -> Int {
        guard overlap > 0 else { return .max }

        let width = min(previous.width, current.width)
        // Sample across the full content area while avoiding window edges,
        // where fixed toolbars and scrollbars can look identical at every
        // candidate offset.
        let edgeMargin = min(width / 8, 32)
        let sampledWidth = width - edgeMargin * 2
        guard sampledWidth > 0 else { return .max }
        let columnStep = max(1, sampledWidth / 32)
        let rowStep = max(1, overlap / 24)

        var difference = 0
        var samples = 0

        for stripRow in stride(from: 0, to: overlap, by: rowStep) {
            // AppKit bitmap backing rows use top-down coordinates in this path.
            let previousRow = previous.height - overlap + stripRow
            let currentRow = stripRow
            guard previousRow >= 0, previousRow < previous.height,
                  currentRow >= 0, currentRow < current.height else { continue }

            for column in stride(from: edgeMargin, to: width - edgeMargin, by: columnStep) {
                difference += pixelDiff(
                    previous.pixel(x: column, y: previousRow),
                    current.pixel(x: column, y: currentRow)
                )
                samples += 1
            }
        }

        guard samples > 0 else { return .max }
        return difference / samples
    }

    /// Copies new rows while progressively blending the first rows with pixels
    /// already emitted by the prior frame. This does not repair a bad offset,
    /// but it prevents a small luminance step from reading as a divider.
    static func blendSeam(
        from source: ScrollCapturer.BitmapData,
        sourceStartRow: Int,
        rowCount: Int,
        to destination: ScrollCapturer.BitmapData,
        destinationStartRow: Int,
        blendRows: Int
    ) {
        guard rowCount > 0, blendRows > 0 else {
            copyRows(
                from: source,
                sourceStartRow: sourceStartRow,
                rowCount: rowCount,
                to: destination,
                destinationStartRow: destinationStartRow
            )
            return
        }

        let effectiveBlendRows = min(blendRows, rowCount)
        let bytesPerPixel = min(source.bytesPerPixelValue, destination.bytesPerPixelValue)
        let bytesPerRow = min(
            source.width * bytesPerPixel,
            min(source.bytesPerRow, destination.bytesPerRow)
        )

        for rowOffset in 0..<effectiveBlendRows {
            let sourceOffset = (sourceStartRow + rowOffset) * source.bytesPerRow
            let priorOffset = (sourceStartRow - 1 - rowOffset) * source.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * destination.bytesPerRow
            let sourceWeight = Double(rowOffset + 1) / Double(effectiveBlendRows + 1)

            for byteOffset in 0..<bytesPerRow {
                let sourceByte = source.data[sourceOffset + byteOffset]
                let priorByte = priorOffset >= 0
                    ? source.data[priorOffset + byteOffset]
                    : sourceByte
                let blended = Double(sourceByte) * sourceWeight
                    + Double(priorByte) * (1 - sourceWeight)
                destination.data[destinationOffset + byteOffset] = UInt8(blended.rounded())
            }
        }

        let remainingStart = effectiveBlendRows
        let remainingCount = rowCount - effectiveBlendRows
        if remainingCount > 0 {
            copyRows(
                from: source,
                sourceStartRow: sourceStartRow + remainingStart,
                rowCount: remainingCount,
                to: destination,
                destinationStartRow: destinationStartRow + remainingStart
            )
        }
    }

    private static func copyRows(
        from source: ScrollCapturer.BitmapData,
        sourceStartRow: Int,
        rowCount: Int,
        to destination: ScrollCapturer.BitmapData,
        destinationStartRow: Int
    ) {
        guard rowCount > 0 else { return }

        let bytesPerPixel = min(source.bytesPerPixelValue, destination.bytesPerPixelValue)
        let bytesPerRow = min(
            source.width * bytesPerPixel,
            min(source.bytesPerRow, destination.bytesPerRow)
        )

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

    private static func pixelDiff(
        _ lhs: (r: UInt8, g: UInt8, b: UInt8),
        _ rhs: (r: UInt8, g: UInt8, b: UInt8)
    ) -> Int {
        abs(Int(lhs.r) - Int(rhs.r))
            + abs(Int(lhs.g) - Int(rhs.g))
            + abs(Int(lhs.b) - Int(rhs.b))
    }
}
