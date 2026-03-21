import AppKit

final class ScrollCapturer {
    private struct CapturedFrame {
        let image: NSImage
        let bitmap: BitmapData
    }

    private struct SearchHint {
        let overlapPixels: Int
        let tolerancePixels: Int
        let strength: Double
    }

    private struct OverlapCandidate {
        let overlapPixels: Int
        let rawScore: Double
        let adjustedScore: Double
    }

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let screen: NSScreen
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let captureDelay: TimeInterval = 0.08
    private let maxFrames = 100

    private var frames: [CapturedFrame] = []
    private var overlaps: [Int] = []
    private var recentNewContentPixels: [Int] = []
    private var pendingCapture: DispatchWorkItem?
    private var pendingScrollDeltaPoints: CGFloat = 0

    // Incremental preview state
    private var previewBitmap: BitmapData?
    private var previewHeightPixels: Int = 0
    private var previewScale: CGFloat = 1
    private var previewPointWidth: CGFloat = 0

    init(rect: CGRect, screen: NSScreen) {
        self.captureRect = rect
        self.screen = screen

        if
            let image = ScreenCapturer.capture(rect: rect, screen: screen),
            let bitmap = bitmapData(from: image)
        {
            let firstFrame = CapturedFrame(image: image, bitmap: bitmap)
            frames.append(firstFrame)
            initPreview(from: firstFrame)
        }
    }

