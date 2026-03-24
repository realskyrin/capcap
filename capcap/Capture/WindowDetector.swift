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

    /// Snapshot all visible app-level windows (excluding this app and system chrome).
    func refresh() {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            windows = []
            return
        }

        windows = infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= 0, layer < 20  // normal (0), floating (3), modal panel (8), utility (19)
            else { return nil }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsNS as CFDictionary, &rect) else { return nil }
            guard rect.width > 1, rect.height > 1 else { return nil }

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
