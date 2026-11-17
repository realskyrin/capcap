// 基于 ScrollSnap 74a613b 的 MIT 实现，版权与许可证见 ThirdParty/ScrollSnap
import AppKit
import Vision

enum ScrollOffsetEstimateSource: Equatable, Sendable {
    case pixelOverlap
    case fullFrameFallback
}

struct ScrollOffsetEstimate: Sendable {
    let translation: CGPoint
    let confidence: Float
    let source: ScrollOffsetEstimateSource
}

protocol ScrollOffsetEstimating: Sendable {
    func estimate(from currentImage: CGImage, to previousImage: CGImage) -> ScrollOffsetEstimate?
}

struct ScrollOffsetEstimator: ScrollOffsetEstimating {
    func estimate(from currentImage: CGImage, to previousImage: CGImage) -> ScrollOffsetEstimate? {
        guard let overlap = PixelOverlap(currentImage, previousImage) else { return nil }
        if overlap.current == overlap.previous {
            return ScrollOffsetEstimate(translation: .zero, confidence: 1, source: .pixelOverlap)
        }

        // Vision 只提出候选位移，必须再通过实际重叠像素校验
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previousImage)
        try? VNImageRequestHandler(cgImage: currentImage, options: [:]).perform([request])
        var proposedOffset: Int?
        if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
            let translation = observation.alignmentTransform
            if abs(translation.tx) <= 3, abs(translation.ty) <= CGFloat(overlap.maximumOffset) {
                let offset = Int(translation.ty.rounded())
                proposedOffset = offset
                let errors = overlap.columnErrors(at: offset).filter(\.isFinite)
                if abs(offset) <= overlap.maximumOffset,
                   !errors.isEmpty, errors.allSatisfy({ $0 <= 0.05 }) {
                    return ScrollOffsetEstimate(translation: CGPoint(x: 0, y: offset),
                                          confidence: observation.confidence, source: .fullFrameFallback)
                }
            }
        }

        // 先用行特征粗筛位移，再分别校验三列像素，避免固定区域主导结果
        let coarse = (-overlap.maximumOffset...overlap.maximumOffset)
            .map { (offset: $0, errors: overlap.columnErrors(at: $0, coarse: true)) }
        var offsets: Set<Int> = []
        for column in 0..<3 {
            for candidate in coarse.sorted(by: { $0.errors[column] < $1.errors[column] }).prefix(3) {
                offsets.formUnion(candidate.offset - 2...candidate.offset + 2)
            }
        }
        if let proposedOffset { offsets.formUnion(proposedOffset - 2...proposedOffset + 2) }
        let checked = offsets.filter { abs($0) <= overlap.maximumOffset }
            .map { (offset: $0, errors: overlap.columnErrors(at: $0)) }
        let minima = (0..<3).map { column in checked.map { $0.errors[column] }.min() ?? .infinity }
        // 亚像素滚动会改变文字抗锯齿，允许少量灰度差异
        let maximumPixelError = 6.0
        let weights = overlap.columnWeights
        let requiredWeight = weights.reduce(0, +) / 2
        let reliable = (0..<3).filter { weights[$0] > 0 && minima[$0] <= maximumPixelError }
        guard reliable.reduce(0, { $0 + weights[$1] }) > requiredWeight else { return nil }
        let agreeing = checked.compactMap { candidate -> (offset: Int, error: Double)? in
            let columns = reliable.filter { column in
                // 亚像素渲染可能让不同列相差一像素，但仍须满足误差上限
                candidate.errors[column] <= maximumPixelError && checked.contains(where: { neighbor in
                    abs(neighbor.offset - candidate.offset) <= 1 && neighbor.errors[column] <= minima[column] + 0.5
                })
            }
            // 仅包含固定页头的列权重低于贯穿正文的细节
            let weight = columns.reduce(0) { $0 + weights[$1] }
            guard weight > requiredWeight else { return nil }
            let error = columns.reduce(0.0) { $0 + candidate.errors[$1] * Double(weights[$1]) } / Double(weight)
            return (offset: candidate.offset, error: error)
        }
        let best = agreeing.min { lhs, rhs in
            lhs.error == rhs.error ? abs(lhs.offset) < abs(rhs.offset) : lhs.error < rhs.error
        }
        guard let best else { return nil }
        return ScrollOffsetEstimate(translation: CGPoint(x: 0, y: best.offset), confidence: 1, source: .pixelOverlap)
    }
}

