// 基于 ScrollSnap 74a613b 的 MIT 实现，版权与许可证见 ThirdParty/ScrollSnap
import AppKit

enum ScrollOffsetEstimateSource: Equatable, Sendable {
    case pixelOverlap
}

struct ScrollOffsetEstimate: Sendable {
    let translation: CGPoint
    let confidence: Float
    let source: ScrollOffsetEstimateSource
    var joinRow: Int? = nil
}

protocol ScrollOffsetEstimating: Sendable {
    func estimate(from currentImage: CGImage, to previousImage: CGImage) -> ScrollOffsetEstimate?
}

struct ScrollOffsetEstimator: ScrollOffsetEstimating {
    func estimate(from currentImage: CGImage, to previousImage: CGImage) -> ScrollOffsetEstimate? {
        // 复用主线来自 PR #222 的正文证据与歧义校验，固定栏和重复行不能单独决定接缝
        switch ScrollFrameMatcher().match(
            previous: previousImage, current: currentImage, allowsReverseScroll: true
        ) {
        case .unchanged:
            return ScrollOffsetEstimate(translation: .zero, confidence: 1, source: .pixelOverlap)
        case .aligned(let alignment):
            return ScrollOffsetEstimate(
                translation: CGPoint(x: 0, y: alignment.shift), confidence: 1,
                source: .pixelOverlap, joinRow: alignment.joinRow
            )
        case .unmatched:
            return exactOverlap(from: currentImage, to: previousImage)
        }
    }

    /// 高密度像素图可能没有可用文字锚点；只在多列逐字节一致且位移唯一时补充匹配
    private func exactOverlap(from currentImage: CGImage, to previousImage: CGImage) -> ScrollOffsetEstimate? {
        guard currentImage.width == previousImage.width, currentImage.height == previousImage.height else { return nil }
        let width = min(96, currentImage.width), height = currentImage.height
        guard width >= 12, height >= 8 else { return nil }
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
        return current.withUnsafeBufferPointer { current in
            previous.withUnsafeBufferPointer { previous in
                let columns = (0..<3).map { max(2, $0 * width / 3)..<min(width - 2, ($0 + 1) * width / 3) }
                func equal(_ y: Int, _ oldY: Int, _ column: Int) -> Bool {
                    let range = columns[column]
                    return memcmp(current.baseAddress! + y * width + range.lowerBound,
                                  previous.baseAddress! + oldY * width + range.lowerBound, range.count) == 0
                }
                var votes: [Int: [Int]] = [:]
                var bounds: [Range<Int>] = []
                var hasChangedDetail = false
                for column in 0..<3 {
                    var start = 0, end = height
                    while start < end && equal(start, start, column) { start += 1 }
                    while end > start && equal(end - 1, end - 1, column) { end -= 1 }
                    bounds.append(start..<end)
                    let detailedRows = (0..<height).filter { y in
                        let range = columns[column]
                        let row = previous.baseAddress! + y * width
                        let newRow = current.baseAddress! + y * width
                        return range.contains {
                            abs(Int(row[$0]) - Int(row[range.lowerBound])) >= 20 ||
                                abs(Int(newRow[$0]) - Int(newRow[range.lowerBound])) >= 20
                        }
                    }.count
                    guard detailedRows >= max(4, height / 10) else { continue }
                    if start == end {
                        votes[0, default: []].append(column)
                        continue
                    }
                    hasChangedDetail = true
                    let minimumOverlap = max(4, (end - start) / 2)
                    let limit = end - start - minimumOverlap
                    guard limit > 0 else { continue }
                    for shift in -limit...limit where shift != 0 {
                        let overlap = (start + max(0, -shift))..<(end - max(0, shift))
                        if overlap.allSatisfy({ equal($0, $0 + shift, column) }) {
                            votes[shift, default: []].append(column)
                        }
                    }
                }
                // 一列动画可独立变化；其余列若支持多个重复行偏移，必须拒绝猜测
                let accepted = votes.filter { $0.value.count >= 2 }
                guard accepted.count == 1, let (shift, support) = accepted.first else { return nil }
                // 静止侧栏不能掩盖尚未匹配的正文；只允许忽略没有纹理的纯色动画列
                guard shift != 0 || !hasChangedDetail else { return nil }
                var joinRow: Int?
                if shift != 0 {
                    let movingRows = (max(0, -shift)..<(height - max(0, shift))).filter { y in
                        support.filter { column in
                            bounds[column].contains(y) && bounds[column].contains(y + shift) &&
                                equal(y, y + shift, column) && !equal(y, y, column)
                        }.count >= 2
                    }
                    // 局部横幅也会精确平移，正文证据必须跨越视口，不能仅凭一小块动画拼页
                    guard movingRows.count >= max(4, height / 20),
                          let first = movingRows.first, let last = movingRows.last,
                          last - first >= height / 3 else { return nil }
                    if shift > 0 { joinRow = movingRows[movingRows.count / 2] }
                }
                return ScrollOffsetEstimate(translation: CGPoint(x: 0, y: shift), confidence: 1,
                                            source: .pixelOverlap, joinRow: joinRow)
            }
        }
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
    private var first: Frame?
    private var previous: Frame?
    private var canvas: NSMutableData?
    private var height = 0
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
        guard let canvas, let first else { return nil }
        // 诊断快照可以跨队列保留，不能把仍会追加的可变缓冲交给调用方
        let snapshot = Data(bytes: canvas.bytes, count: height * packedStride(first.image))
        return outputImage(data: snapshot as CFData, template: first)
    }

