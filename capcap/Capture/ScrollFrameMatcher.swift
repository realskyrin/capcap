import CoreGraphics
import Vision

// Adapted from the frame matcher in capcap PR #222.
/// Measures a downward scroll in backing pixels. Registration is only a proposal:
/// several separated bands of actual, moving image detail must agree before a
/// caller may add any rows to the result.
struct ScrollFrameMatcher {
    enum Match {
        case aligned(Alignment)
        case unchanged
        case unmatched
    }

    struct Alignment {
        let shift: Int
        /// A verified row of moving content in the current frame.
        let joinRow: Int
    }

    func match(previous: CGImage, current: CGImage, expectedShift: CGFloat? = nil) -> Match {
        guard previous.width == current.width, previous.height == current.height,
              let before = GrayFrame(previous), let after = GrayFrame(current) else {
            return .unmatched
        }
        if before.pixels == after.pixels { return .unchanged }
        if before.height < 48 { return matchShortViewport(before: before, after: after) }
        let movement = Movement(before: before, after: after)

        let minimumOverlap = max(24, min(96, before.height / 10))
        let limit = before.height - minimumOverlap
        let coarseStep = max(2, before.height / 360)
        let stationary = stationaryEdges(before: before, after: after)
        var attempted: [Attempt: CachedEvidence] = [:]
        var edgeCache: [Int: (top: Int, bottom: Int)] = [:]
        func edges(for shift: Int) -> (top: Int, bottom: Int) {
            if let cached = edgeCache[shift] { return cached }
            // Exclude fixed chrome before testing agreement across the overlap.
            let edges = fixedEdges(before: before, after: after, shift: shift, stationary: stationary)
            edgeCache[shift] = edges
            return edges
        }
        func inspect(_ shift: Int, step: Int) -> Evidence? {
            guard shift != 0, abs(shift) <= limit else { return nil }
            let attempt = Attempt(shift: shift, step: step)
            if let cached = attempted[attempt] {
                if case let .aligned(evidence) = cached { return evidence }
                return nil
            }
            let edge = edges(for: shift)
            let matched = evidence(
                before: before, after: after, shift: shift,
                top: edge.top, bottom: edge.bottom, step: step, movement: movement
            )
            attempted[attempt] = matched.map(CachedEvidence.aligned) ?? .rejected
            return matched
        }
        func result(_ evidence: Evidence) -> Match {
            if evidence.shift < 0 { return .unchanged }
            return .aligned(Alignment(shift: evidence.shift, joinRow: evidence.joinRow))
        }

        let nativeEstimate = visionShift(previous: before, current: after)
        let nativeEvidence = nativeEstimate.flatMap { inspect($0, step: 1) }
        // Moving anchors serve both recovery and ambiguity checks. A strong
        // global registration can still choose the wrong repeated list row.
        let rows = rowCandidates(before: before, after: after, limit: limit, movement: movement)
        let strongNative = nativeEvidence.flatMap { $0.quality >= 0.97 && $0.bands >= 5 ? $0 : nil }
        let recovered = strongNative == nil ? rows.first.flatMap { $0.votes >= 3 ? inspect($0.shift, step: 1) : nil } : nil
        let strongEvidence = strongNative ?? recovered.flatMap { $0.quality >= 0.97 && $0.bands >= 5 ? $0 : nil }
        var candidates = Set<Int>()
        func propose(_ shift: Int, refine: Bool = false) {
            for adjustment in (refine ? -3...3 : 0...0) {
                let value = shift + adjustment
                if value != 0, abs(value) <= limit { candidates.insert(value) }
            }
        }

        // Small terminal scrolls must not disappear behind an arbitrary minimum
        // distance. They still need the same visual proof as a larger scroll.
        if strongEvidence == nil {
            for shift in 1...7 { propose(shift); propose(-shift) }
        }
        if let expectedShift, expectedShift.isFinite, abs(expectedShift) <= CGFloat(limit) {
            propose(Int(expectedShift.rounded()), refine: strongEvidence == nil)
        }
        if let estimate = nativeEstimate, abs(estimate) <= limit {
            propose(estimate, refine: strongEvidence == nil)
            propose(-estimate, refine: strongEvidence == nil)
        }
        for row in rows { propose(row.shift) }

        func verifiedCandidates() -> (best: Evidence?, ambiguous: Bool) {
            var coarse = candidates.sorted().compactMap { inspect($0, step: coarseStep) }
            coarse.sort { ranksBefore($0, $1, expectedShift: expectedShift) }
            // Every accepted offset is checked at the original Y resolution.
            // Registration and the requested wheel distance only propose it.
            let verified: [Evidence]
            if let strongEvidence {
                verified = [strongEvidence]
            } else {
                var full = coarse.prefix(3).compactMap { inspect($0.shift, step: 1) }
                if let nativeEvidence, !full.contains(where: { $0.shift == nativeEvidence.shift }) {
                    full.append(nativeEvidence)
                }
                verified = full.sorted { ranksBefore($0, $1, expectedShift: expectedShift) }
            }
            guard let seed = verified.first else { return (nil, false) }
            var best = seed
            // A rounded estimate can pass on softly antialiased text even if
            // the neighboring backing row lines up more accurately.
            let neighbors = seed.quality < 1 ? [-2, -1, 1, 2].compactMap { inspect(seed.shift + $0, step: 1) } : []
            for neighbor in neighbors where neighbor.quality > best.quality &&
                neighbor.bands >= seed.bands - 1 && neighbor.support >= seed.support * 0.75 {
                best = neighbor
            }
            if (verified + neighbors).contains(where: { couldConflict($0, with: best) }) {
                return (best, true)
            }
            // Do not stop at three full checks if another sampled candidate
            // could explain the same content. All paths use this same gate.
            for candidate in coarse where couldConflict(candidate, with: best) {
                if let full = inspect(candidate.shift, step: 1), couldConflict(full, with: best) {
                    return (best, true)
                }
            }
            return (best, false)
        }

        var verified = verifiedCandidates()
        if verified.best == nil, !movement.mostlyStationary {
            // Fixed sidebars can dominate global registration. Only recovery
            // pays for five bounded regions; matching regions vote for one Y
            // offset, which still needs exactly the same pixel verification.
            for estimate in regionalVisionShifts(previous: before, current: after) {
                propose(estimate, refine: true)
            }
            verified = verifiedCandidates()
        }
        if let best = verified.best {
            return verified.ambiguous ? .unmatched : result(best)
        }

        // Animation can spoil more rows than agree on the scroll. Retry while
        // requiring contrary rows to support a distinct offset.
        for shift in 1...7 { propose(shift); propose(-shift) }
        if let expectedShift, expectedShift.isFinite, abs(expectedShift) <= CGFloat(limit + 3) {
            propose(Int(expectedShift.rounded()), refine: true)
        }
        if let nativeEstimate {
            propose(nativeEstimate, refine: true)
            propose(-nativeEstimate, refine: true)
        }
        let tolerant = matchAroundChangingContent(
            before: before, after: after, movement: movement, candidates: candidates, limit: limit,
            coarseStep: coarseStep, expectedShift: expectedShift, edges: edges(for:)
        )
        if let best = tolerant.best {
            return tolerant.ambiguous ? .unmatched : result(best)
        }
        return changesStayInPlace(before: before, stationary: stationary) ? .unchanged : .unmatched
    }

