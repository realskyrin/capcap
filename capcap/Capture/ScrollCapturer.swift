import AppKit

/// 抓屏和拼接共用串行队列，保证补尾帧不会与正在处理的帧交叉
final class ScrollCapturer {
    enum FrameOutcome: Equatable {
        case appended
        case noNewContent
        case retry
        case atFrameLimit
    }

    struct Result {
        let image: NSImage?
        let isIncomplete: Bool
        let reachedFrameLimit: Bool
    }

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let screen: NSScreen
    private let excludedWindowNumbers: [CGWindowID]
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let stitcher = ScrollStitcher()
    private let estimator = ScrollOffsetEstimator()
    private var isFinishing = false
    private var hasInitialFrame = false

    init(rect: CGRect, screen: NSScreen, excludingWindowNumbers: [CGWindowID] = []) {
        captureRect = rect
        self.screen = screen
        self.excludedWindowNumbers = excludingWindowNumbers
    }

    /// 首帧也在后台抓取，避免 ScreenCaptureKit 初始化阻塞编辑器
    func start(completion: @escaping (Bool) -> Void) {
        captureQueue.async {
            let outcome = self.captureFrame(waitForStability: false)
            self.hasInitialFrame = outcome == .appended
            DispatchQueue.main.async { completion(outcome == .appended) }
        }
    }

    func stopAndStitch(completion: @escaping (Result) -> Void) {
        captureQueue.async {
            self.isFinishing = true
            // 收尾时仍排除原选区和提示窗口，并等待滚动动画停止
            if self.hasInitialFrame && !self.stitcher.reachedFrameLimit {
                _ = self.captureFrame(waitForStability: true)
            }
            let result = Result(
                image: self.stitcher.image,
                isIncomplete: self.stitcher.isIncomplete,
                reachedFrameLimit: self.stitcher.reachedFrameLimit
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    func captureSynchronously(waitForStability: Bool) -> FrameOutcome {
        captureQueue.sync {
            guard !isFinishing else { return .noNewContent }
            return captureFrame(waitForStability: waitForStability)
        }
    }

    private func captureFrame(waitForStability: Bool) -> FrameOutcome {
        guard let image = captureImage(waitForStability: waitForStability) else {
            stitcher.markIncomplete()
            return .retry
        }
        let outcome = stitcher.add(image)
        switch outcome {
        case .appended:
            emitPreview()
            return .appended
        case .revisited:
            // 回滚仍表示页面在移动，不能计入“滚到底”的连续停滞次数
            return .appended
        case .unchanged:
            return .noNewContent
        case .unmatched:
            return .retry
        case .atFrameLimit:
            return .atFrameLimit
        }
    }

    private func captureImage(waitForStability: Bool) -> NSImage? {
        guard waitForStability else { return snapshot(timeout: 3) }

        let deadline = Date().addingTimeInterval(0.65)
        var previous: CGImage?
        var latest: NSImage?
        while deadline.timeIntervalSinceNow > 0 {
            guard let image = snapshot(timeout: deadline.timeIntervalSinceNow),
                  let cgImage = image.cgImagePreservingBacking() else { break }
            latest = image
            // 用正文位移判断稳定，GIF 或闪烁光标无需达到逐像素完全一致
            if let previous,
               let estimate = estimator.estimate(from: cgImage, to: previous),
               abs(estimate.translation.y) <= 1 {
                return image
            }
            previous = cgImage
            let delay = min(0.06, deadline.timeIntervalSinceNow)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        return latest
    }

    private func snapshot(timeout: TimeInterval) -> NSImage? {
        ScreenCapturer.capture(
            rect: captureRect,
            screen: screen,
            excludingWindowNumbers: excludedWindowNumbers,
            timeout: timeout
        )
    }

    private func emitPreview() {
        guard let image = stitcher.image else { return }
        DispatchQueue.main.async { [weak self] in self?.onPreviewUpdated?(image) }
    }
}
