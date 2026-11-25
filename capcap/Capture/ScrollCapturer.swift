import AppKit
import os

/// 抓屏和拼接共用串行队列，保证补尾帧不会与正在处理的帧交叉
final class ScrollCapturer {
    // 仅记录尺寸、耗时和匹配结果，便于定位漏拼接，不记录页面内容
    private static let diagnostics = Logger(subsystem: "cn.skyrin.capcap", category: "ScrollCapture")
    enum FrameOutcome: Equatable {
        case appended
        case revisited
        case noNewContent
        case retry
        case atFrameLimit
    }

    struct Result {
        let image: NSImage?
        let isIncomplete: Bool
        let reachedFrameLimit: Bool
    }

    struct ScrollInput {
        private(set) var upwardEvents = 0
        private(set) var downwardEvents = 0

        var direction: ScrollStitcher.ScrollDirection? {
            // 碰底等情况会吞掉滚轮距离；正反输入混合时不能用净距离推断页面方向
            if upwardEvents > 0 && downwardEvents > 0 { return nil }
            if upwardEvents > 0 { return .up }
            if downwardEvents > 0 { return .down }
            return nil
        }

        mutating func record(deltaY: CGFloat) {
            guard deltaY.isFinite, deltaY != 0 else { return }
            if deltaY < 0 { downwardEvents += 1 }
            else { upwardEvents += 1 }
        }

        mutating func acknowledge(_ captured: ScrollInput) {
            upwardEvents -= captured.upwardEvents
            downwardEvents -= captured.downwardEvents
        }
    }

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private var matchingRect: CGRect
    private let screen: NSScreen
    private let excludedWindowNumbers: [CGWindowID]
    private let captureQueue = DispatchQueue(label: "capcap.scroll-capture", qos: .userInitiated)
    private let contentSession = ScreenCapturer.ContentSession()
    private let stitcher = ScrollStitcher()
    private let estimator = ScrollOffsetEstimator()
    private let inputLock = NSLock()
    private var scrollInput = ScrollInput()
    private var scrollMonitor: Any?
    private var isFinishing = false
    private var hasInitialFrame = false
    private var finalResult: Result?
    private var diagnosticFrame = 0
    private var lastCaptureStarted: TimeInterval?

    init(rect: CGRect, screen: NSScreen, excludingWindowNumbers: [CGWindowID] = []) {
        captureRect = rect
        matchingRect = rect
        self.screen = screen
        self.excludedWindowNumbers = excludingWindowNumbers
    }

    deinit {
        if let scrollMonitor {
            DispatchQueue.main.async { NSEvent.removeMonitor(scrollMonitor) }
        }
    }

