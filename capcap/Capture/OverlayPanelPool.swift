import AppKit
import QuartzCore

/// Retains one already-committed full-screen surface per display so a capture
/// trigger never has to wait for WindowServer to allocate a cold surface.
final class OverlayPanelPool {
    private struct PanelLease {
        let displayID: CGDirectDisplayID
        let panel: OverlayPanel
    }

    static let shared = OverlayPanelPool()

    private var panelsByDisplayID: [CGDirectDisplayID: OverlayPanel] = [:]
    private var warmingPanelsByDisplayID: [CGDirectDisplayID: OverlayPanel] = [:]
    private var warmupTimeoutsByDisplayID: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var leasedPanels: [ObjectIdentifier: PanelLease] = [:]
    private var leaseCountsByDisplayID: [CGDirectDisplayID: Int] = [:]

    func prewarm(screens: [NSScreen]) {
        assertMainThread()
        reconcilePanels(with: screens)

        for screen in screens {
            guard let displayID = Self.displayID(for: screen),
                  leaseCountsByDisplayID[displayID, default: 0] == 0 else { continue }
            if let warmingPanel = warmingPanelsByDisplayID[displayID] {
                guard !warmingPanel.isConfigured(for: screen),
                      let panel = takeWarmingPanel(displayID: displayID) else { continue }
                startWarmup(panel: panel, screen: screen, displayID: displayID)
                continue
            }
            if let pooledPanel = panelsByDisplayID[displayID] {
                guard !pooledPanel.hasPresentedSurface(for: screen),
                      let panel = panelsByDisplayID.removeValue(forKey: displayID) else { continue }
                startWarmup(panel: panel, screen: screen, displayID: displayID)
                continue
            }
            startWarmup(panel: makePanel(for: screen), screen: screen, displayID: displayID)
        }
    }

    func invalidateAndPrewarm(screens: [NSScreen]) {
        assertMainThread()
        panelsByDisplayID.values.forEach { $0.invalidatePresentedSurface() }
        leasedPanels.values.forEach { $0.panel.invalidatePresentedSurface() }

        let warmingDisplayIDs = Array(warmingPanelsByDisplayID.keys)
        for displayID in warmingDisplayIDs {
            guard let panel = takeWarmingPanel(displayID: displayID) else { continue }
            panel.invalidatePresentedSurface()
            resetForStorage(panel)
            storePooled(panel, displayID: displayID)
        }
        prewarm(screens: screens)
    }

    func lease(for screen: NSScreen) -> OverlayPanel {
        assertMainThread()
        let displayID = Self.displayID(for: screen)
        let panel = displayID.flatMap(takeWarmingPanel(displayID:))
            ?? displayID.flatMap { panelsByDisplayID.removeValue(forKey: $0) }
            ?? makePanel(for: screen)

        panel.prepareSurface(for: screen)
        if let displayID {
            leasedPanels[ObjectIdentifier(panel)] = PanelLease(
                displayID: displayID,
                panel: panel
            )
            leaseCountsByDisplayID[displayID, default: 0] += 1
        }
        return panel
    }

    func markSurfacePresented(
        _ window: NSWindow,
        for screen: NSScreen,
        presentationToken: UInt64
    ) -> Bool {
        assertMainThread()
        guard let panel = window as? OverlayPanel else { return false }
        return panel.markSurfacePresented(
            for: screen,
            presentationToken: presentationToken
        )
    }

    func recycle(_ window: NSWindow) {
        assertMainThread()
        guard let panel = window as? OverlayPanel else {
            window.orderOut(nil)
            return
        }
        let identifier = ObjectIdentifier(panel)
        guard let lease = leasedPanels.removeValue(forKey: identifier) else {
            dispose(panel)
            return
        }
        let displayID = lease.displayID
        decrementLeaseCount(for: displayID)
        resetForStorage(panel)

        guard let screen = NSScreen.screens.first(where: {
            Self.displayID(for: $0) == displayID
        }) else {
            dispose(panel)
            return
        }
        guard panel.hasPresentedSurface(for: screen) else {
            startWarmup(panel: panel, screen: screen, displayID: displayID)
            return
        }

        if let warmingPanel = takeWarmingPanel(displayID: displayID) {
            dispose(warmingPanel)
        }
        storePooled(panel, displayID: displayID)
    }

    private func reconcilePanels(with screens: [NSScreen]) {
        let liveDisplayIDs = Set(screens.compactMap(Self.displayID(for:)))
        let stalePooledIDs = panelsByDisplayID.keys.filter {
            !liveDisplayIDs.contains($0)
        }
        for displayID in stalePooledIDs {
            if let panel = panelsByDisplayID.removeValue(forKey: displayID) {
                dispose(panel)
            }
        }
        let staleWarmingIDs = warmingPanelsByDisplayID.keys.filter {
            !liveDisplayIDs.contains($0)
        }
        for displayID in staleWarmingIDs {
            if let panel = takeWarmingPanel(displayID: displayID) {
                dispose(panel)
            }
        }
        let staleTimeoutIDs = warmupTimeoutsByDisplayID.keys.filter {
            !liveDisplayIDs.contains($0)
        }
        for displayID in staleTimeoutIDs {
            warmupTimeoutsByDisplayID.removeValue(forKey: displayID)?.cancel()
        }
    }