    func scheduleCapture(observedDeltaPoints: CGFloat = 0) {
        captureQueue.async { [weak self] in
            guard let self else { return }

            self.pendingScrollDeltaPoints += abs(observedDeltaPoints)
            self.pendingCapture?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.captureFrameFromPendingScroll()
            }

            self.pendingCapture = workItem
            self.captureQueue.asyncAfter(deadline: .now() + self.captureDelay, execute: workItem)
        }
    }

    func stopAndStitch() -> NSImage? {
        var result: NSImage?

        captureQueue.sync {
            pendingCapture?.cancel()
            pendingCapture = nil

            captureFrameFromPendingScroll()

            guard !frames.isEmpty else {
                result = nil
                return
            }

            if frames.count == 1 {
                result = frames[0].image
                return
            }

            result = stitchAcceptedFrames()
        }

        return result
    }

    private func captureFrameFromPendingScroll() {
        let expectedShiftPoints = pendingScrollDeltaPoints
        pendingScrollDeltaPoints = 0
        captureFrame(expectedShiftPoints: expectedShiftPoints)
    }

    private func captureFrame(expectedShiftPoints: CGFloat) {
        guard frames.count < maxFrames else { return }
        guard
            let image = ScreenCapturer.capture(rect: captureRect, screen: screen),
            let bitmap = bitmapData(from: image)
        else {
            return
        }

        let candidateFrame = CapturedFrame(image: image, bitmap: bitmap)

        if let previousFrame = frames.last,
           imagesAreNearlyIdentical(previousFrame.bitmap, candidateFrame.bitmap) {
            return
        }

        guard let previousFrame = frames.last else {
            frames.append(candidateFrame)
            initPreview(from: candidateFrame)
            return
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
        guard newRows >= minimumNewRows else { return }

        frames.append(candidateFrame)
        overlaps.append(overlap)
        rememberNewContentPixels(newRows)
        appendToPreview(candidateFrame.bitmap, overlapPixels: overlap)
    }

    // MARK: - Incremental Preview

    private func initPreview(from frame: CapturedFrame) {
        previewScale = CGFloat(frame.bitmap.height) / max(frame.image.size.height, 1)
        previewPointWidth = frame.image.size.width

        let initialCapacity = frame.bitmap.height * 10
        guard let output = makeOutputBitmap(from: frame.bitmap, totalHeightPixels: initialCapacity) else { return }

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
            guard let grown = makeOutputBitmap(from: bitmap, totalHeightPixels: newCapacity) else { return }
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

        guard let croppedRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: previewBitmap.width,
            pixelsHigh: previewHeightPixels,
            bitsPerSample: previewBitmap.rep.bitsPerSample,
            samplesPerPixel: previewBitmap.rep.samplesPerPixel,
            hasAlpha: previewBitmap.rep.hasAlpha,
            isPlanar: false,
            colorSpaceName: previewBitmap.rep.colorSpaceName,
            bitmapFormat: previewBitmap.rep.bitmapFormat,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let croppedData = croppedRep.bitmapData else {
            return
        }

        let bytesPerRow = min(previewBitmap.bytesPerRow, croppedRep.bytesPerRow)
        for row in 0..<previewHeightPixels {
            let sourceOffset = row * previewBitmap.bytesPerRow
            let destinationOffset = row * croppedRep.bytesPerRow
            memcpy(
                croppedData.advanced(by: destinationOffset),
                previewBitmap.data.advanced(by: sourceOffset),
                bytesPerRow
            )
        }

        let totalHeightPoints = CGFloat(previewHeightPixels) / previewScale
        croppedRep.size = NSSize(width: previewPointWidth, height: totalHeightPoints)

        let image = NSImage(size: croppedRep.size)
        image.addRepresentation(croppedRep)

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
            return firstFrame.image
        }

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

        stitchedBitmap.rep.size = NSSize(width: firstFrame.image.size.width, height: totalHeightPoints)
        let image = NSImage(size: stitchedBitmap.rep.size)
        image.addRepresentation(stitchedBitmap.rep)
        return image
    }

    // MARK: - Overlap Detection

    private func findOverlap(
        previous: BitmapData,
        current: BitmapData,
        expectedNewContentPixels: Int?
    ) -> Int {
        let width = min(previous.width, current.width)
        let height = min(previous.height, current.height)
        guard width > 0, height > 0 else { return 0 }

        let minNewContent = max(8, height / 200)
        let minOverlap = max(12, height / 40)
        let maxOverlap = height - minNewContent
        guard minOverlap <= maxOverlap else { return 0 }

        let sampleCols = sampledColumns(width: width, count: min(44, max(20, width / 18)))
        let previousRowEnergy = rowEnergies(in: previous, sampleCols: sampleCols)
        let currentRowEnergy = rowEnergies(in: current, sampleCols: sampleCols)
        let fullRange = minOverlap...maxOverlap
        let hint = overlapHint(
            height: height,
            minNewContent: minNewContent,
            minOverlap: minOverlap,
            maxOverlap: maxOverlap,
            explicitNewContentPixels: expectedNewContentPixels
        )

        let coarseStep = max(2, height / 140)
        var coarseCandidates = collectCoarseCandidates(
            in: preferredRange(for: hint, boundedBy: fullRange),
            step: coarseStep,
            previous: previous,
            current: current,
            height: height,
            sampleCols: sampleCols,
            previousRowEnergy: previousRowEnergy,
            currentRowEnergy: currentRowEnergy,
            hint: hint,
            maxSampleRows: 40,
            limit: 6
        )

        if preferredRange(for: hint, boundedBy: fullRange) != fullRange {
            coarseCandidates.append(contentsOf: collectCoarseCandidates(
                in: fullRange,
                step: max(4, coarseStep * 2),
                previous: previous,
                current: current,
                height: height,
                sampleCols: sampleCols,
                previousRowEnergy: previousRowEnergy,
                currentRowEnergy: currentRowEnergy,
                hint: hint,
                maxSampleRows: 28,
                limit: 4
            ))
        }

        guard !coarseCandidates.isEmpty else { return hint?.overlapPixels ?? 0 }

        let fineCandidates = refineCandidates(
            coarseCandidates,
            fullRange: fullRange,
            coarseStep: coarseStep,
            previous: previous,
            current: current,
            height: height,
            sampleCols: sampleCols,
            previousRowEnergy: previousRowEnergy,
            currentRowEnergy: currentRowEnergy,
            hint: hint
        )

        guard !fineCandidates.isEmpty else { return hint?.overlapPixels ?? 0 }
        let sorted = fineCandidates.sorted(by: compareCandidates(_:_:))
        let bestCandidate = sorted[0]

        if bestCandidate.rawScore > 20, let hint {
            if let hintedCandidate = fineCandidates.first(where: { $0.overlapPixels == hint.overlapPixels }),
               hintedCandidate.rawScore <= bestCandidate.rawScore + 4 {
                return hintedCandidate.overlapPixels
            }
        }

        return bestCandidate.overlapPixels
    }

    private func overlapHint(
        height: Int,
        minNewContent: Int,
        minOverlap: Int,
        maxOverlap: Int,
        explicitNewContentPixels: Int?
    ) -> SearchHint? {
        let maxNewContent = height - minOverlap

        if let explicitNewContentPixels, explicitNewContentPixels > 0 {
            let clampedNewContent = clamp(explicitNewContentPixels, min: minNewContent, max: maxNewContent)
            return SearchHint(
                overlapPixels: height - clampedNewContent,
                tolerancePixels: max(28, min(height / 3, clampedNewContent / 2 + 24)),
                strength: 4.0
            )
        }

        guard let rollingMedian = median(of: recentNewContentPixels.suffix(5)) else { return nil }
        let clampedNewContent = clamp(rollingMedian, min: minNewContent, max: maxNewContent)

        return SearchHint(
            overlapPixels: height - clampedNewContent,
            tolerancePixels: max(48, min(height / 2, clampedNewContent)),
            strength: 1.8
        )
    }

    private func preferredRange(for hint: SearchHint?, boundedBy fullRange: ClosedRange<Int>) -> ClosedRange<Int> {
        guard let hint else { return fullRange }

        let lower = max(fullRange.lowerBound, hint.overlapPixels - hint.tolerancePixels)
        let upper = min(fullRange.upperBound, hint.overlapPixels + hint.tolerancePixels)
        if lower > upper {
            return fullRange
        }
        return lower...upper
    }

    private func collectCoarseCandidates(
        in range: ClosedRange<Int>,
        step: Int,
        previous: BitmapData,
        current: BitmapData,
        height: Int,
        sampleCols: [Int],
        previousRowEnergy: [Int],
        currentRowEnergy: [Int],
        hint: SearchHint?,
        maxSampleRows: Int,
        limit: Int
    ) -> [OverlapCandidate] {
        var candidates: [OverlapCandidate] = []

        for overlap in stride(from: range.lowerBound, through: range.upperBound, by: step) {
            let rawScore = overlapScore(
                previous: previous,
                current: current,
                overlapPixels: overlap,
                height: height,
                sampleCols: sampleCols,
                previousRowEnergy: previousRowEnergy,
                currentRowEnergy: currentRowEnergy,
                maxSampleRows: maxSampleRows
            )

            guard rawScore.isFinite else { continue }

            let candidate = OverlapCandidate(
                overlapPixels: overlap,
                rawScore: rawScore,
                adjustedScore: rawScore + priorPenalty(for: overlap, hint: hint)
            )

            candidates.append(candidate)
        }

        return Array(candidates.sorted(by: compareCandidates(_:_:)).prefix(limit))
    }

    private func refineCandidates(
        _ coarseCandidates: [OverlapCandidate],
        fullRange: ClosedRange<Int>,
        coarseStep: Int,
        previous: BitmapData,
        current: BitmapData,
        height: Int,
        sampleCols: [Int],
        previousRowEnergy: [Int],
        currentRowEnergy: [Int],
        hint: SearchHint?
    ) -> [OverlapCandidate] {
        var overlapsToCheck = Set<Int>()

        for candidate in coarseCandidates {
            let lower = max(fullRange.lowerBound, candidate.overlapPixels - coarseStep * 2)
            let upper = min(fullRange.upperBound, candidate.overlapPixels + coarseStep * 2)
            for overlap in lower...upper {
                overlapsToCheck.insert(overlap)
            }
        }

        if let hint {
            let lower = max(fullRange.lowerBound, hint.overlapPixels - max(8, hint.tolerancePixels / 3))
            let upper = min(fullRange.upperBound, hint.overlapPixels + max(8, hint.tolerancePixels / 3))
            for overlap in lower...upper {
                overlapsToCheck.insert(overlap)
            }
        }

        return overlapsToCheck.map { overlap in
            let rawScore = overlapScore(
                previous: previous,
                current: current,
                overlapPixels: overlap,
                height: height,
                sampleCols: sampleCols,
                previousRowEnergy: previousRowEnergy,
                currentRowEnergy: currentRowEnergy,
                maxSampleRows: 96
            )

            return OverlapCandidate(
                overlapPixels: overlap,
                rawScore: rawScore,
                adjustedScore: rawScore + priorPenalty(for: overlap, hint: hint)
            )
        }.filter(\.rawScore.isFinite)
    }

    private func overlapScore(
        previous: BitmapData,
        current: BitmapData,
        overlapPixels: Int,
        height: Int,
        sampleCols: [Int],
        previousRowEnergy: [Int],
        currentRowEnergy: [Int],
        maxSampleRows: Int
    ) -> Double {
        guard overlapPixels > 0 else { return .greatestFiniteMagnitude }

        let rowSampleCount = min(overlapPixels, maxSampleRows)
        let rowStep = max(1, overlapPixels / rowSampleCount)

        var weightedDiff = 0
        var totalWeight = 0
        var informativeRows = 0

        for row in stride(from: 0, to: overlapPixels, by: rowStep) {
            let previousRow = height - overlapPixels + row
            let currentRow = row
            let rowEnergy = max(previousRowEnergy[previousRow], currentRowEnergy[currentRow])
            let weight = max(1, rowEnergy / 6)
            var rowDiff = 0

            for col in sampleCols {
                rowDiff += pixelDiff(previous.pixel(x: col, y: previousRow), current.pixel(x: col, y: currentRow))
            }

            weightedDiff += rowDiff * weight
            totalWeight += sampleCols.count * weight
            if rowEnergy > 10 {
                informativeRows += 1
            }
        }

        guard totalWeight > 0 else { return .greatestFiniteMagnitude }
        guard informativeRows >= max(2, rowSampleCount / 12) else { return .greatestFiniteMagnitude }

        return Double(weightedDiff) / Double(totalWeight)
    }

    private func priorPenalty(for overlapPixels: Int, hint: SearchHint?) -> Double {
        guard let hint else { return 0 }

        let distance = abs(overlapPixels - hint.overlapPixels)
        let normalized = Double(distance) / Double(max(1, hint.tolerancePixels))
        if distance <= hint.tolerancePixels {
            return normalized * hint.strength
        }

        return normalized * hint.strength * 2.2
    }

    private func compareCandidates(_ lhs: OverlapCandidate, _ rhs: OverlapCandidate) -> Bool {
        let scoreGap = abs(lhs.adjustedScore - rhs.adjustedScore)
        if scoreGap < 0.75 {
            if lhs.overlapPixels != rhs.overlapPixels {
                return lhs.overlapPixels > rhs.overlapPixels
            }
            return lhs.rawScore < rhs.rawScore
        }

        if lhs.adjustedScore != rhs.adjustedScore {
            return lhs.adjustedScore < rhs.adjustedScore
        }

        return lhs.rawScore < rhs.rawScore
    }

    private func rememberNewContentPixels(_ pixels: Int) {
        recentNewContentPixels.append(pixels)
        if recentNewContentPixels.count > 6 {
            recentNewContentPixels.removeFirst(recentNewContentPixels.count - 6)
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

    private func rowEnergies(in bitmap: BitmapData, sampleCols: [Int]) -> [Int] {
        guard sampleCols.count > 1 else { return Array(repeating: 1, count: bitmap.height) }

        return (0..<bitmap.height).map { row in
            var total = 0
            var previousLuma = luminance(of: bitmap.pixel(x: sampleCols[0], y: row))

            for col in sampleCols.dropFirst() {
                let currentLuma = luminance(of: bitmap.pixel(x: col, y: row))
                total += abs(currentLuma - previousLuma)
                previousLuma = currentLuma
            }

            return max(1, total / max(1, sampleCols.count - 1))
        }
    }

    private func luminance(of pixel: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        (77 * Int(pixel.r) + 150 * Int(pixel.g) + 29 * Int(pixel.b)) >> 8
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

        return BitmapData(rep: rep)
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

    private func median<S: Sequence>(of values: S) -> Int? where S.Element == Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    private final class BitmapData {
        let rep: NSBitmapImageRep
        let data: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int
        private let bytesPerPixel: Int

        init?(rep: NSBitmapImageRep) {
            guard let data = rep.bitmapData else { return nil }
            self.rep = rep
            self.data = data
            self.bytesPerRow = rep.bytesPerRow
            self.width = rep.pixelsWide
            self.height = rep.pixelsHigh
            self.bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        }

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return (0, 0, 0)
            }

            let offset = y * bytesPerRow + x * bytesPerPixel
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        var bytesPerPixelValue: Int { bytesPerPixel }
    }
}