/// 灰度采样允许页头或单列动画保持独立，纯色区域不能单独证明位移
private struct PixelOverlap {
    let current: [UInt8]
    let previous: [UInt8]
    private let width: Int
    private let height: Int
    private let currentRows: [RowSignature]
    private let previousRows: [RowSignature]

    private struct RowSignature {
        let mean: Double
        let weightedMean: Double
        let contrast: Int
    }
    var maximumOffset: Int { Int(Double(height) * 0.85) }
    var columnWeights: [Int] {
        (0..<3).map { column in
            let rows = (0..<height).filter { y in
                max(currentRows[y * 3 + column].contrast, previousRows[y * 3 + column].contrast) >= 20
            }
            guard rows.count >= max(4, height / 10), let first = rows.first, let last = rows.last else { return 0 }
            return last - first + 1
        }
    }

    init?(_ currentImage: CGImage, _ previousImage: CGImage) {
        guard currentImage.width == previousImage.width, currentImage.height == previousImage.height,
              currentImage.width >= 3, currentImage.height > 0 else { return nil }
        let width = min(96, currentImage.width)
        let height = currentImage.height
        func pixels(_ image: CGImage) -> [UInt8]? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                            count: width * height))
        }
        guard let current = pixels(currentImage), let previous = pixels(previousImage) else { return nil }
        func signatures(_ pixels: [UInt8]) -> [RowSignature] {
            let rows = (0..<height * 3).map { index in
                let y = index / 3
                let column = index % 3
                let range = Self.columnRange(column, width: width)
                let start = range.lowerBound
                let end = range.upperBound
                var sum = 0, weighted = 0, weights = 0, low = 255, high = 0
                for x in start..<end {
                    let value = Int(pixels[y * width + x])
                    let weight = (x - start) % 7 + 1
                    sum += value; weighted += value * weight; weights += weight
                    low = min(low, value); high = max(high, value)
                }
                return RowSignature(mean: Double(sum) / Double(end - start),
                                    weightedMean: Double(weighted) / Double(weights), contrast: high - low)
            }
            // 垂直方向的相邻细节用于识别带纹理页头下的正文滚动
            let radius = max(1, height / 20)
            return rows.enumerated().map { index, row in
                let y = index / 3, column = index % 3
                let above = rows[max(0, y - radius) * 3 + column]
                let below = rows[min(height - 1, y + radius) * 3 + column]
                // 纯色区域借助垂直细节，同时保留文字空白行过滤
                guard row.contrast < 20, above.contrast < 20, below.contrast < 20 else { return row }
                let verticalContrast = max(row.mean, max(above.mean, below.mean)) - min(row.mean, min(above.mean, below.mean))
                return RowSignature(mean: row.mean, weightedMean: row.weightedMean,
                                    contrast: max(row.contrast, Int(verticalContrast)))
            }
        }
        currentRows = signatures(current)
        previousRows = signatures(previous)
        self.current = current
        self.previous = previous
        self.width = width
        self.height = height
    }

    private static func columnRange(_ column: Int, width: Int) -> Range<Int> {
        // 滚动条与选区边缘可能独立变化，不参与正文匹配
        let margin = min(3, width / 12)
        return max(margin, column * width / 3)..<min(width - margin, (column + 1) * width / 3)
    }

    func columnErrors(at offset: Int, coarse: Bool = false) -> [Double] {
        let overlapHeight = height - abs(offset)
        guard overlapHeight > 0 else { return Array(repeating: .infinity, count: 3) }
        // 精校验覆盖每一行，稀疏采样会让 Retina 的重复像素行误差一像素
        let sampleCount = coarse ? min(32, overlapHeight) : overlapHeight
        var columnErrors: [Double] = []
        for column in 0..<3 {
            let range = Self.columnRange(column, width: width)
            let startX = range.lowerBound
            let endX = range.upperBound
            var rowErrors: [Double] = []
            for sample in 0..<sampleCount {
                let y = (sample * 2 + 1) * overlapHeight / (sampleCount * 2)
                let currentRow = (y + max(0, -offset)) * width
                let previousRow = (y + max(0, offset)) * width
                let a = currentRows[(y + max(0, -offset)) * 3 + column]
                let b = previousRows[(y + max(0, offset)) * 3 + column]
                guard max(a.contrast, b.contrast) >= 20 else { continue }
                if coarse {
                    rowErrors.append((abs(a.mean - b.mean) + abs(a.weightedMean - b.weightedMean)) / 2)
                } else {
                    var difference = 0
                    for x in startX..<endX {
                        difference += abs(Int(current[currentRow + x]) - Int(previous[previousRow + x]))
                    }
                    rowErrors.append(Double(difference) / Double(endX - startX))
                }
            }
            guard rowErrors.count >= 4 else { columnErrors.append(.infinity); continue }
            rowErrors.sort()
            // 舍弃误差最大的三分之一行，容忍固定页头和局部动态内容
            let count = max(1, rowErrors.count * 2 / 3)
            columnErrors.append(rowErrors.prefix(count).reduce(0, +) / Double(count))
        }
        return columnErrors
    }
}


