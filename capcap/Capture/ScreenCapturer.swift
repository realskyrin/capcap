import AppKit
import ScreenCaptureKit

struct ScreenCapturer {
    /// - Parameter excludingWindowNumbers: window numbers (`NSWindow.windowNumber`)
    ///   to omit from the capture — used so capcap's own scroll-capture chrome
    ///   (e.g. the on-screen hint toast) is never baked into a captured frame.
    static func capture(
        rect: CGRect,
        screen: NSScreen,
        excludingWindowNumbers: [CGWindowID] = [],
        timeout: TimeInterval? = nil
    ) -> NSImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let excludedWindowNumbers = effectiveExcludedWindowNumbers(excludingWindowNumbers)
        let requestedDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let screenScale = screen.backingScaleFactor

        let resultBox = CaptureResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        // The headless agent entrypoint calls this bridge on the process main
        // thread. A regular Task inherits that executor and cannot start while
        // the main thread is blocked by the semaphore below.
        let task = Task.detached {
            do {
                let image = try await captureAsync(
                    rect: rect,
                    requestedDisplayID: requestedDisplayID,
                    screenScale: screenScale,
                    excludingWindowNumbers: excludedWindowNumbers
                )
                resultBox.set(image)
            } catch {}
            semaphore.signal()
        }

