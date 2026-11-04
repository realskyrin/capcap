import CoreGraphics
import Vision

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
        let fixedTop: Int
        let fixedBottom: Int
    }

    func match(previous: CGImage, current: CGImage, expectedShift: CGFloat? = nil) -> Match {
        guard previous.width == current.width, previous.height == current.height,
              previous.width >= 40, previous.height >= 48,
              let before = GrayFrame(previous), let after = GrayFrame(current) else {
            return .unmatched
        }
        if before.pixels == after.pixels { return .unchanged }
        let movement = Movement(before: before, after: after)

        let minimumOverlap = max(24, min(96, before.height / 10))
        let limit = before.height - minimumOverlap
        let coarseStep = max(2, before.height / 360)
        let stationary = stationaryEdges(before: before, after: after)
        var attempted: [Attempt: CachedEvidence] = [:]
        var edgeCache: [Int: (top: Int, bottom: Int)] = [:]
        func inspect(_ shift: Int, step: Int) -> Evidence? {
            guard shift != 0, abs(shift) <= limit else { return nil }
            let attempt = Attempt(shift: shift, step: step)
            if let cached = attempted[attempt] {
                if case let .aligned(evidence) = cached { return evidence }
                return nil
            }
            // Fixed chrome must be excluded before testing global agreement,
            // rather than making its removal depend on that agreement first.
            let edges = edgeCache[shift] ?? fixedEdges(before: before, after: after, shift: shift, stationary: stationary)
            edgeCache[shift] = edges
            let matched = evidence(
                before: before, after: after, shift: shift,
                top: edges.top, bottom: edges.bottom, step: step, movement: movement
            )
            attempted[attempt] = matched.map(CachedEvidence.aligned) ?? .rejected
            return matched
        }
        func result(_ evidence: Evidence) -> Match {
            if evidence.shift < 0 { return .unchanged }
            return .aligned(Alignment(shift: evidence.shift, fixedTop: evidence.top, fixedBottom: evidence.bottom))
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
            guard let best = verified.first else { return (nil, false) }
            if verified.dropFirst().contains(where: { couldConflict($0, with: best) }) {
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
        guard let best = verified.best else {
            // A small changing region can also be new content entering a
            // mostly blank viewport. Failure to prove its offset is not proof
            // that nothing was missed, even when most pixels are stationary.
            return .unmatched
        }
        if verified.ambiguous { return .unmatched }
        return result(best)
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
        abs(candidate.shift - best.shift) > 2 && candidate.quality >= best.quality - 0.025 &&
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
            let sampleWidth = min(192, image.width)
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
        let top: Int
        let bottom: Int
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
        var bands = [Band](repeating: Band(), count: 8)
        let columns = before.columns
        let minimumRowDetail = max(3, columns.count / 50)
        var allSamples = 0, allMatches = 0, allGoodRows = 0, allBadRows = 0
        for y in stride(from: start, to: end, by: step) {
            let previousBase = (y + shift) * before.width
            let currentBase = y * before.width
            var samples = 0, matches = 0, error = 0
            var tileSamples = TileCounts()
            var tileMatches = TileCounts()
            for x in columns {
                let previousIndex = previousBase + x
                let currentIndex = currentBase + x
                // Flat white backgrounds and stationary sidebars are not votes
                // for a translation, even when they occupy most of the image.
                guard movement[currentIndex] != 0,
                      max(before.gradients[previousIndex], after.gradients[currentIndex]) >= 10 else {
                    continue
                }
                let difference = abs(Int(before.pixels[previousIndex]) - Int(after.pixels[currentIndex]))
                let tile = min(3, (x - columns.lowerBound) * 4 / columns.count)
                samples += 1
                tileSamples.increment(tile)
                error += min(difference, 64)
                if difference <= 14 { matches += 1; tileMatches.increment(tile) }
            }
            guard samples >= minimumRowDetail else { continue }
            allSamples += samples
            allMatches += matches
            let band = min(7, (y - start) * 8 / length)
            if matches * 100 >= samples * 82, error <= samples * 13 {
                allGoodRows += 1
                bands[band].goodRows += 1
                bands[band].samples += samples
                bands[band].matches += matches
                bands[band].error += error
                bands[band].firstRow = min(bands[band].firstRow, y)
                bands[band].lastRow = y
                for tile in 0..<4 where tileSamples.value(tile) >= 2 && tileMatches.value(tile) * 100 >= tileSamples.value(tile) * 82 {
                    bands[band].horizontal |= 1 << tile
                }
            } else {
                allBadRows += 1
                bands[band].badRows += 1
            }
        }
        let useful = bands.filter { $0.goodRows >= 1 && $0.goodRows >= $0.badRows * 2 }
        let rows = useful.reduce(0) { $0 + $1.goodRows }
        let samples = useful.reduce(0) { $0 + $1.samples }
        let horizontal = useful.reduce(0) { $0 | $1.horizontal }
        // Local animations may spoil a few rows. They must not let us discard
        // most of the frame's contrary evidence and accept only three islands.
        guard useful.count >= 3,
              allGoodRows >= allBadRows * 2,
              allMatches * 100 >= allSamples * 72,
              rows >= max(6, length / (60 * step)),
              samples >= max(48, columns.count * 2 / step),
              let first = useful.map(\.firstRow).min(), let last = useful.map(\.lastRow).max(),
              last - first >= length / 3 else { return nil }
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
            shift: shift, top: top, bottom: bottom,
            quality: Double(matches) / Double(samples) - Double(error) / Double(samples * 256),
            support: Double(samples * step), bands: useful.count
        )
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
        if abs(lhs.quality - rhs.quality) > 0.005 { return lhs.quality > rhs.quality }
        if lhs.bands != rhs.bands { return lhs.bands > rhs.bands }
        if abs(lhs.support - rhs.support) > min(lhs.support, rhs.support) * 0.1 {
            return lhs.support > rhs.support
        }
        if let expectedShift, expectedShift.isFinite {
            return abs(CGFloat(lhs.shift) - expectedShift) < abs(CGFloat(rhs.shift) - expectedShift)
        }
        return abs(lhs.shift) < abs(rhs.shift)
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
                let maximum = before.height / 3
                var top = 0, bottom = 0
                while top < maximum, sameRow(top) { top += 1 }
                while bottom < maximum, sameRow(before.height - 1 - bottom) { bottom += 1 }
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
}