    /// Very short selections have too few rows for multi-band registration.
    /// Accept a shift only if it uniquely lines up the entire overlapping body.
    private func matchShortViewport(before: GrayFrame, after: GrayFrame) -> Match {
        func rows(_ frame: GrayFrame) -> [ArraySlice<UInt8>] {
            (0..<frame.height).map { y in
                let start = y * frame.width
                return frame.pixels[start..<(start + frame.width)]
            }
        }
        let old = rows(before), new = rows(after)
        guard let first = old.indices.first(where: { old[$0] != new[$0] }),
              let last = old.indices.last(where: { old[$0] != new[$0] }) else { return .unchanged }
        let minimumOverlap = max(2, min(6, before.height / 4))
        let limit = last - first + 1 - minimumOverlap
        guard limit > 0 else { return .unmatched }

        var accepted: Alignment?
        for shift in -limit...limit where shift != 0 {
            let start = first + max(0, -shift)
            let end = last - max(0, shift)
            let overlap = start...end
            guard overlap.allSatisfy({ new[$0] == old[$0 + shift] }),
                  overlap.contains(where: { new[$0] != new[start] }) else { continue }
            guard accepted == nil else { return .unmatched }
            accepted = Alignment(shift: shift, joinRow: (start + end) / 2)
        }
        guard let accepted else { return .unmatched }
        return accepted.shift > 0 ? .aligned(accepted) : .unchanged
    }

    private struct Attempt: Hashable {
        let shift: Int
        let step: Int
    }

    private enum CachedEvidence {
        case rejected
        case aligned(Evidence)
    }

    private func couldConflict(_ candidate: Evidence, with best: Evidence) -> Bool {
        let distance = abs(candidate.shift - best.shift)
        let qualityMargin = distance <= 2 ? 0.0005 : 0.025
        return distance > 0 && candidate.quality >= best.quality - qualityMargin &&
            candidate.support >= best.support * 0.75 && candidate.bands >= best.bands - 1
    }