    private func makePanel(for screen: NSScreen) -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        return panel
    }

    private func startWarmup(
        panel: OverlayPanel,
        screen: NSScreen,
        displayID: CGDirectDisplayID
    ) {
        if warmingPanelsByDisplayID[displayID] !== panel,
           let replacedPanel = takeWarmingPanel(displayID: displayID) {
            dispose(replacedPanel)
        }
        let presentationToken = panel.prepareSurface(for: screen)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.acceptsMouseMovedEvents = false
        panel.animationBehavior = .none

        let warmupView = OverlayWarmupView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        warmupView.onFirstFramePresented = { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard panel.markSurfacePresented(
                for: screen,
                presentationToken: presentationToken
            ) else { return }
            self.finishWarmup(
                panel: panel,
                displayID: displayID,
                timedOut: false
            )
        }
        panel.contentView = warmupView
        warmingPanelsByDisplayID[displayID] = panel
        panel.orderFrontRegardless()

        let timeout = DispatchWorkItem { [weak self, weak panel] in
            guard let panel else { return }
            self?.finishWarmup(
                panel: panel,
                displayID: displayID,
                timedOut: true
            )
        }
        warmupTimeoutsByDisplayID[displayID] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func takeWarmingPanel(displayID: CGDirectDisplayID) -> OverlayPanel? {
        guard let panel = warmingPanelsByDisplayID.removeValue(forKey: displayID) else {
            return nil
        }
        warmupTimeoutsByDisplayID.removeValue(forKey: displayID)?.cancel()
        (panel.contentView as? OverlayWarmupView)?.cancelPresentationTracking()
        panel.contentView = nil
        return panel
    }

    private func finishWarmup(
        panel: OverlayPanel,
        displayID: CGDirectDisplayID,
        timedOut: Bool
    ) {
        guard warmingPanelsByDisplayID[displayID] === panel else { return }
        _ = takeWarmingPanel(displayID: displayID)
        resetForStorage(panel)
        storePooled(panel, displayID: displayID)

        guard timedOut else { return }
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(
                "overlay-prewarm",
                "presentation-surface-timeout",
                metadata: ["displayID": displayID]
            )
        }
    }

    private func storePooled(_ panel: OverlayPanel, displayID: CGDirectDisplayID) {
        if let replacedPanel = panelsByDisplayID.updateValue(panel, forKey: displayID),
           replacedPanel !== panel {
            dispose(replacedPanel)
        }
    }

    private func resetForStorage(_ panel: OverlayPanel) {
        _ = panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.initialFirstResponder = nil
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.collectionBehavior = []
        panel.sharingType = .none
    }

    private func dispose(_ panel: OverlayPanel) {
        (panel.contentView as? OverlayWarmupView)?.cancelPresentationTracking()
        resetForStorage(panel)
        panel.close()
    }

    private func decrementLeaseCount(for displayID: CGDirectDisplayID) {
        let remaining = leaseCountsByDisplayID[displayID, default: 1] - 1
        if remaining > 0 {
            leaseCountsByDisplayID[displayID] = remaining
        } else {
            leaseCountsByDisplayID.removeValue(forKey: displayID)
        }
    }

    private func assertMainThread() {
        precondition(Thread.isMainThread, "Overlay panel lifecycle must stay on the main thread")
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }
}

private final class OverlayWarmupView: NSView {
    var onFirstFramePresented: (() -> Void)?

    private var displayLink: CADisplayLink?
    private var didSchedulePresentation = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.001).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        schedulePresentationIfNeeded()
    }

    func cancelPresentationTracking() {
        displayLink?.invalidate()
        displayLink = nil
        onFirstFramePresented = nil
    }

    private func schedulePresentationIfNeeded() {
        guard !didSchedulePresentation else { return }
        didSchedulePresentation = true
        let displayLink = displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        displayLink.invalidate()
        self.displayLink = nil
        onFirstFramePresented?()
        onFirstFramePresented = nil
    }
}

/// The selection shell stays nonactivating; editor code may explicitly make
/// it key only after the frozen screenshot is ready.
final class OverlayPanel: NSPanel {
    private struct SurfaceSignature: Equatable {
        let frame: NSRect
        let scale: CGFloat
    }

    private var configuredSurface: SurfaceSignature?
    private var presentedSurface: SurfaceSignature?
    private(set) var surfacePresentationToken: UInt64 = 0

    @discardableResult
    func prepareSurface(for screen: NSScreen) -> UInt64 {
        let signature = Self.signature(for: screen)
        if configuredSurface != signature {
            presentedSurface = nil
        }
        surfacePresentationToken &+= 1
        setFrame(screen.frame, display: false)
        configuredSurface = signature
        return surfacePresentationToken
    }

    func isConfigured(for screen: NSScreen) -> Bool {
        configuredSurface == Self.signature(for: screen)
    }

    @discardableResult
    func markSurfacePresented(
        for screen: NSScreen,
        presentationToken: UInt64
    ) -> Bool {
        guard presentationToken == surfacePresentationToken,
              isConfigured(for: screen) else { return false }
        presentedSurface = Self.signature(for: screen)
        return true
    }

    func hasPresentedSurface(for screen: NSScreen) -> Bool {
        presentedSurface == Self.signature(for: screen)
    }

    func invalidatePresentedSurface() {
        surfacePresentationToken &+= 1
        presentedSurface = nil
    }

    private static func signature(for screen: NSScreen) -> SurfaceSignature {
        SurfaceSignature(frame: screen.frame, scale: screen.backingScaleFactor)
    }

    override var canBecomeKey: Bool { true }
}