    func thumbnail() -> NSImage? {
        guard let canvas, let first,
              let source = canvasImage(data: canvas as CFData, template: first.image) else { return nil }
        let scale = min(1, 240 / CGFloat(first.image.width), 800 / CGFloat(height))
        let width = max(1, Int(CGFloat(first.image.width) * scale))
        let thumbnailHeight = max(1, Int(CGFloat(height) * scale))
        guard let space = first.image.colorSpace,
              let context = CGContext(data: nil, width: width, height: thumbnailHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space.model == .rgb ? space : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: thumbnailHeight))
        guard let thumbnail = context.makeImage() else { return nil }
        return NSImage(cgImage: thumbnail, size: outputSize(first))
    }

    func takeImage() -> NSImage? {
        defer {
            // 成图提供者接管缓冲，此后追加会创建新缓冲，不会修改已交付的图片
            canvas = nil
            first = nil
            previous = nil
            height = 0
            position = 0
            lastAppendHeight = 0
            acceptedFrames = 0
        }
        guard let canvas, let first else { return nil }
        return outputImage(data: canvas as CFData, template: first)
    }

    func markIncomplete() {
        isIncomplete = true
    }

    @discardableResult
    func add(_ image: NSImage) -> Outcome {
        guard image.size.width > 0, image.size.height > 0,
              let cgImage = image.cgImagePreservingBacking(), cgImage.colorSpace != nil,
              let pixelData = cgImage.dataProvider?.data,
              cgImage.bytesPerRow >= packedStride(cgImage) else {
            isIncomplete = true
            return .unmatched
        }
        let frame = Frame(image: cgImage, size: image.size)
        guard let first, let anchor = previous else {
            guard copyRows(from: pixelData, frame: frame.image, sourceRow: 0, destinationRow: 0,
                           newHeight: frame.image.height) else {
                isIncomplete = true
                return .unmatched
            }
            self.first = frame
            previous = frame
            acceptedFrames = 1
            isIncomplete = false
            reachedFrameLimit = false
            return .appended
        }
        guard frame.image.width == anchor.image.width,
              frame.image.height == anchor.image.height,
              abs(frame.scale - anchor.scale) < 0.001,
              frame.size == first.size,
              frame.image.bitsPerComponent == first.image.bitsPerComponent,
              frame.image.bitsPerPixel == first.image.bitsPerPixel,
              frame.image.bitmapInfo == first.image.bitmapInfo,
              frame.image.colorSpace == first.image.colorSpace,
              let estimate = estimator.estimate(from: frame.image, to: anchor.image) else {
            // 匹配失败时保留可靠参考帧，稍后的帧仍有机会追上
            isIncomplete = true
            return .unmatched
        }
        guard estimate.translation.y.isFinite,
              abs(estimate.translation.y) < CGFloat(frame.image.height) else {
            isIncomplete = true
            return .unmatched
        }
        let shift = Int(estimate.translation.y.rounded())
        let nextPosition = position + shift
        let growth = nextPosition + frame.image.height - height
        // 只刷新刚新增且已进入视口内部的内容，让延迟绘制有机会补全
        let refreshHeight = growth >= 0 && lastAppendHeight + growth <= frame.image.height / 2
            ? lastAppendHeight : 0
        // 固定栏可能造成零位移误判；补尾前须确认已保留的正文没有移动
        if shift == 0 && (refreshHeight == 0 || !matchesRetainedRows(
            frame, data: pixelData, anchor: anchor, rowCount: frame.image.height - refreshHeight
        )) {
            return .unchanged
        }
        if growth > 0 {
            guard acceptedFrames < maxFrames else {
                reachedFrameLimit = true
                return .atFrameLimit
            }
        }
        if growth > 0 || refreshHeight > 0 {
            let sourceRow: Int
            if growth > 0, let joinRow = estimate.joinRow {
                guard joinRow >= 0, joinRow < frame.image.height - shift else {
                    isIncomplete = true
                    return .unmatched
                }
                sourceRow = joinRow
            } else {
                sourceRow = frame.image.height - growth - refreshHeight
            }
            let destinationRow = nextPosition + sourceRow
            guard sourceRow >= 0, sourceRow < frame.image.height,
                  destinationRow >= 0, destinationRow <= height,
                  copyRows(from: pixelData, frame: frame.image, sourceRow: sourceRow,
                           destinationRow: destinationRow, newHeight: height + growth) else {
                isIncomplete = true
                return .unmatched
            }
        }
        // 回滚只移动参考位置，不删除已捕获内容；再次向下时仅追加新区域
        position = nextPosition
        // 零位移只有通过保留区域校验后才会到达这里，此时可保留补绘后的可靠参考帧
        previous = frame
        lastAppendHeight = max(0, growth)
        if growth > 0 { acceptedFrames += 1 }
        isIncomplete = false
        return growth > 0 ? .appended : (shift == 0 ? .unchanged : .revisited)
    }

    private func packedStride(_ frame: CGImage) -> Int {
        (frame.width * frame.bitsPerPixel + 7) / 8
    }

    private func matchesRetainedRows(_ frame: Frame, data: CFData, anchor: Frame, rowCount: Int) -> Bool {
        guard let oldData = anchor.image.dataProvider?.data,
              let current = CFDataGetBytePtr(data), let previous = CFDataGetBytePtr(oldData),
              CFDataGetLength(data) / frame.image.bytesPerRow >= rowCount,
              CFDataGetLength(oldData) / anchor.image.bytesPerRow >= rowCount else { return false }
        let stride = packedStride(frame.image)
        return withExtendedLifetime((data, oldData)) {
            (0..<rowCount).allSatisfy { row in
                memcmp(current + row * frame.image.bytesPerRow,
                       previous + row * anchor.image.bytesPerRow, stride) == 0
            }
        }
    }

    private func copyRows(from pixelData: CFData, frame: CGImage, sourceRow: Int,
                          destinationRow: Int, newHeight: Int) -> Bool {
        let stride = packedStride(frame)
        let rows = frame.height - sourceRow
        guard let input = CFDataGetBytePtr(pixelData), stride > 0,
              sourceRow >= 0, rows > 0, destinationRow >= 0,
              newHeight >= height, destinationRow <= newHeight,
              rows == newHeight - destinationRow else { return false }
        let (lastRow, rowOverflow) = (frame.height - 1).multipliedReportingOverflow(by: frame.bytesPerRow)
        let (inputBytes, inputOverflow) = lastRow.addingReportingOverflow(stride)
        guard !rowOverflow, !inputOverflow, inputBytes <= CFDataGetLength(pixelData) else { return false }
        let (requiredBytes, overflow) = newHeight.multipliedReportingOverflow(by: stride)
        guard !overflow else { return false }
        if requiredBytes > (canvas?.length ?? 0) {
            // 几何扩容只在容量不足时复制旧像素，累计拷贝随成图大小线性增长
            let (doubled, capacityOverflow) = (canvas?.length ?? 0).multipliedReportingOverflow(by: 2)
            let capacity = capacityOverflow ? requiredBytes : max(requiredBytes, doubled)
            guard let grown = NSMutableData(length: capacity) else { return false }
            if let canvas { memcpy(grown.mutableBytes, canvas.bytes, destinationRow * stride) }
            canvas = grown
        }
        guard let canvas else { return false }
        let output = canvas.mutableBytes.advanced(by: destinationRow * stride)
        // 直接复制 CGImage 的已解码像素，NSBitmapImageRep.bitmapData 会改写 BGRA 的字节序
        withExtendedLifetime(pixelData) {
            let start = input.advanced(by: sourceRow * frame.bytesPerRow)
            if stride == frame.bytesPerRow {
                memcpy(output, start, rows * stride)
            } else {
                for row in 0..<rows {
                    memcpy(output.advanced(by: row * stride), start.advanced(by: row * frame.bytesPerRow), stride)
                }
            }
        }
        height = newHeight
        return true
    }

    private func outputSize(_ frame: Frame) -> NSSize {
        NSSize(width: frame.size.width, height: CGFloat(height) / frame.scale)
    }

    private func outputImage(data: CFData, template: Frame) -> NSImage? {
        guard let image = canvasImage(data: data, template: template.image) else { return nil }
        return NSImage(cgImage: image, size: outputSize(template))
    }

    private func canvasImage(data: CFData, template: CGImage) -> CGImage? {
        guard let space = template.colorSpace, let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: template.width, height: height,
                       bitsPerComponent: template.bitsPerComponent, bitsPerPixel: template.bitsPerPixel,
                       bytesPerRow: packedStride(template), space: space, bitmapInfo: template.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: template.renderingIntent)
    }
}