    /// A scoped view only used inside `withView`; its pointers never outlive the
    /// owning arrays. The compared offsets are bounded before entering loops.
    private struct PixelView {
        let width: Int
        let height: Int
        let pixels: UnsafePointer<UInt8>
        let gradients: UnsafePointer<UInt8>
        var columns: Range<Int> { 3..<(width - max(5, width / 24)) }
    }

    private struct GrayFrame {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let gradients: [UInt8]
        var columns: Range<Int> { 3..<(width - max(5, width / 24)) }

        func withView<Result>(_ body: (PixelView) -> Result) -> Result {
            pixels.withUnsafeBufferPointer { pixels in
                gradients.withUnsafeBufferPointer { gradients in
                    body(PixelView(width: width, height: height, pixels: pixels.baseAddress!, gradients: gradients.baseAddress!))
                }
            }
        }

        var image: CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }

        init?(_ image: CGImage) {
            // Keep the sampling grid valid even for a narrow vertical selection.
            let sampleWidth = min(192, max(40, image.width))
            let imageHeight = image.height
            var bytes = [UInt8](repeating: 255, count: sampleWidth * imageHeight)
            let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(
                    data: storage.baseAddress, width: sampleWidth, height: imageHeight,
                    bitsPerComponent: 8, bytesPerRow: sampleWidth,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: sampleWidth, height: imageHeight))
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: imageHeight))
                return true
            }
            guard rendered else { return nil }
            width = sampleWidth
            height = imageHeight
            pixels = bytes
            var detail = [UInt8](repeating: 0, count: bytes.count)
            bytes.withUnsafeBufferPointer { source in
                detail.withUnsafeMutableBufferPointer { destination in
                    // All offsets are bounded by the image's allocated extent.
                    // Pointer access avoids millions of redundant array bounds
                    // checks in the default debug-built menu bar app.
                    guard let input = source.baseAddress, let output = destination.baseAddress else { return }
                    for y in 0..<imageHeight {
                        let above = max(0, y - 1) * sampleWidth
                        let below = min(imageHeight - 1, y + 1) * sampleWidth
                        for x in 1..<(sampleWidth - 1) {
                            let index = y * sampleWidth + x
                            let value = Int(input[index])
                            let horizontal = max(abs(value - Int(input[index - 1])), abs(value - Int(input[index + 1])))
                            let vertical = max(abs(value - Int(input[above + x])), abs(value - Int(input[below + x])))
                            output[index] = UInt8(max(horizontal, vertical))
                        }
                    }
                }
            }
            gradients = detail
        }
    }

    /// The same temporal mask is used when proposing and verifying offsets.
    /// Stationary chrome cannot vote for a candidate that validation ignores.
    private struct Movement {
        let pixels: [UInt8]
        let mostlyStationary: Bool

        init(before: GrayFrame, after: GrayFrame) {
            var mask = [UInt8](repeating: 0, count: before.pixels.count)
            var changed = 0
            var tiles: UInt32 = 0
            var stationary = true
            let columns = before.columns
            let changedLimit = before.height * columns.count / 25
            before.withView { before in
                after.withView { after in
                    mask.withUnsafeMutableBufferPointer { mask in
                        for y in 0..<before.height {
                            for x in columns {
                                let index = y * before.width + x
                                guard abs(Int(before.pixels[index]) - Int(after.pixels[index])) > 14 else { continue }
                                mask[index] = 1
                                if stationary {
                                    changed += 1
                                    let tile = min(7, y * 8 / before.height) * 4 +
                                        min(3, (x - columns.lowerBound) * 4 / columns.count)
                                    tiles |= UInt32(1) << tile
                                    if tiles.nonzeroBitCount > 2 || changed > changedLimit { stationary = false }
                                }
                            }
                        }
                    }
                }
            }
            pixels = mask
            mostlyStationary = stationary
        }
    }

    private struct Evidence {
        let shift: Int
        let joinRow: Int
        let quality: Double
        let support: Double
        let bands: Int
    }

    private struct Band {
        var goodRows = 0
        var badRows = 0
        var samples = 0
        var matches = 0
        var error = 0
        var horizontal = 0
        var firstRow = Int.max
        var lastRow = 0
    }

    private enum RowStatus {
        case empty, good, bad
    }

    private struct RowEvidence {
        var samples = 0
        var matches = 0
        var error = 0
        var horizontal = 0
        var status = RowStatus.empty
    }

    private struct EvidenceSummary {
        private var bands = [Band](repeating: Band(), count: 8)
        private var allSamples = 0
        private var allMatches = 0
        private(set) var allGoodRows = 0
        private var allBadRows = 0

        mutating func add(_ row: RowEvidence, at y: Int, band: Int) {
            guard row.status != .empty else { return }
            allSamples += row.samples
            allMatches += row.matches
            if row.status == .good {
                allGoodRows += 1
                bands[band].goodRows += 1
                bands[band].samples += row.samples
                bands[band].matches += row.matches
                bands[band].error += row.error
                bands[band].firstRow = min(bands[band].firstRow, y)
                bands[band].lastRow = y
                bands[band].horizontal |= row.horizontal
            } else {
                allBadRows += 1
                bands[band].badRows += 1
            }
        }

        func verified(
            shift: Int, length: Int, step: Int, columns: Int, minimumSpanDivisor: Int = 3
        ) -> Evidence? {
            let useful = bands.filter { $0.goodRows >= 1 && $0.goodRows >= $0.badRows * 2 }
            let rows = useful.reduce(0) { $0 + $1.goodRows }
            let samples = useful.reduce(0) { $0 + $1.samples }
            let horizontal = useful.reduce(0) { $0 | $1.horizontal }
            guard useful.count >= 3,
                  allGoodRows >= allBadRows * 2,
                  allMatches * 100 >= allSamples * 72,
                  rows >= max(6, length / (60 * step)),
                  samples >= max(48, columns * 2 / step),
                  let first = useful.map(\.firstRow).min(), let last = useful.map(\.lastRow).max(),
                  last - first >= length / minimumSpanDivisor else { return nil }
            // A narrow article/code column can be the only moving detail in a
            // white viewport. Require much stronger vertical support in that case.
            if horizontal.nonzeroBitCount < 2 {
                guard horizontal.nonzeroBitCount == 1, useful.count >= 5,
                      rows >= max(12, length / (30 * step)),
                      last - first >= length / 2 else { return nil }
            }
            let matches = useful.reduce(0) { $0 + $1.matches }
            let error = useful.reduce(0) { $0 + $1.error }
            return Evidence(
                shift: shift, joinRow: useful[useful.count / 2].firstRow,
                quality: Double(matches) / Double(samples) - Double(error) / Double(samples * 256),
                support: Double(samples * step), bands: useful.count
            )
        }
    }

    private func evidence(
        before: GrayFrame, after: GrayFrame, shift: Int, top: Int, bottom: Int, step: Int, movement: Movement
    ) -> Evidence? {
        before.withView { before in
            after.withView { after in
                movement.pixels.withUnsafeBufferPointer { movement in
                    evidence(
                        before: before, after: after, shift: shift, top: top, bottom: bottom,
                        step: step, movement: movement.baseAddress!
                    )
                }
            }
        }
    }

    private func evidence(
        before: PixelView, after: PixelView, shift: Int, top: Int, bottom: Int, step: Int, movement: UnsafePointer<UInt8>
    ) -> Evidence? {
        let start = top + max(0, -shift)
        let end = before.height - bottom - max(0, shift)
        let length = end - start
        guard length >= max(24, min(96, before.height / 10)) else { return nil }
        let columns = before.columns
        let minimumRowDetail = max(3, columns.count / 50)
        var summary = EvidenceSummary()
        for y in stride(from: start, to: end, by: step) {
            let row = compareRow(
                y, shift: shift, before: before, after: after, movement: movement,
                columns: columns, minimumRowDetail: minimumRowDetail
            )
            summary.add(row, at: y, band: min(7, (y - start) * 8 / length))
        }
        return summary.verified(shift: shift, length: length, step: step, columns: columns.count)
    }

    private func compareRow(
        _ y: Int, shift: Int, before: PixelView, after: PixelView, movement: UnsafePointer<UInt8>,
        columns: Range<Int>, minimumRowDetail: Int
    ) -> RowEvidence {
        let previousBase = (y + shift) * before.width
        let currentBase = y * before.width
        var row = RowEvidence()
        var tileSamples = TileCounts()
        var tileMatches = TileCounts()
        for x in columns {
            let previousIndex = previousBase + x
            let currentIndex = currentBase + x
            // Only detail that changed at this position can vote for a scroll.
            guard movement[currentIndex] != 0,
                  max(before.gradients[previousIndex], after.gradients[currentIndex]) >= 10 else { continue }
            let difference = abs(Int(before.pixels[previousIndex]) - Int(after.pixels[currentIndex]))
            let tile = min(3, (x - columns.lowerBound) * 4 / columns.count)
            row.samples += 1
            tileSamples.increment(tile)
            row.error += min(difference, 64)
            if difference <= 14 {
                row.matches += 1
                tileMatches.increment(tile)
            }
        }
        guard row.samples >= minimumRowDetail else { return row }
        guard row.matches * 100 >= row.samples * 82, row.error <= row.samples * 13 else {
            row.status = .bad
            return row
        }
        row.status = .good
        for tile in 0..<4 where tileSamples.value(tile) >= 2 && tileMatches.value(tile) * 100 >= tileSamples.value(tile) * 82 {
            row.horizontal |= 1 << tile
        }
        return row
    }

    private struct TileCounts {
        var first = 0, second = 0, third = 0, fourth = 0
        mutating func increment(_ tile: Int) {
            switch tile {
            case 0: first += 1
            case 1: second += 1
            case 2: third += 1
            default: fourth += 1
            }
        }
        func value(_ tile: Int) -> Int {
            switch tile {
            case 0: return first
            case 1: return second
            case 2: return third
            default: return fourth
            }
        }
    }

    private func ranksBefore(_ lhs: Evidence, _ rhs: Evidence, expectedShift: CGFloat?) -> Bool {
        let leftQuality = Int((lhs.quality * 200).rounded())
        let rightQuality = Int((rhs.quality * 200).rounded())
        if leftQuality != rightQuality { return leftQuality > rightQuality }
        if lhs.bands != rhs.bands { return lhs.bands > rhs.bands }
        if lhs.support != rhs.support { return lhs.support > rhs.support }
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        if let expectedShift, expectedShift.isFinite {
            let leftError = abs(CGFloat(lhs.shift) - expectedShift)
            let rightError = abs(CGFloat(rhs.shift) - expectedShift)
            if leftError != rightError { return leftError < rightError }
        }
        if abs(lhs.shift) != abs(rhs.shift) { return abs(lhs.shift) < abs(rhs.shift) }
        return lhs.shift < rhs.shift
    }

    private func visionShift(previous: GrayFrame, current: GrayFrame) -> Int? {
        // Identical cropping removes the usual scrollbar and much of a fixed
        // title bar without changing the registration's original-pixel Y scale.
        let inset = previous.height / 10
        let rect = CGRect(
            x: previous.width / 40, y: inset,
            width: previous.width - max(12, previous.width / 16), height: previous.height - inset * 2
        )
        // Registration uses the already normalized narrow image too. Sending a
        // multi-megapixel Retina frame to Vision on every tick is unnecessary;
        // its Y remains full resolution, so ty is still an original pixel count.
        guard let target = previous.image, let source = current.image else { return nil }
        return visionShift(previous: target, current: source, rect: rect)
    }

    private func visionShift(previous: CGImage, current: CGImage, rect: CGRect) -> Int? {
        guard let target = previous.cropping(to: rect), let source = current.cropping(to: rect) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
        do { try VNImageRequestHandler(cgImage: source, options: [:]).perform([request]) }
        catch { return nil }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation,
              observation.alignmentTransform.ty.isFinite,
              abs(observation.alignmentTransform.ty) < CGFloat(previous.height),
              abs(observation.alignmentTransform.tx) <= max(3, CGFloat(previous.width) / 100) else { return nil }
        return Int(observation.alignmentTransform.ty.rounded())
    }

    private func regionalVisionShifts(previous: GrayFrame, current: GrayFrame) -> [Int] {
        guard let target = previous.image, let source = current.image else { return [] }
        let inset = max(2, previous.height / 20)
        let left = previous.columns.lowerBound
        let width = previous.columns.count
        let height = previous.height - inset * 2
        // Three vertical strips isolate left/right chrome. Two wide, separated
        // bands supply another estimate when detail occupies a narrow column.
        var regions: [CGRect] = (0..<3).map { column in
            let x = left + column * width / 3
            let right = left + (column + 1) * width / 3
            return CGRect(x: x, y: inset, width: right - x, height: height)
        }
        regions.append(CGRect(x: left, y: inset, width: width, height: height * 2 / 3))
        regions.append(CGRect(x: left, y: inset + height / 3, width: width, height: height * 2 / 3))
        let estimates = regions.compactMap { visionShift(previous: target, current: source, rect: $0) }
            .filter { $0 != 0 }.sorted()
        var groups: [[Int]] = []
        for estimate in estimates {
            if let last = groups.last, let first = last.first, estimate - first <= 2 {
                groups[groups.count - 1].append(estimate)
            } else {
                groups.append([estimate])
            }
        }
        return groups.sorted {
            $0.count == $1.count ? abs($0[$0.count / 2]) < abs($1[$1.count / 2]) : $0.count > $1.count
        }.map { $0[$0.count / 2] }
    }

    /// Bounded fallback when fixed chrome defeats global registration. Each
    /// anchor compares three rows of content detail, not a white row average.
    private struct RowProposal {
        let shift: Int
        let votes: Int
    }

    private func rowCandidates(before: GrayFrame, after: GrayFrame, limit: Int, movement: Movement) -> [RowProposal] {
        before.withView { before in
            after.withView { after in
                movement.pixels.withUnsafeBufferPointer { movement in
                    rowCandidates(before: before, after: after, limit: limit, movement: movement.baseAddress!)
                }
            }
        }
    }

    private func rowCandidates(
        before: PixelView, after: PixelView, limit: Int, movement: UnsafePointer<UInt8>
    ) -> [RowProposal] {
        var votes: [Int: Int] = [:]
        let columns = Array(stride(from: before.columns.lowerBound, to: before.columns.upperBound, by: max(1, before.columns.count / 32)))
        let height = before.height
        for band in 0..<12 {
            let start = max(2, band * height / 12)
            let end = min(height - 2, (band + 1) * height / 12)
            guard start < end else { continue }
            var anchor = start, strength = 0
            for y in start..<end {
                var score = 0
                for x in before.columns {
                    let index = y * before.width + x
                    guard movement[index] != 0 else { continue }
                    // Horizontal separators repeat at every list row. They
                    // have large vertical gradients but no location detail.
                    let horizontal = abs(Int(after.pixels[index - 1]) - Int(after.pixels[index + 1]))
                    if horizontal >= 10 {
                        score += min(32, abs(Int(before.pixels[index]) - Int(after.pixels[index])))
                    }
                }
                if score > strength { strength = score; anchor = y }
            }
            guard strength >= 48 else { continue }
            // Freeze the moving sample positions once per anchor. In addition
            // to excluding sidebars, this bounds the inner search to three
            // sparsely sampled rows instead of comparing the entire frame.
            var positions: [(offset: Int, x: Int)] = []
            for offset in [-2, 0, 2] {
                for x in columns where movement[(anchor + offset) * before.width + x] != 0 {
                    positions.append((offset, x))
                }
            }
            guard positions.count >= 10 else { continue }
            var matches: [Int] = []
            candidateOffsets: for distance in 1...limit {
                for sign in 0..<2 {
                    let previousY = anchor + (sign == 0 ? -distance : distance)
                    guard previousY >= 2, previousY < height - 2 else { continue }
                    var samples = 0, good = 0, error = 0
                    var rejected = false
                    for position in positions {
                        let p = (previousY + position.offset) * before.width + position.x
                        let c = (anchor + position.offset) * before.width + position.x
                        guard max(before.gradients[p], after.gradients[c]) >= 10 else { continue }
                        let difference = abs(Int(before.pixels[p]) - Int(after.pixels[c]))
                        samples += 1
                        error += min(difference, 64)
                        if difference <= 14 { good += 1 }
                        // Even if every remaining sample matched, these
                        // contradictions cannot meet the final 88%/mean-10 gate.
                        if (samples - good) * 100 > positions.count * 12 || error > positions.count * 10 {
                            rejected = true
                            break
                        }
                    }
                    if !rejected, samples >= 10, good * 100 >= samples * 88, error <= samples * 10 {
                        matches.append(previousY - anchor)
                        // Keep repeated matches as competing seam proposals.
                        // Dropping the whole anchor hides ambiguity from a
                        // confident native estimate. Nearest offsets provide
                        // the largest overlaps; 24 votes bound repetitive data.
                        if matches.count >= 24 { break candidateOffsets }
                    }
                }
            }
            for shift in matches { votes[shift, default: 0] += 1 }
        }
        return votes.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if abs($0.key) != abs($1.key) { return abs($0.key) < abs($1.key) }
            return $0.key < $1.key
        }.prefix(12).map { RowProposal(shift: $0.key, votes: $0.value) }
    }

    private func stationaryEdges(before: GrayFrame, after: GrayFrame) -> (top: Int, bottom: Int) {
        before.withView { before in
            after.withView { after in
                func sameRow(_ y: Int) -> Bool {
                    var changed = 0, error = 0
                    for x in before.columns {
                        let index = y * before.width + x
                        let difference = abs(Int(before.pixels[index]) - Int(after.pixels[index]))
                        error += difference
                        if difference > 8 { changed += 1 }
                    }
                    return changed <= max(1, before.columns.count / 100) && error <= before.columns.count * 3
                }
                var top = 0, bottom = 0
                while top < before.height, sameRow(top) { top += 1 }
                while bottom < before.height - top, sameRow(before.height - 1 - bottom) { bottom += 1 }
                return (top, bottom)
            }
        }
    }

    private func fixedEdges(
        before: GrayFrame, after: GrayFrame, shift: Int, stationary: (top: Int, bottom: Int)
    ) -> (top: Int, bottom: Int) {
        before.withView { before in
            after.withView { after in fixedEdges(before: before, after: after, shift: shift, stationary: stationary) }
        }
    }

    private func fixedEdges(
        before: PixelView, after: PixelView, shift: Int, stationary: (top: Int, bottom: Int)
    ) -> (top: Int, bottom: Int) {
        let distance = abs(shift)
        func frozenDetail(_ y: Int, comparisonY: Int, compareWithPrevious: Bool = false) -> Bool {
            guard comparisonY >= 0, comparisonY < before.height else { return false }
            var evidence = 0
            for x in before.columns {
                let index = y * before.width + x
                let comparisonIndex = comparisonY * before.width + x
                let comparison = compareWithPrevious ? before.pixels[comparisonIndex] : after.pixels[comparisonIndex]
                if before.gradients[index] >= 10,
                   abs(Int(before.pixels[index]) - Int(comparison)) > 16 {
                    evidence += 1
                }
            }
            return evidence >= max(4, before.columns.count / 16)
        }
        var top = 0
        for y in 0..<stationary.top {
            if frozenDetail(y, comparisonY: y + distance, compareWithPrevious: true) { top = y + 1 }
        }
        var hasFrozenBottomDetail = false
        for offset in 0..<stationary.bottom {
            let y = before.height - 1 - offset
            if frozenDetail(y, comparisonY: y - distance) { hasFrozenBottomDetail = true }
        }
        // A proven fixed border also owns the contiguous stationary padding
        // above it. Leaving that padding behind would replace document rows
        // with a blank seam. A wholly blank tail supplies no such evidence.
        // The complete proposed overlap is revalidated before returning it.
        let bottom = hasFrozenBottomDetail ? stationary.bottom : 0
        return (top, bottom)
    }

    private func matchAroundChangingContent(
        before: GrayFrame, after: GrayFrame, movement: Movement, candidates: Set<Int>, limit: Int,
        coarseStep: Int, expectedShift: CGFloat?, edges: (Int) -> (top: Int, bottom: Int)
    ) -> (best: Evidence?, ambiguous: Bool) {
        // A cached nil marks an offset with too little overlap after removing chrome.
        var tables: [Attempt: RowTable?] = [:]
        func table(_ shift: Int, step: Int) -> RowTable? {
            guard shift != 0, abs(shift) <= limit else { return nil }
            let attempt = Attempt(shift: shift, step: step)
            if let cached = tables[attempt] { return cached }
            let edge = edges(shift)
            let built = rowTable(
                before: before, after: after, shift: shift, top: edge.top, bottom: edge.bottom,
                step: step, movement: movement
            )
            tables.updateValue(built, forKey: attempt)
            return built
        }

        let shifts = candidates.sorted()
        // Soft video frames, gradients and blurred photos also line up at
        // neighboring offsets. Only sharp rows, such as detail in a panning
        // video, can establish competing motion or contradict a candidate.
        let smoothRows = verticallySmoothRows(before)
        func isSharp(_ y: Int, at shift: Int) -> Bool {
            let sourceRow = y + shift
            return smoothRows.indices.contains(sourceRow) && !smoothRows[sourceRow]
        }
        let plausible = shifts.filter { shift in
            table(shift, step: coarseStep)?.isPlausibleMotion { isSharp($0, at: shift) } == true
        }.compactMap { table($0, step: 1) }
        func inspect(_ shift: Int, step: Int) -> Evidence? {
            guard let candidate = table(shift, step: step) else { return nil }
            let rivals = plausible.filter { $0.shift != shift }
            return tolerantEvidence(candidate, columns: before.columns.count) { y in
                rivals.contains { rival in
                    rival.isGood(at: y) && isSharp(y, at: rival.shift)
                }
            }
        }

        let coarse = shifts.compactMap { inspect($0, step: coarseStep) }
            .sorted { ranksBefore($0, $1, expectedShift: expectedShift) }
        let verified = coarse.prefix(3).compactMap { inspect($0.shift, step: 1) }
            .sorted { ranksBefore($0, $1, expectedShift: expectedShift) }
        guard let seed = verified.first else { return (nil, false) }
        var best = seed
        let neighbors = seed.quality < 1 ? [-2, -1, 1, 2].compactMap { inspect(seed.shift + $0, step: 1) } : []
        for neighbor in neighbors where neighbor.quality > best.quality &&
            neighbor.bands >= seed.bands - 1 && neighbor.support >= seed.support * 0.75 {
            best = neighbor
        }
        if (verified + neighbors).contains(where: { couldConflict($0, with: best) }) {
            return (best, true)
        }
        for candidate in coarse where couldConflict(candidate, with: best) {
            if let full = inspect(candidate.shift, step: 1), couldConflict(full, with: best) {
                return (best, true)
            }
        }
        return (best, false)
    }

    /// Stores one verdict per sampled row so rechecking a candidate only aggregates its evidence.
    private struct RowTable {
        let shift: Int
        let start: Int
        let length: Int
        let step: Int
        let rows: [RowEvidence]

        func isGood(at y: Int) -> Bool {
            let offset = y - start
            guard offset >= 0, offset < length, offset.isMultiple(of: step) else { return false }
            return rows[offset / step].status == .good
        }

        /// Matching detail must span the overlap. A single block can be an animation.
        func isPlausibleMotion(counting include: (Int) -> Bool) -> Bool {
            var bands = 0, goodRows = 0, first = Int.max, last = 0
            for (index, row) in rows.enumerated() where row.status == .good {
                let offset = index * step
                guard include(start + offset) else { continue }
                goodRows += 1
                bands |= 1 << min(7, offset * 8 / length)
                first = min(first, offset)
                last = offset
            }
            return goodRows >= max(6, length / (60 * step)) &&
                bands.nonzeroBitCount >= 3 && last - first >= length / 3
        }
    }

    private func rowTable(
        before: GrayFrame, after: GrayFrame, shift: Int, top: Int, bottom: Int, step: Int, movement: Movement
    ) -> RowTable? {
        let start = top + max(0, -shift)
        let end = before.height - bottom - max(0, shift)
        let length = end - start
        guard length >= max(24, min(96, before.height / 10)) else { return nil }
        let columns = before.columns
        let minimumRowDetail = max(3, columns.count / 50)
        let rows = before.withView { before in
            after.withView { after in
                movement.pixels.withUnsafeBufferPointer { movement in
                    stride(from: start, to: end, by: step).map { y in
                        compareRow(
                            y, shift: shift, before: before, after: after, movement: movement.baseAddress!,
                            columns: columns, minimumRowDetail: minimumRowDetail
                        )
                    }
                }
            }
        }
        return RowTable(shift: shift, start: start, length: length, step: step, rows: rows)
    }

    private func tolerantEvidence(
        _ table: RowTable, columns: Int, hasContraryEvidence: (Int) -> Bool
    ) -> Evidence? {
        var summary = EvidenceSummary()
        var unexplainedRows = 0
        for (index, row) in table.rows.enumerated() {
            let offset = index * table.step
            let y = table.start + offset
            if row.status == .bad, !hasContraryEvidence(y) {
                unexplainedRows += 1
                continue
            }
            summary.add(row, at: y, band: min(7, offset * 8 / table.length))
        }
        guard summary.allGoodRows * 10 >= summary.allGoodRows + unexplainedRows else { return nil }
        // Animated blocks above and below can leave only a narrow band of still content in view.
        return summary.verified(
            shift: table.shift, length: table.length, step: table.step, columns: columns, minimumSpanDivisor: 8
        )
    }

    /// Checks the previous frame's detailed pixels for agreement one row up or down.
    private func verticallySmoothRows(_ frame: GrayFrame) -> [Bool] {
        frame.withView { frame in
            let columns = frame.columns
            let minimumRowDetail = max(3, columns.count / 50)
            return (0..<frame.height).map { y in
                let pixels = frame.pixels + y * frame.width
                let gradients = frame.gradients + y * frame.width
                func agrees(with neighbor: Int) -> Bool {
                    guard neighbor >= 0, neighbor < frame.height else { return false }
                    let neighboringPixels = frame.pixels + neighbor * frame.width
                    var samples = 0, matches = 0
                    for x in columns where gradients[x] >= 10 {
                        samples += 1
                        if abs(Int(pixels[x]) - Int(neighboringPixels[x])) <= 14 {
                            matches += 1
                        }
                    }
                    return samples >= minimumRowDetail && matches * 100 >= samples * 82
                }
                return agrees(with: y - 1) || agrees(with: y + 1)
            }
        }
    }

    /// A scroll would move the detail on either side of an in-place change.
    /// Ordinary fixed headers and footers are too thin to qualify, and changes
    /// reaching the top or bottom edge remain unproven.
    private func changesStayInPlace(before: GrayFrame, stationary: (top: Int, bottom: Int)) -> Bool {
        let height = before.height
        guard stationary.top >= height / 6, stationary.bottom >= height / 6,
              (stationary.top + stationary.bottom) * 5 >= height * 2 else { return false }

        return before.withView { before in
            let columns = before.columns
            let minimumRowDetail = max(3, columns.count / 50)
            let minimumRows = max(3, height / 100)
            func hasDetail(in rows: Range<Int>) -> Bool {
                var detailedRows = 0
                for y in rows {
                    let gradients = before.gradients + y * before.width
                    var detail = 0
                    for x in columns where gradients[x] >= 10 {
                        detail += 1
                        if detail == minimumRowDetail { break }
                    }
                    if detail == minimumRowDetail {
                        detailedRows += 1
                        if detailedRows == minimumRows { return true }
                    }
                }
                return false
            }
            return hasDetail(in: 0..<stationary.top) && hasDetail(in: (height - stationary.bottom)..<height)
        }
    }
}
