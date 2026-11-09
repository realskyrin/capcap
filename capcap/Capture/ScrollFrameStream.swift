import AppKit
import ScreenCaptureKit
import OSLog

/// The capture session consumes buffered frames and terminal failures through
/// the same boundary; supplied sources can exercise recovery without SCK.
protocol ScrollFrameSource: AnyObject {
    func snapshot(after consumedSequence: UInt64, timeout: TimeInterval, waitsForNewFrame: Bool) -> ScrollFrameStream.Snapshot
    func discard(through consumedSequence: UInt64)
    func stop()
}

/// Keeps acquisition independent of the (occasionally expensive) matcher.
/// Pixels are copied out of ScreenCaptureKit's small surface pool immediately;
/// the bounded history belongs to this session and is never written to disk.
final class ScrollFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, ScrollFrameSource {
    struct Frame {
        let sequence: UInt64
        let image: CGImage
        let byteCount: Int
    }

    enum Snapshot {
        case frames([Frame])
        case unavailable
        case failed
    }

    private static let logger = Logger(subsystem: "cn.skyrin.capcap", category: "ScrollCapture")
    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(label: "capcap.scroll-frames", qos: .userInitiated)
    private let maximumBytes = 96 * 1024 * 1024
    private let maximumFrames = 24
    private var frames: [Frame] = []
    private var bufferedBytes = 0
    private var sequence: UInt64 = 0
    private var failed = false
    private var stopped = false
    private var stream: SCStream?

    init(rect: CGRect, displayID: CGDirectDisplayID?, scale: CGFloat, excludingWindowNumbers: [CGWindowID]) {
        super.init()
        Task.detached { [self] in
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    markFailed()
                    return
                }
                let exclusions = content.windows.filter { excludingWindowNumbers.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: exclusions)
                let configuration = SCStreamConfiguration()
                let bounds = CGDisplayBounds(display.displayID)
                configuration.sourceRect = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                configuration.width = max(1, Int(ceil(rect.width * scale)))
                configuration.height = max(1, Int(ceil(rect.height * scale)))
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.scalesToFit = false
                let source = SCStream(filter: filter, configuration: configuration, delegate: self)
                try source.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
                guard install(source) else { return }
                try await source.startCapture()
                // stop() can race the asynchronous startup. A second stop here
                // ensures that a cancelled session never leaves a stream alive.
                if isStopped { try? await source.stopCapture() }
            } catch {
                let error = error as NSError
                Self.logger.error("scroll stream unavailable domain=\(error.domain, privacy: .public) code=\(error.code)")
                markFailed()
            }
        }
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private func install(_ source: SCStream) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return false }
        stream = source
        return true
    }

    /// Returns an immutable snapshot. With no new frame, the last complete
    /// frame is still valid: WindowServer need not redraw a stationary page.
    func snapshot(after consumedSequence: UInt64, timeout: TimeInterval, waitsForNewFrame: Bool = false) -> Snapshot {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !failed && !stopped && (frames.isEmpty || (waitsForNewFrame && frames.last!.sequence <= consumedSequence)) {
            if !condition.wait(until: deadline) { break }
        }
        if failed { return .failed }
        guard !stopped else { return .unavailable }
        let pending = frames.filter { $0.sequence > consumedSequence }
        if !pending.isEmpty { return .frames(pending) }
        return frames.last.map { .frames([$0]) } ?? .unavailable
    }

    func discard(through consumedSequence: UInt64) {
        condition.lock()
        defer { condition.unlock() }
        // Retain the latest frame so an unchanged page remains observable.
        while frames.count > 1, frames[0].sequence <= consumedSequence {
            bufferedBytes -= frames.removeFirst().byteCount
        }
    }

    func stop() {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true
        let source = stream
        stream = nil
        frames.removeAll()
        bufferedBytes = 0
        condition.broadcast()
        condition.unlock()
        if let source {
            Task.detached { try? await source.stopCapture() }
        }
    }

    private func markFailed() {
        condition.lock()
        failed = true
        condition.broadcast()
        condition.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopped else { return }
        let error = error as NSError
        Self.logger.error("scroll stream stopped domain=\(error.domain, privacy: .public) code=\(error.code)")
        markFailed()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let byteCount = bytesPerRow * height
        guard width > 0, height > 0, byteCount <= maximumBytes,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        let pixels: Data?
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            pixels = Data(bytes: base, count: byteCount)
        } else {
            pixels = nil
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        guard let pixels, let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return }

        condition.lock()
        defer { condition.unlock() }
        guard !stopped, !failed else { return }
        sequence &+= 1
        frames.append(Frame(sequence: sequence, image: image, byteCount: byteCount))
        bufferedBytes += byteCount
        while frames.count > maximumFrames || bufferedBytes > maximumBytes {
            bufferedBytes -= frames.removeFirst().byteCount
        }
        condition.broadcast()
    }
}
