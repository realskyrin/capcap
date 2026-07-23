import AppKit
import XCTest
@testable import capcap

@MainActor
final class OverlayPresentationTests: XCTestCase {
    override func tearDown() {
        ToastWindow.dismiss()
        super.tearDown()
    }

    func testOverlayIsInteractiveBeforeTwoSecondPreparationFinishes() {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider(delay: 2)
        var controller: OverlayWindowController!
        var captureStartedBeforePresentation = false
        provider.onCapture = {
            captureStartedBeforePresentation = controller.activeSelectionViews.isEmpty
        }
        controller = OverlayWindowController(
            snapshotProvider: provider,
            windowSnapshotLoader: { _ in
                Thread.sleep(forTimeInterval: 2)
                return .success([])
            },
            onComplete: { _ in }
        )

        let started = ProcessInfo.processInfo.systemUptime
        controller.activate()
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertTrue(controller.isOverlayPresented)
        XCTAssertTrue(controller.isSelectionInteractive)
        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertTrue(captureStartedBeforePresentation)
        XCTAssertTrue(controller.activeSelectionViews.allSatisfy {
            $0.window?.isKeyWindow == false
        })

        controller.activate()
        XCTAssertEqual(provider.captureCount, 1, "Repeated activation must not start a second session")
        controller.cancel()
        XCTAssertEqual(provider.cancellationCount, 1)
    }

    func testSelectionWaitsWithoutBlockingAndResumesWhenItsSnapshotArrives() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider()
        let controller = OverlayWindowController(snapshotProvider: provider, onComplete: { _ in })
        controller.activate()

        let selectionView = try XCTUnwrap(controller.activeSelectionViews.first)
        let displayID = try XCTUnwrap(provider.targets.first?.displayID)
        controller.selectionDidComplete(
            rect: selectionRect(in: selectionView),
            inView: selectionView,
            isWindowSelection: false,
            windowID: nil
        )

        XCTAssertTrue(controller.isWaitingForSnapshot)
        XCTAssertFalse(controller.hasActiveEditor)

        provider.emit(.image(displayID: displayID, image: makeImage()))
        drainMainRunLoop()

