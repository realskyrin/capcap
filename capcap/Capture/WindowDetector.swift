import AppKit
import CoreGraphics

struct DetectedWindow: Sendable {
    let name: String
    let windowID: CGWindowID
    let layer: Int
    let frame: CGRect   // CG coordinates (global, top-left origin)

    var usesCompositedScreenBackdrop: Bool {
        layer >= 20
    }
}

enum WindowDetectionError: LocalizedError, Sendable {
    case invalidPrimaryScreenArea(CGFloat)
    case windowListUnavailable
    case invalidWindowListPayload

    var errorDescription: String? {
        switch self {
        case .invalidPrimaryScreenArea(let area):
            return "Invalid primary screen area for window detection: \(area)"
        case .windowListUnavailable:
            return "Core Graphics did not return a window list"
        case .invalidWindowListPayload:
            return "Core Graphics returned an unexpected window list payload"
        }
    }
}

class WindowDetector {
    private var windows: [DetectedWindow] = []

    /// Build an immutable window snapshot without touching AppKit screen state
    /// or this detector's mutable state. Safe to call from a background queue.
    static func snapshot(
        primaryScreenArea: CGFloat
    ) -> Result<[DetectedWindow], WindowDetectionError> {
        guard primaryScreenArea.isFinite, primaryScreenArea > 0 else {
            return .failure(.invalidPrimaryScreenArea(primaryScreenArea))
        }

        guard let rawInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) else {
            return .failure(.windowListUnavailable)
        }
        guard let infoList = rawInfoList as? [[String: Any]] else {
            return .failure(.invalidWindowListPayload)
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        let detectedWindows: [DetectedWindow] = infoList.compactMap { info -> DetectedWindow? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= 0
            else { return nil }

            // Keep this app's own menus/popups detectable so capcap can capture
            // its visible transient UI. Only screen-saver-level chrome (toasts,
            // tooltips, countdown and progress panels) is excluded.
            // The capture overlay itself is created after refresh(), so it is
            // never in this snapshot.
            if pid == ownPID && layer >= Int(CGWindowLevelForKey(.screenSaverWindow)) {
                return nil
            }

            // Skip fully transparent windows (invisible system overlays)
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                return nil
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsNS as CFDictionary, &rect) else { return nil }
            guard rect.width > 1, rect.height > 1 else { return nil }

            // For windows above normal app levels (dock, menu bar, popups, etc.),
            // skip near-full-screen ones — these are typically invisible system
            // overlays (e.g. input method backgrounds) that block real windows.
            if layer >= 20 {
                if rect.width * rect.height > primaryScreenArea * 0.8 {
                    return nil
                }
            }

            let name = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0

            return DetectedWindow(name: name, windowID: windowID, layer: layer, frame: rect)
        }

        return .success(detectedWindows)
    }

    /// Commit a previously-created value snapshot to this detector.
    func apply(_ detectedWindows: [DetectedWindow]) {
        windows = detectedWindows
    }

    /// High-layer system surfaces (menu bar, Dock, popups) are often only a
    /// translucent foreground when captured as independent windows. Capture
    /// their already-composited screen pixels instead.
    func usesCompositedScreenBackdrop(forWindowID windowID: CGWindowID) -> Bool {
        windows.first { $0.windowID == windowID }?.usesCompositedScreenBackdrop ?? false
    }

    /// Return the topmost window whose frame contains `cgPoint`
    /// (CG coordinates: origin at top-left of primary display, y increases downward).
    func windowAt(cgPoint: CGPoint) -> DetectedWindow? {
        // CGWindowListCopyWindowInfo returns windows in front-to-back z-order,
        // so the first hit is the topmost window.
        return windows.first { $0.frame.contains(cgPoint) }
    }
}
