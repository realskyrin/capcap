import AppKit

enum ScrollFrameOutcome: Equatable {
    case appended, noNewContent, unmatched, atFrameLimit
}

/// Owned by the capture queue. The previous viewport supplies the matching
/// reference. The canvas holds the stitched pixels at the capture resolution.
final class ScrollImageStitcher {
    private let matcher = ScrollFrameMatcher()
    private var previous: CGImage?
    private var canvas: NSMutableData?
    private var height = 0
    private var viewportSize = CGSize.zero
    private var frameCount = 0

    var reachedFrameLimit: Bool { frameCount >= 100 }

    func append(_ image: NSImage, expectedShiftPoints: CGFloat = 0) -> ScrollFrameOutcome {
        guard !reachedFrameLimit else { return .atFrameLimit }
        guard image.size.width > 0, image.size.height > 0,
              let bitmap = image.bitmapImageRepPreservingBacking(), !bitmap.isPlanar,
              let input = bitmap.bitmapData, let frame = bitmap.cgImage, frame.colorSpace != nil,
              frame.width == bitmap.pixelsWide, frame.height == bitmap.pixelsHigh,
              frame.bitsPerPixel == bitmap.bitsPerPixel, frame.bitsPerComponent == bitmap.bitsPerSample
        else { return .unmatched }
        let stride = packedStride(for: frame)
        let inputStride = bitmap.bytesPerRow
        guard inputStride >= stride else { return .unmatched }

        var sourceRow = 0
        var destinationRow = 0
        if let previous {
            guard previous.width == frame.width, previous.height == frame.height,
                  previous.bitsPerPixel == frame.bitsPerPixel, previous.bitsPerComponent == frame.bitsPerComponent,
                  previous.bitmapInfo == frame.bitmapInfo, previous.colorSpace == frame.colorSpace,
                  viewportSize == image.size else { return .unmatched }

            let scale = CGFloat(frame.height) / viewportSize.height
            let expectedShift = expectedShiftPoints > 0 ? expectedShiftPoints * scale : nil
            switch matcher.match(previous: previous, current: frame, expectedShift: expectedShift) {
            case .unchanged:
                return .noNewContent
            case .unmatched:
                return .unmatched
            case .aligned(let alignment):
                sourceRow = alignment.joinRow
                guard alignment.shift > 0, sourceRow >= 0, sourceRow < frame.height - alignment.shift
                else { return .unmatched }
                // Replace the old footer with unobscured document pixels from
                // the new viewport. Its header stays above this verified join.
                destinationRow = height - frame.height + alignment.shift + sourceRow
            }
        }

        let rowsToCopy = frame.height - sourceRow
        let newHeight = destinationRow + rowsToCopy
        if newHeight * stride > (canvas?.length ?? 0) {
            // Keep at most one spare viewport when growing the export canvas.
            let capacity = canvas == nil ? newHeight : newHeight + frame.height
            guard let grown = NSMutableData(length: capacity * stride) else { return .unmatched }
            if let canvas {
                memcpy(grown.mutableBytes, canvas.bytes, destinationRow * stride)
            }
            canvas = grown
        }
        guard let canvas else { return .unmatched }
        let output = canvas.mutableBytes.advanced(by: destinationRow * stride)
        withExtendedLifetime(bitmap) {
            let start = input.advanced(by: sourceRow * inputStride)
            if stride == inputStride {
                memcpy(output, start, rowsToCopy * stride)
            } else {
                for row in 0..<rowsToCopy {
                    memcpy(output.advanced(by: row * stride), start.advanced(by: row * inputStride), stride)
                }
            }
        }
        height = newHeight
        viewportSize = image.size
        previous = frame
        frameCount += 1
        return .appended
    }

    /// Transfers ownership of the finished canvas to its image provider.
    func takeImage() -> NSImage? {
        defer {
            canvas = nil
            self.previous = nil
            frameCount = 0
            height = 0
        }
        guard let previous else { return nil }
        if frameCount == 1 { return NSImage(cgImage: previous, size: viewportSize) }
        guard let result = canvasImage(template: previous) else { return nil }
        return NSImage(cgImage: result, size: outputSize(for: previous))
    }

    func thumbnail() -> NSImage? {
        guard let previous, let source = canvasImage(template: previous) else { return nil }
        // The preview panel is 120 × 400 points. Only its small, independent
        // thumbnail leaves this queue while the full canvas is still mutable.
        let scale = min(1, 240 / CGFloat(previous.width), 800 / CGFloat(height))
        let width = max(1, Int(CGFloat(previous.width) * scale))
        let thumbnailHeight = max(1, Int(CGFloat(height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: thumbnailHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: thumbnailHeight))
        guard let thumbnail = context.makeImage() else { return nil }
        return NSImage(cgImage: thumbnail, size: outputSize(for: previous))
    }

    private func outputSize(for frame: CGImage) -> CGSize {
        CGSize(width: viewportSize.width, height: CGFloat(height) * viewportSize.height / CGFloat(frame.height))
    }

    private func packedStride(for frame: CGImage) -> Int {
        (frame.width * frame.bitsPerPixel + 7) / 8
    }

    private func canvasImage(template: CGImage) -> CGImage? {
        guard let space = template.colorSpace, let canvas,
              let provider = CGDataProvider(data: canvas as CFData) else { return nil }
        return CGImage(
            width: template.width, height: height, bitsPerComponent: template.bitsPerComponent,
            bitsPerPixel: template.bitsPerPixel, bytesPerRow: packedStride(for: template), space: space,
            bitmapInfo: template.bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: false, intent: template.renderingIntent
        )
    }
}
