import AppKit
import ScreenCaptureKit

struct ScreenCapturer {
    static func capture(rect: CGRect, screen: NSScreen) -> NSImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        var resultImage: NSImage?
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let image = try await captureAsync(rect: rect, screen: screen)
                resultImage = image
            } catch {
                NSLog("capcap: Screen capture failed: \(error)")
            }
            semaphore.signal()
        }

        semaphore.wait()
        return resultImage
    }

    private static func captureAsync(rect: CGRect, screen: NSScreen) async throws -> NSImage? {
        let content = try await SCShareableContent.current

        // Find the matching SCDisplay for this screen
        guard let display = content.displays.first(where: { display in
            display.displayID == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }) else {
            // Fallback: use first display
            guard let display = content.displays.first else { return nil }
            return try await captureDisplay(display, rect: rect)
        }

        return try await captureDisplay(display, rect: rect)
    }

    private static func captureDisplay(_ display: SCDisplay, rect: CGRect) async throws -> NSImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = max(screenScale(for: display), 1)

        let config = SCStreamConfiguration()
        config.sourceRect = rect
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

    private static func screenScale(for display: SCDisplay) -> CGFloat {
        guard
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            })
        else {
            return 2
        }

        return screen.backingScaleFactor
    }
}
