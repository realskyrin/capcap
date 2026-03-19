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

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * 2) // Retina
        config.height = Int(rect.height * 2)
        config.capturesAudio = false
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return NSImage(cgImage: image, size: NSSize(width: rect.width, height: rect.height))
    }
}