    /// 首帧也在后台抓取，避免 ScreenCaptureKit 初始化阻塞编辑器
    func start(completion: @escaping (Bool) -> Void) {
        let windows = try? WindowDetector.snapshot(primaryScreenArea: screen.frame.width * screen.frame.height).get()
        // 小选区之外的同一页面也可滚动，但其他窗口的输入不能改变本次方向
        let sourceBounds = windows?.first {
            !excludedWindowNumbers.contains($0.windowID) &&
                $0.frame.contains(CGPoint(x: captureRect.midX, y: captureRect.midY))
        }?.frame
        let inputRect = sourceBounds ?? captureRect
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            matchingRect = Self.matchingRect(for: captureRect, sourceBounds: sourceBounds,
                                            displayBounds: CGDisplayBounds(displayID))
        }
        // 只监听方向，不拦截事件；手动滚动与发往浏览器的自动滚动共用这条约束
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let point = event.cgEvent?.location, inputRect.contains(point) else { return }
            self.inputLock.withLock { self.scrollInput.record(deltaY: event.scrollingDeltaY) }
        }
        captureQueue.async {
            let outcome = self.captureFrame(waitForStability: false)
            self.hasInitialFrame = outcome == .appended
            DispatchQueue.main.async { completion(outcome == .appended) }
        }
    }

    func stopAndStitch(completion: @escaping (Result) -> Void) {
        captureQueue.async {
            if let result = self.finalResult {
                DispatchQueue.main.async {
                    self.removeScrollMonitor()
                    completion(result)
                }
                return
            }
            self.isFinishing = true
            defer { self.contentSession.finish() }
            // 收尾时仍排除原选区和提示窗口，并等待滚动动画停止
            if self.hasInitialFrame && !self.stitcher.reachedFrameLimit {
                _ = self.captureFrame(waitForStability: true)
            }
            let result = Result(
                image: self.stitcher.takeImage().flatMap { self.selectedImage(from: $0) },
                isIncomplete: self.stitcher.isIncomplete,
                reachedFrameLimit: self.stitcher.reachedFrameLimit
            )
            self.finalResult = result
            DispatchQueue.main.async {
                self.removeScrollMonitor()
                completion(result)
            }
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    func captureSynchronously(waitForStability: Bool) -> FrameOutcome {
        captureQueue.sync {
            guard !isFinishing else { return .noNewContent }
            return autoreleasepool { captureFrame(waitForStability: waitForStability) }
        }
    }

    private func captureFrame(waitForStability: Bool) -> FrameOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        let interval = lastCaptureStarted.map { Int((started - $0) * 1000) } ?? 0
        lastCaptureStarted = started
        diagnosticFrame += 1
        let capturedInput = inputLock.withLock { scrollInput }
        Self.diagnostics.debug("frame_begin n=\(self.diagnosticFrame) interval_ms=\(interval) up=\(capturedInput.upwardEvents) down=\(capturedInput.downwardEvents)")
        guard let image = captureImage(waitForStability: waitForStability) else {
            Self.diagnostics.debug("frame_capture_failed n=\(self.diagnosticFrame)")
            stitcher.markIncomplete()
            return .retry
        }
        let captured = ProcessInfo.processInfo.systemUptime
        let outcome = stitcher.add(image, expectedScrollDirection: capturedInput.direction)
        let finished = ProcessInfo.processInfo.systemUptime
        Self.diagnostics.debug("frame_end n=\(self.diagnosticFrame) width=\(image.size.width) height=\(image.size.height) capture_ms=\(Int((captured - started) * 1000)) match_ms=\(Int((finished - captured) * 1000)) outcome=\(String(describing: outcome), privacy: .public)")
        if outcome == .appended || outcome == .revisited {
            // 只确认采帧开始前的输入，抓屏和匹配期间发生的滚动留给下一帧
            inputLock.withLock { scrollInput.acknowledge(capturedInput) }
        }
        switch outcome {
        case .appended:
            emitPreview()
            return .appended
        case .revisited:
            // 保留手动回退的参考位置，由自动滚动策略判断是否仍有新增内容
            return .revisited
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
            rect: matchingRect,
            screen: screen,
            excludingWindowNumbers: excludedWindowNumbers,
            contentSession: contentSession,
            timeout: timeout
        )
    }

    private func emitPreview() {
        guard let thumbnail = stitcher.thumbnail(), let image = selectedImage(from: thumbnail) else { return }
        DispatchQueue.main.async { [weak self] in self?.onPreviewUpdated?(image) }
    }

    static func matchingRect(for selection: CGRect, sourceBounds: CGRect?, displayBounds: CGRect) -> CGRect {
        guard let sourceBounds else { return selection }
        let available = sourceBounds.intersection(displayBounds)
        // 矮选区穿过段落空白时没有足够锚点；只借用同一窗口、同一屏幕内的上下文
        guard available.contains(selection), selection.height < 400 else { return selection }
        let height = min(400, available.height)
        let top = min(max(selection.midY - height / 2, available.minY), available.maxY - height)
        return CGRect(x: selection.minX, y: top, width: selection.width, height: height)
    }

    private func selectedImage(from image: NSImage) -> NSImage? {
        Self.selectedImage(from: image, selection: captureRect, matchingRect: matchingRect)
    }

    static func selectedImage(from image: NSImage, selection: CGRect, matchingRect: CGRect) -> NSImage? {
        guard selection != matchingRect else { return image }
        guard image.size.height > 0, let backing = image.cgImagePreservingBacking() else { return nil }
        let topPadding = selection.minY - matchingRect.minY
        let bottomPadding = matchingRect.maxY - selection.maxY
        let height = image.size.height - topPadding - bottomPadding
        guard topPadding >= 0, bottomPadding >= 0, height > 0 else { return nil }
        // 缩略图保留成图的逻辑尺寸，必须按各自像素比例裁剪，不能固定使用屏幕倍率
        let scale = CGFloat(backing.height) / image.size.height
        let pixelHeight = min(backing.height, max(1, Int(ceil(height * scale))))
        let top = min(backing.height - pixelHeight, Int((topPadding * scale).rounded()))
        guard let cropped = backing.cropping(to: CGRect(x: 0, y: top, width: backing.width, height: pixelHeight)) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: selection.width, height: height))
    }
}
