import AppKit
import AVFoundation
import ImageIO

struct HistoryImagePreview {
    let cgImage: CGImage?
    let pixelWidth: Int
    let pixelHeight: Int

    var estimatedByteCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    static func load(url: URL, pixelSize: Int) -> HistoryImagePreview {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return HistoryImagePreview(cgImage: nil, pixelWidth: 0, pixelHeight: 0)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        return HistoryImagePreview(cgImage: cgImage, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    static func loadVideoFrame(url: URL, pixelSize: Int) -> HistoryImagePreview {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let size = videoPixelSize(for: asset) ?? CGSize(width: cgImage.width, height: cgImage.height)
            return HistoryImagePreview(
                cgImage: cgImage,
                pixelWidth: Int(round(size.width)),
                pixelHeight: Int(round(size.height))
            )
        } catch {
            return HistoryImagePreview(cgImage: nil, pixelWidth: 0, pixelHeight: 0)
        }
    }

    static func metadata(pixelWidth: Int, pixelHeight: Int, date: Date) -> String {
        let size: String
        if pixelWidth > 0, pixelHeight > 0 {
            size = "\(pixelWidth) x \(pixelHeight)"
        } else {
            size = "Image"
        }
        return "\(size)  ·  \(dateFormatter.string(from: date))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MdHm")
        return formatter
    }()

    private static func videoPixelSize(for asset: AVAsset) -> CGSize? {
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

final class HistoryImagePreviewRequest {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum HistoryImagePreviewLoadPriority: Int {
    case prefetch
    case visible

    var operationQueuePriority: Operation.QueuePriority {
        switch self {
        case .prefetch: return .low
        case .visible: return .veryHigh
        }
    }

    var qualityOfService: QualityOfService {
        switch self {
        case .prefetch: return .utility
        case .visible: return .userInitiated
        }
    }
}

final class HistoryImagePreviewLoader {
    static let shared = HistoryImagePreviewLoader()

    private struct Waiter {
        let request: HistoryImagePreviewRequest
        let completion: (HistoryImagePreview) -> Void
    }

    private final class InFlightLoad {
        var waiters: [Waiter]
        let operation: Operation
        var priority: HistoryImagePreviewLoadPriority

        init(
            waiters: [Waiter],
            operation: Operation,
            priority: HistoryImagePreviewLoadPriority
        ) {
            self.waiters = waiters
            self.operation = operation
            self.priority = priority
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "capcap.historyPreviewLoader"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let cache = NSCache<NSString, HistoryImagePreviewCacheValue>()
    private let inFlightLock = NSLock()
    private var inFlight: [String: InFlightLoad] = [:]

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    @discardableResult
    func load(
        url: URL,
        pixelSize: Int,
        priority: HistoryImagePreviewLoadPriority = .visible,
        completion: @escaping (HistoryImagePreview) -> Void
    ) -> HistoryImagePreviewRequest {
        load(
            url: url,
            pixelSize: pixelSize,
            cachePrefix: "image",
            priority: priority,
            producer: HistoryImagePreview.load,
            completion: completion
        )
    }

    @discardableResult
    func loadVideoFrame(
        url: URL,
        pixelSize: Int,
        priority: HistoryImagePreviewLoadPriority = .visible,
        completion: @escaping (HistoryImagePreview) -> Void
    ) -> HistoryImagePreviewRequest {
        load(
            url: url,
            pixelSize: pixelSize,
            cachePrefix: "video",
            priority: priority,
            producer: HistoryImagePreview.loadVideoFrame,
            completion: completion
        )
    }

    func cachedPreview(url: URL, pixelSize: Int) -> HistoryImagePreview? {
        cachedPreview(url: url, pixelSize: pixelSize, cachePrefix: "image")
    }

    func cachedVideoFrame(url: URL, pixelSize: Int) -> HistoryImagePreview? {
        cachedPreview(url: url, pixelSize: pixelSize, cachePrefix: "video")
    }

    @discardableResult
    private func load(
        url: URL,
        pixelSize: Int,
        cachePrefix: String,
        priority: HistoryImagePreviewLoadPriority,
        producer: @escaping (URL, Int) -> HistoryImagePreview,
        completion: @escaping (HistoryImagePreview) -> Void
    ) -> HistoryImagePreviewRequest {
        let request = HistoryImagePreviewRequest()
        let key = cacheKey(url: url, pixelSize: pixelSize, cachePrefix: cachePrefix)

        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async { [request] in
                guard !request.isCancelled else { return }
                completion(cached.preview)
            }
            return request
        }

        let waiter = Waiter(request: request, completion: completion)
        let operation = BlockOperation()
        operation.queuePriority = priority.operationQueuePriority
        operation.qualityOfService = priority.qualityOfService
        operation.addExecutionBlock { [weak self] in
            guard let self else { return }
            guard self.claimActiveWaiters(for: key) else { return }

            let preview: HistoryImagePreview
            if let cached = self.cache.object(forKey: key as NSString) {
                preview = cached.preview
            } else {
                preview = producer(url, pixelSize)
                self.cache.setObject(
                    HistoryImagePreviewCacheValue(preview: preview),
                    forKey: key as NSString,
                    cost: preview.estimatedByteCost
                )
            }
            self.finish(key: key, preview: preview)
        }

        inFlightLock.lock()
        if let existingLoad = inFlight[key] {
            existingLoad.waiters.append(waiter)
            promote(existingLoad, to: priority)
            inFlightLock.unlock()
            return request
        }
        inFlight[key] = InFlightLoad(
            waiters: [waiter],
            operation: operation,
            priority: priority
        )
        inFlightLock.unlock()

        queue.addOperation(operation)

        return request
    }

    private func cachedPreview(url: URL, pixelSize: Int, cachePrefix: String) -> HistoryImagePreview? {
        let key = cacheKey(url: url, pixelSize: pixelSize, cachePrefix: cachePrefix)
        return cache.object(forKey: key as NSString)?.preview
    }

    private func claimActiveWaiters(for key: String) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        guard inFlight[key]?.waiters.contains(where: { !$0.request.isCancelled }) == true else {
            inFlight.removeValue(forKey: key)
            return false
        }
        return true
    }

    private func promote(_ load: InFlightLoad, to priority: HistoryImagePreviewLoadPriority) {
        guard priority.rawValue > load.priority.rawValue else { return }
        load.priority = priority
        load.operation.queuePriority = priority.operationQueuePriority
        load.operation.qualityOfService = priority.qualityOfService
    }

    private func finish(key: String, preview: HistoryImagePreview) {
        inFlightLock.lock()
        let waiters = inFlight.removeValue(forKey: key)?.waiters ?? []
        inFlightLock.unlock()

        DispatchQueue.main.async {
            for waiter in waiters where !waiter.request.isCancelled {
                waiter.completion(preview)
            }
        }
    }

    private func cacheKey(url: URL, pixelSize: Int, cachePrefix: String) -> String {
        "\(cachePrefix)#\(url.path)#\(pixelSize)"
    }
}

private final class HistoryImagePreviewCacheValue: NSObject {
    let preview: HistoryImagePreview

    init(preview: HistoryImagePreview) {
        self.preview = preview
    }
}