final class ScrollStitcher {
    enum Outcome: Equatable {
        case appended
        case unchanged
        case revisited
        case unmatched
        case atFrameLimit
    }

    private struct Frame {
        let image: CGImage
        let size: NSSize
        var scale: CGFloat { CGFloat(image.height) / size.height }
    }

    private let estimator: any ScrollOffsetEstimating
    private let maxFrames: Int
    private var stitched: Frame?
    private var previous: Frame?
    private var position = 0
    private var lastAppendHeight = 0
    private var acceptedFrames = 0
    private(set) var isIncomplete = false
    private(set) var reachedFrameLimit = false

    // 由 ScrollCapturer 的串行队列独占；无需额外 actor 或第二个任务队列
    init(estimator: any ScrollOffsetEstimating = ScrollOffsetEstimator(), maxFrames: Int = 100) {
        self.estimator = estimator
        self.maxFrames = maxFrames
    }

    var image: NSImage? {
        stitched.map { NSImage(cgImage: $0.image, size: $0.size) }
    }

    func markIncomplete() {
        isIncomplete = true
    }

    @discardableResult
    func add(_ image: NSImage) -> Outcome {
        guard image.size.height > 0, let cgImage = image.cgImagePreservingBacking() else {
            isIncomplete = true
            return .unmatched
        }
        let frame = Frame(image: cgImage, size: image.size)
        guard let base = stitched, let anchor = previous else {
            stitched = frame
            previous = frame
            acceptedFrames = 1
            isIncomplete = false
            return .appended
        }
        guard frame.image.width == anchor.image.width,
              frame.image.height == anchor.image.height,
              abs(frame.scale - anchor.scale) < 0.001,
              let estimate = estimator.estimate(from: frame.image, to: anchor.image) else {
            // 匹配失败时保留可靠参考帧，稍后的帧仍有机会追上
            isIncomplete = true
            return .unmatched
        }
        let shift = Int(estimate.translation.y.rounded())
        let nextPosition = position + shift
        let growth = nextPosition + frame.image.height - base.image.height
        // 只刷新刚新增且已进入视口内部的内容，让延迟绘制有机会补全
        let refreshHeight = growth >= 0 && lastAppendHeight + growth <= frame.image.height / 2
            ? lastAppendHeight : 0
        if growth > 0 {
            guard acceptedFrames < maxFrames else {
                reachedFrameLimit = true
                return .atFrameLimit
            }
        }
        if growth > 0 || refreshHeight > 0 {
            guard let output = composite(base: base, next: frame, growth: growth, replacing: refreshHeight) else {
                isIncomplete = true
                return .unmatched
            }
            stitched = output
        }
        // 回滚只移动参考位置，不删除已捕获内容；再次向下时仅追加新区域
        position = nextPosition
        previous = frame
        lastAppendHeight = max(0, growth)
        if growth > 0 { acceptedFrames += 1 }
        isIncomplete = false
        return growth > 0 ? .appended : (shift == 0 ? .unchanged : .revisited)
    }

    private func composite(base: Frame, next: Frame, growth: Int, replacing: Int) -> Frame? {
        let stripHeight = growth + replacing
        guard stripHeight > 0, stripHeight <= next.image.height,
              let strip = next.image.cropping(to: CGRect(
                x: 0, y: next.image.height - stripHeight, width: next.image.width, height: stripHeight
              )),
              let context = CGContext(
                data: nil, width: base.image.width, height: base.image.height + growth,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.draw(base.image, in: CGRect(x: 0, y: growth, width: base.image.width, height: base.image.height))
        context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
        guard let output = context.makeImage() else { return nil }
        return Frame(image: output, size: NSSize(width: base.size.width, height: CGFloat(output.height) / next.scale))
    }
}