        XCTAssertFalse(controller.isWaitingForSnapshot)
        XCTAssertTrue(controller.hasActiveEditor)
        XCTAssertEqual(controller.appliedSnapshotCount, 1)
        controller.cancel()
    }

    func testSelectedDisplayFailureEndsSessionWithoutSynchronousFallback() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider()
        var completionCount = 0
        let controller = OverlayWindowController(snapshotProvider: provider) { _ in
            completionCount += 1
        }
        controller.activate()

        let selectionView = try XCTUnwrap(controller.activeSelectionViews.first)
        let displayID = try XCTUnwrap(provider.targets.first?.displayID)
        controller.selectionDidComplete(
            rect: selectionRect(in: selectionView),
            inView: selectionView,
            isWindowSelection: false,
            windowID: nil
        )
        provider.emit(.failure(displayID: displayID, error: TestCaptureError.failed))
        drainMainRunLoop()

        XCTAssertTrue(controller.isCaptureSessionEnded)
        XCTAssertFalse(controller.isOverlayPresented)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(provider.cancellationCount, 1)
    }

    func testFinishedWithoutSelectedDisplaySnapshotFailsExplicitly() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider()
        var completionCount = 0
        let controller = OverlayWindowController(snapshotProvider: provider) { _ in
            completionCount += 1
        }
        controller.activate()
        provider.emit(.finished)
        drainMainRunLoop()

        let selectionView = try XCTUnwrap(controller.activeSelectionViews.first)
        controller.selectionDidComplete(
            rect: selectionRect(in: selectionView),
            inView: selectionView,
            isWindowSelection: false,
            windowID: nil
        )

        XCTAssertTrue(controller.isCaptureSessionEnded)
        XCTAssertEqual(completionCount, 1)
    }

    func testCancelDiscardsLateSnapshotCallback() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider()
        var completionCount = 0
        let controller = OverlayWindowController(snapshotProvider: provider) { _ in
            completionCount += 1
        }
        controller.activate()
        let displayID = try XCTUnwrap(provider.targets.first?.displayID)

        controller.cancel()
        provider.emit(.image(displayID: displayID, image: makeImage()))
        drainMainRunLoop()

        XCTAssertEqual(controller.appliedSnapshotCount, 0)
        XCTAssertEqual(provider.cancellationCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(controller.isCaptureSessionEnded)
    }

    func testEscapeCancelsWhileSnapshotIsPending() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider(delay: 2)
        var completionCount = 0
        let controller = OverlayWindowController(snapshotProvider: provider) { _ in
            completionCount += 1
        }
        controller.activate()
        let windowNumber = try XCTUnwrap(controller.activeSelectionViews.first?.window?.windowNumber)
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )

        NSApp.sendEvent(escape)
        drainMainRunLoop()

        XCTAssertTrue(controller.isCaptureSessionEnded)
        XCTAssertEqual(provider.cancellationCount, 1)
        XCTAssertEqual(completionCount, 1)
    }

    func testOverlayPanelsAreReusedAcrossSessions() throws {
        _ = NSApplication.shared
        let firstController = OverlayWindowController(
            snapshotProvider: ControlledScreenSnapshotProvider(),
            onComplete: { _ in }
        )
        firstController.activate()
        let firstPanels = firstController.activeSelectionViews.compactMap(\.window)
        XCTAssertFalse(firstPanels.isEmpty)
        firstController.cancel()

        let secondController = OverlayWindowController(
            snapshotProvider: ControlledScreenSnapshotProvider(),
            onComplete: { _ in }
        )
        secondController.activate()
        let secondPanels = secondController.activeSelectionViews.compactMap(\.window)

        XCTAssertEqual(firstPanels.count, secondPanels.count)
        XCTAssertTrue(zip(firstPanels, secondPanels).allSatisfy { $0 === $1 })
        secondController.cancel()
    }

    func testScreenParameterChangeCancelsSelectionSession() {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider(delay: 2)
        var completionCount = 0
        let controller = OverlayWindowController(snapshotProvider: provider) { _ in
            completionCount += 1
        }
        controller.activate()

        controller.screenParametersDidChange()

        XCTAssertTrue(controller.isCaptureSessionEnded)
        XCTAssertEqual(provider.cancellationCount, 1)
        XCTAssertEqual(completionCount, 1)
    }

    func testCancelClearsPendingWindowCaptureContinuation() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider()
        let controller = OverlayWindowController(
            snapshotProvider: provider,
            windowSnapshotLoader: { _ in .success([]) },
            windowImageLoader: { _, _ in
                try await Task.sleep(for: .seconds(2))
                return nil
            },
            onComplete: { _ in }
        )
        controller.activate()
        let selectionView = try XCTUnwrap(controller.activeSelectionViews.first)
        let displayID = try XCTUnwrap(provider.targets.first?.displayID)
        provider.emit(.image(displayID: displayID, image: makeImage()))
        drainMainRunLoop()

        controller.selectionDidComplete(
            rect: selectionRect(in: selectionView),
            inView: selectionView,
            isWindowSelection: true,
            windowID: 42
        )
        XCTAssertTrue(controller.isWaitingForWindowCapture)

        controller.cancel()
        drainMainRunLoop()

        XCTAssertFalse(controller.isWaitingForWindowCapture)
        XCTAssertTrue(controller.isCaptureSessionEnded)
    }

    func testSurfaceIsWarmOnlyAfterPresentedFrame() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let stalePresentationToken = panel.prepareSurface(for: screen)

        XCTAssertFalse(panel.hasPresentedSurface(for: screen))
        XCTAssertTrue(panel.markSurfacePresented(
            for: screen,
            presentationToken: stalePresentationToken
        ))
        XCTAssertTrue(panel.hasPresentedSurface(for: screen))
        panel.invalidatePresentedSurface()
        XCTAssertFalse(panel.hasPresentedSurface(for: screen))
        XCTAssertFalse(panel.markSurfacePresented(
            for: screen,
            presentationToken: stalePresentationToken
        ))
        XCTAssertFalse(panel.hasPresentedSurface(for: screen))
        panel.close()
    }

    private func selectionRect(in view: SelectionView) -> NSRect {
        NSRect(
            x: 10,
            y: 10,
            width: min(100, max(5, view.bounds.width - 20)),
            height: min(80, max(5, view.bounds.height - 20))
        )
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

}

private final class ControlledScreenSnapshotProvider: ScreenSnapshotProviding {
    private(set) var captureCount = 0
    private(set) var cancellationCount = 0
    private(set) var targets: [ScreenSnapshotTarget] = []
    private var eventHandler: ((ScreenSnapshotEvent) -> Void)?
    private var delayedWorkItem: DispatchWorkItem?
    private let delay: TimeInterval?
    var onCapture: (() -> Void)?

    init(delay: TimeInterval? = nil) {
        self.delay = delay
    }

    func prewarm() {}

    @discardableResult
    func capture(
        targets: [ScreenSnapshotTarget],
        eventHandler: @escaping (ScreenSnapshotEvent) -> Void
    ) -> ScreenSnapshotCancellation {
        captureCount += 1
        self.targets = targets
        self.eventHandler = eventHandler
        onCapture?()

        if let delay {
            let workItem = DispatchWorkItem { eventHandler(.finished) }
            delayedWorkItem = workItem
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
        }

        return { [weak self] in
            self?.cancellationCount += 1
            self?.delayedWorkItem?.cancel()
        }
    }

    func emit(_ event: ScreenSnapshotEvent) {
        eventHandler?(event)
    }
}

private enum TestCaptureError: Error {
    case failed
}
