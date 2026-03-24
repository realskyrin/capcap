import AppKit
import CoreGraphics

struct DetectedWindow {
    let name: String
    let windowID: CGWindowID
    let frame: CGRect   // CG coordinates (global, top-left origin)
}

class WindowDetector {
    private var windows: [DetectedWindow] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Snapshot all visible windows (excluding this app).
    func refresh() {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            windows = []
            return
        }

        let primaryFrame = NSScreen.screens[0].frame
        let screenArea = primaryFrame.width * primaryFrame.height

        windows = infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= 0
            else { return nil }

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
                if rect.width * rect.height > screenArea * 0.8 {
                    return nil
                }
            }

            let name = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0

            return DetectedWindow(name: name, windowID: windowID, frame: rect)
        }
    }

    /// Return the topmost window whose frame contains `cgPoint`
    /// (CG coordinates: origin at top-left of primary display, y increases downward).
    func windowAt(cgPoint: CGPoint) -> DetectedWindow? {
        // CGWindowListCopyWindowInfo returns windows in front-to-back z-order,
        // so the first hit is the topmost window.
        return windows.first { $0.frame.contains(cgPoint) }
    }
}