        if let timeout {
            let waitResult = semaphore.wait(timeout: .now() + .milliseconds(max(1, Int(timeout * 1000))))
            if waitResult == .timedOut {
                task.cancel()
                return nil
            }
        } else {
            semaphore.wait()
        }
        return resultBox.get()
    }

    private static func effectiveExcludedWindowNumbers(_ windowNumbers: [CGWindowID]) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        return (windowNumbers + ToastWindow.captureExcludedWindowNumbers).filter { windowNumber in
            windowNumber > 0 && seen.insert(windowNumber).inserted
        }
    }

    /// Synchronous bridge retained for the headless agent command, which runs
    /// capture work outside the interactive overlay path.
    static func capture(
        windowID: CGWindowID,
        pointSize: NSSize? = nil,
        timeout: TimeInterval? = nil
    ) -> NSImage? {
        let resultBox = CaptureResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task.detached {
            do {
                let image = try await captureWindowAsync(windowID: windowID, pointSize: pointSize)
                resultBox.set(image)
            } catch {}
            semaphore.signal()
        }

        if let timeout {
            let waitResult = semaphore.wait(timeout: .now() + .milliseconds(max(1, Int(timeout * 1000))))
            if waitResult == .timedOut {
                task.cancel()
                return nil
            }
        } else {
            semaphore.wait()
        }
        return resultBox.get()
    }

    static func isEffectivelyTransparent(_ image: NSImage, alphaThreshold: UInt8 = 3) -> Bool {
        guard let cgImage = image.cgImagePreservingBacking() else { return false }

        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return true }

        let sampleMaxDimension = 32
        let sampleScale = min(
            1,
            CGFloat(sampleMaxDimension) / CGFloat(max(width, height))
        )
        let sampleWidth = max(1, Int(ceil(CGFloat(width) * sampleScale)))
        let sampleHeight = max(1, Int(ceil(CGFloat(height) * sampleScale)))
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * sampleHeight)

        let drewImage = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }

        guard drewImage else { return false }

        for index in stride(from: 3, to: rgba.count, by: bytesPerPixel) {
            if rgba[index] > alphaThreshold {
                return false
            }
        }
        return true
    }

    private static func captureAsync(
        rect: CGRect,
        requestedDisplayID: CGDirectDisplayID?,
        screenScale: CGFloat,
        excludingWindowNumbers: [CGWindowID]
    ) async throws -> NSImage? {
        let content = try await SCShareableContent.current
        let excludedWindows = excludingWindowNumbers.isEmpty
            ? []
            : content.windows.filter { excludingWindowNumbers.contains($0.windowID) }

        // Find the matching SCDisplay for this screen
        guard let display = content.displays.first(where: { display in
            display.displayID == requestedDisplayID
        }) else {
            // Fallback: use first display
            guard let display = content.displays.first else { return nil }
            return try await captureDisplay(
                display,
                rect: rect,
                scale: screenScale,
                excludingWindows: excludedWindows
            )
        }

        return try await captureDisplay(
            display,
            rect: rect,
            scale: screenScale,
            excludingWindows: excludedWindows
        )
    }

    static func captureWindowAsync(windowID: CGWindowID, pointSize: NSSize?) async throws -> NSImage? {
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let contentSize = filter.contentRect.size

        // Backing-store dimensions come from the ScreenCaptureKit content rect,
        // not from `pointSize`. `pointSize` is the overlay selection rect — a
        // separately measured quantity (CGWindowList frame vs ScreenCaptureKit
        // contentRect) that diverges from the real window content by sub-point
        // rounding and titlebar handling, most visibly on browsers. Tagging the
        // NSImage with it left the logical size larger than its backing pixels,
        // so rendering/export exposed a transparent strip on the right edge
        // (issue #135). `windowImage(from:scale:)` now derives the logical size
        // from the captured CGImage's own pixel dimensions, so the image is
        // always self-consistent at the display scale. `pointSize` is retained
        // on the signature only for call-site stability.
        let pixelWidth = max(Int(ceil(contentSize.width * scale)), 1)
        let pixelHeight = max(Int(ceil(contentSize.height * scale)), 1)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.capturesAudio = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return windowImage(from: image, scale: scale)
    }

    /// Wrap a captured window `CGImage` in an `NSImage` whose logical size is
    /// derived from the image's own backing pixel dimensions (not from any
    /// overlay selection rect), so it is always self-consistent at `scale`:
    /// rendered at its logical size, it reproduces exactly its pixel count,
    /// with no edge overhang into transparent space (issue #135, browser
    /// auto-snap right blank strip). Tagging from the actual `CGImage` width
    /// — rather than the requested `config.width` — also stays correct if
    /// ScreenCaptureKit ever returns a pixel count that differs from the
    /// request (e.g. under `captureResolution = .best`).
    static func windowImage(from cgImage: CGImage, scale: CGFloat) -> NSImage {
        let imageSize = NSSize(
            width: logicalSize(forPixelWidth: cgImage.width, scale: scale),
            height: logicalSize(forPixelWidth: cgImage.height, scale: scale)
        )
        return NSImage(cgImage: cgImage, size: imageSize)
    }

    /// Convert a backing-store pixel extent to the logical (point) extent that
    /// maps onto exactly that many pixels at `scale` — the inverse of the
    /// `ceil(points * scale)` rounding used to size a window capture. Tagging
    /// an `NSImage` with sizes produced by this helper keeps it self-consistent:
    /// rendered at its logical size at `scale`, it reproduces exactly its
    /// backing pixel count, so no edge overhangs into transparent space.
    static func logicalSize(forPixelWidth pixelWidth: Int, scale: CGFloat) -> CGFloat {
        CGFloat(max(pixelWidth, 0)) / max(scale, 1)
    }

    private static func captureDisplay(
        _ display: SCDisplay,
        rect: CGRect,
        scale: CGFloat,
        excludingWindows: [SCWindow]
    ) async throws -> NSImage? {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let scale = max(scale, 1)

        // sourceRect must be in the display's local coordinate space (top-left
        // origin of *this* display), not the global CG coordinate space. For
        // extended displays whose CGDisplayBounds origin is non-zero, passing
        // the global rect captures the wrong region (or nothing).
        let displayBounds = CGDisplayBounds(display.displayID)
        let localRect = CGRect(
            x: rect.origin.x - displayBounds.origin.x,
            y: rect.origin.y - displayBounds.origin.y,
            width: rect.width,
            height: rect.height
        )

        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        config.width = max(Int(ceil(rect.width * scale)), 1)
        config.height = max(Int(ceil(rect.height * scale)), 1)
        config.capturesAudio = false
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return NSImage(cgImage: image, size: NSSize(width: rect.width, height: rect.height))
    }

    /// Crop a region from a pre-captured full-screen CGImage (e.g. from CGDisplayCreateImage).
    static func crop(from snapshot: CGImage, captureRect: CGRect, screen: NSScreen) -> NSImage? {
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        let displayBounds = CGDisplayBounds(displayID)

        // Convert global CG rect to display-local coordinates
        let localRect = CGRect(
            x: captureRect.origin.x - displayBounds.origin.x,
            y: captureRect.origin.y - displayBounds.origin.y,
            width: captureRect.width,
            height: captureRect.height
        )

        // Scale to image pixel coordinates (Retina)
        let scaleX = CGFloat(snapshot.width) / displayBounds.width
        let scaleY = CGFloat(snapshot.height) / displayBounds.height
        let imageRect = CGRect(
            x: localRect.origin.x * scaleX,
            y: localRect.origin.y * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        )

        guard let cropped = snapshot.cropping(to: imageRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: captureRect.width, height: captureRect.height))
    }

    private final class CaptureResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: NSImage?

        func set(_ image: NSImage?) {
            lock.lock()
            self.image = image
            lock.unlock()
        }

        func get() -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }
}
