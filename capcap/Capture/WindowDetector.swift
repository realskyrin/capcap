import AppKit
import CoreGraphics

enum DetectedWindowTarget: Equatable, Sendable {
    case applicationWindow
    case menuBarComponent
}

struct WindowDetectionContext: Sendable {
    let primaryScreenArea: CGFloat
    let displayBounds: [CGRect]
}

struct DetectedWindow: Sendable {
    let name: String
    let windowID: CGWindowID
    let layer: Int
    let frame: CGRect   // CG coordinates (global, top-left origin)
    let target: DetectedWindowTarget

    var usesCompositedScreenBackdrop: Bool {
        target == .menuBarComponent
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
        context: WindowDetectionContext
    ) -> Result<[DetectedWindow], WindowDetectionError> {
        guard context.primaryScreenArea.isFinite, context.primaryScreenArea > 0 else {
            return .failure(.invalidPrimaryScreenArea(context.primaryScreenArea))
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
            guard let target = targetType(
                layer: layer,
                frame: rect,
                displayBounds: context.displayBounds
            ) else { return nil }

            let name = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            return DetectedWindow(
                name: name,
                windowID: windowID,
                layer: layer,
                frame: rect,
                target: target
            )
        }

        return .success(detectedWindows)
    }

    /// Classifies only stable capture targets. Layer-0 app windows remain
    /// selectable. At the status-window level, accept a single short window
    /// aligned to the top of one display, while rejecting full menu bars and
    /// other high-layer transient surfaces.
    static func targetType(
        layer: Int,
        frame: CGRect,
        displayBounds: [CGRect]
    ) -> DetectedWindowTarget? {
        if layer == 0 {
            return .applicationWindow
        }
        guard layer == Int(CGWindowLevelForKey(.statusWindow)),
              frame.width > 1,
              frame.height > 1,
              frame.height <= 64
        else { return nil }

        let owningDisplay = displayBounds.first { display in
            guard display.width > 1, display.height > 1 else { return false }
            let isTopAligned = abs(frame.minY - display.minY) <= 1
            let isFullyContained = frame.minX >= display.minX
                && frame.maxX <= display.maxX
                && frame.minY >= display.minY
                && frame.maxY <= display.maxY
            let isIndividualComponent = frame.width < display.width * 0.8
            return isTopAligned && isFullyContained && isIndividualComponent
        }
        return owningDisplay == nil ? nil : .menuBarComponent
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
        windows.first { $0.frame.contains(cgPoint) }
    }
}
