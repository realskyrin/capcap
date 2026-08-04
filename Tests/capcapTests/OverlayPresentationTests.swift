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
        let focusedSelectionViews = controller.activeSelectionViews.filter {
            $0.window?.isKeyWindow == true
        }
        XCTAssertEqual(focusedSelectionViews.count, 1)
        XCTAssertTrue(focusedSelectionViews.first?.window?.firstResponder === focusedSelectionViews.first)

        controller.activate()
        XCTAssertEqual(provider.captureCount, 1, "Repeated activation must not start a second session")
        controller.cancel()
        XCTAssertEqual(provider.cancellationCount, 1)
    }

    func testLegacyDisabledMagnifierPreferenceIsIgnored() {
        _ = NSApplication.shared
        let key = "magnifierLensPanelEnabled"
        let previousValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let controller = OverlayWindowController(
            snapshotProvider: ControlledScreenSnapshotProvider(delay: 2),
            onComplete: { _ in }
        )
        controller.activate()
        defer { controller.cancel() }

        XCTAssertTrue(controller.isMagnifierLensPanelPresented)
    }

    func testRShortcutIsHandledWhileSnapshotPreparationIsPending() throws {
        _ = NSApplication.shared
        let previousAspectRatio = Defaults.hasSelectionAspectRatio
            ? Defaults.selectionAspectRatio
            : nil
        Defaults.clearSelectionAspectRatio()

        let provider = ControlledScreenSnapshotProvider(delay: 2)
        let controller = OverlayWindowController(
            snapshotProvider: provider,
            windowSnapshotLoader: { _ in
                Thread.sleep(forTimeInterval: 2)
                return .success([])
            },
            onComplete: { _ in }
        )
        defer {
            controller.cancel()
            if let previousAspectRatio {
                Defaults.selectionAspectRatio = previousAspectRatio
            } else {
                Defaults.clearSelectionAspectRatio()
            }
        }

        controller.activate()
        let selectionView = try XCTUnwrap(
            controller.activeSelectionViews.first(where: { $0.window?.isKeyWindow == true })
        )
        XCTAssertTrue(selectionView.window?.firstResponder === selectionView)
        let windowNumber = try XCTUnwrap(selectionView.window?.windowNumber)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15
            )
        )

        NSApp.sendEvent(event)
        drainMainRunLoop()

        XCTAssertEqual(
            try XCTUnwrap(selectionView.aspectRatio),
            try XCTUnwrap(Defaults.selectionAspectRatioPresets.first),
            accuracy: 0.000_001
        )
    }

    func testCaptureStartsWithCrosshairAndPointerEventsKeepIt() throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let controller = OverlayWindowController(
            snapshotProvider: ControlledScreenSnapshotProvider(delay: 2),
            windowSnapshotLoader: { _ in .success([]) },
            onComplete: { _ in }
        )
        defer {
            controller.cancel()
            originalCursor.set()
        }

        controller.activate()
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
        let selectionView = try XCTUnwrap(
            controller.activeSelectionViews.first(where: { $0.window?.isKeyWindow == true })
        )
        let windowNumber = try XCTUnwrap(selectionView.window?.windowNumber)
        let mouseMoved = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 100, y: 100),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 100, y: 100),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let mouseDragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: NSPoint(x: 160, y: 140),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )

        NSCursor.crosshair.set()
        selectionView.mouseMoved(with: mouseMoved)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)

        NSCursor.openHand.set()
        selectionView.mouseDown(with: mouseDown)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)

        NSCursor.closedHand.set()
        selectionView.mouseDragged(with: mouseDragged)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
    }

    func testSelectedHandlesUseDirectionalResizeCursorsForHoverAndDrag() throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let selectionView = SelectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        defer { originalCursor.set() }

        let selectionRect = NSRect(x: 100, y: 80, width: 240, height: 180)
        selectionView.updateSelectionRect(selectionRect)
        selectionView.selectionLocked = true
        let positions = SelectionView.handlePositions(for: selectionRect)
        let handles = SelectionView.HandlePosition.allCases
        // These events are delivered directly to the view, so presenting a
        // real window only adds WindowServer cursor-rect work. Keeping the
        // test off-screen makes the AppKit unit test deterministic in CI.
        let windowNumber = 0

        for (index, handle) in handles.enumerated() {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: positions[index],
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: windowNumber,
                    context: nil,
                    eventNumber: index,
                    clickCount: 0,
                    pressure: 0
                )
            )
            NSCursor.crosshair.set()
            selectionView.mouseMoved(with: event)
            XCTAssertEqual(
                NSCursor.current,
                SelectionView.cursorForHandle(handle),
                "Handle \(handle) should use its directional resize cursor"
            )
        }

        let draggedHandle = SelectionView.HandlePosition.topRight
        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: positions[1],
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 20,
                clickCount: 1,
                pressure: 1
            )
        )
        let draggedPoint = NSPoint(x: positions[1].x + 30, y: positions[1].y + 20)
        let mouseDragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: draggedPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 21,
                clickCount: 1,
                pressure: 1
            )
        )

        selectionView.mouseDown(with: mouseDown)
        XCTAssertEqual(NSCursor.current, SelectionView.cursorForHandle(draggedHandle))
        NSCursor.crosshair.set()
        selectionView.mouseDragged(with: mouseDragged)
        XCTAssertEqual(
            NSCursor.current,
            SelectionView.cursorForHandle(draggedHandle),
            "Dragging an existing handle must not restore the initial crosshair"
        )
    }

    func testAnnotationCanvasPreservesOuterSelectionResizeCursors() throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let selectionView = SelectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        defer { originalCursor.set() }

        let selectionRect = NSRect(x: 100, y: 80, width: 240, height: 180)
        selectionView.updateSelectionRect(selectionRect)
        selectionView.selectionLocked = true

        let canvas = EditCanvasView(frame: selectionRect)
        canvas.hostSelectionView = selectionView
        selectionView.addSubview(canvas)
        canvas.activeTool = .rectangle

        func canvasEvent(
            type: NSEvent.EventType,
            point: NSPoint,
            eventNumber: Int
        ) throws -> NSEvent {
            let locationInWindow = canvas.convert(point, to: selectionView)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: locationInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: eventNumber,
                clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .mouseMoved ? 0 : 1
            ))
        }

        // Commit a real mark first so this follows the exact event-routing
        // transition from the regression video.
        let markStart = NSPoint(x: 70, y: 55)
        let markEnd = NSPoint(x: 165, y: 125)
        canvas.mouseDown(with: try canvasEvent(type: .leftMouseDown, point: markStart, eventNumber: 1))
        canvas.mouseDragged(with: try canvasEvent(type: .leftMouseDragged, point: markEnd, eventNumber: 2))
        canvas.mouseUp(with: try canvasEvent(type: .leftMouseUp, point: markEnd, eventNumber: 3))
        XCTAssertTrue(canvas.canUndo, "The test must reach the post-annotation state")

        let inwardOffsets: [SelectionView.HandlePosition: NSPoint] = [
            .topLeft: NSPoint(x: 2, y: -2),
            .topRight: NSPoint(x: -2, y: -2),
            .bottomLeft: NSPoint(x: 2, y: 2),
            .bottomRight: NSPoint(x: -2, y: 2),
            .topCenter: NSPoint(x: 0, y: -2),
            .bottomCenter: NSPoint(x: 0, y: 2),
            .leftCenter: NSPoint(x: 2, y: 0),
            .rightCenter: NSPoint(x: -2, y: 0),
        ]
        let positions = SelectionView.handlePositions(for: selectionRect)

        for (index, handle) in SelectionView.HandlePosition.allCases.enumerated() {
            let offset = try XCTUnwrap(inwardOffsets[handle])
            let hostPoint = NSPoint(
                x: positions[index].x + offset.x,
                y: positions[index].y + offset.y
            )
            let canvasPoint = canvas.convert(hostPoint, from: selectionView)
            NSCursor.arrow.set()
            canvas.mouseMoved(with: try canvasEvent(
                type: .mouseMoved,
                point: canvasPoint,
                eventNumber: 10 + index
            ))
            XCTAssertEqual(
                NSCursor.current,
                SelectionView.cursorForHandle(handle),
                "Canvas tracking must preserve the outer cursor for \(handle)"
            )
        }

        // Crossing out of the canvas at a frame handle also emits
        // mouseExited; that event must not flash the arrow cursor.
        let topCenter = positions[4]
        let outsideCanvasPoint = canvas.convert(
            NSPoint(x: topCenter.x, y: topCenter.y + 2),
            from: selectionView
        )
        NSCursor.arrow.set()
        canvas.mouseExited(with: try canvasEvent(
            type: .mouseMoved,
            point: outsideCanvasPoint,
            eventNumber: 30
        ))
        XCTAssertEqual(
            NSCursor.current,
            SelectionView.cursorForHandle(.topCenter),
            "Leaving the canvas through a frame handle must preserve its resize cursor"
        )
    }

    func testExistingSelectionAdjustmentDoesNotRestoreMagnifier() throws {
        _ = NSApplication.shared
        let controller = OverlayWindowController(
            snapshotProvider: ControlledScreenSnapshotProvider(delay: 2),
            windowSnapshotLoader: { _ in .success([]) },
            onComplete: { _ in }
        )
        controller.activate()
        defer { controller.cancel() }

        XCTAssertTrue(controller.isMagnifierLensPanelPresented)
        let selectionView = try XCTUnwrap(
            controller.activeSelectionViews.first(where: { $0.window?.isKeyWindow == true })
        )
        controller.selectionDidComplete(
            rect: NSRect(x: 100, y: 100, width: 200, height: 150),
            inView: selectionView,
            isWindowSelection: false,
            windowID: nil
        )
        XCTAssertFalse(controller.isMagnifierLensPanelPresented)

        controller.selectionDidStart(reason: .existingSelectionAdjustment)
        XCTAssertFalse(
            controller.isMagnifierLensPanelPresented,
            "Adjusting a completed selection must not restore the startup magnifier"
        )
    }

    func testCaptureReassertsCrosshairAfterTriggerModifierReleaseWithoutMouseMovement() {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let controller = OverlayWindowController(
            snapshotProvider: ControlledScreenSnapshotProvider(delay: 2),
            windowSnapshotLoader: { _ in .success([]) },
            onComplete: { _ in }
        )
        defer {
            controller.cancel()
            originalCursor.set()
        }

        controller.activate()
        // The overlay activates capcap, then registers and invalidates a
        // full-view crosshair cursor rect, so the crosshair should be visible
        // without any mouse movement.
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
    }

    func testCursorChipIsExcludedFromScreenSnapshots() {
        _ = NSApplication.shared
        let chip = CursorChipWindow()

        XCTAssertEqual(chip.sharingType, .none)
        chip.close()
    }

    func testEventTrackingCaptureWaitsForSnapshotBeforeDismissingPopup() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider()
        var eventTrackingIsActive = true
        var dismissalCount = 0
        let controller = OverlayWindowController(
            snapshotProvider: provider,
            windowSnapshotLoader: { _ in .success([]) },
            eventTrackingStateProvider: { eventTrackingIsActive },
            eventTrackingDismissal: {
                dismissalCount += 1
                eventTrackingIsActive = false
            },
            onComplete: { _ in }
        )

        controller.activate()

        XCTAssertFalse(controller.isOverlayPresented)
        XCTAssertEqual(dismissalCount, 0)

        let displayID = try XCTUnwrap(provider.targets.first?.displayID)
        provider.emit(.image(displayID: displayID, image: makeImage()))
        drainMainRunLoop()

        XCTAssertEqual(dismissalCount, 1)
        XCTAssertTrue(controller.isOverlayPresented)
        XCTAssertEqual(controller.appliedSnapshotCount, 1)
        controller.cancel()
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

    func testEscapeDoesNotCancelCaptureWhileColorSamplerIsActive() throws {
        _ = NSApplication.shared
        let provider = ControlledScreenSnapshotProvider(delay: 2)
        var completionCount = 0
        let controller = OverlayWindowController(
            snapshotProvider: provider,
            colorSamplerActiveProvider: { true }
        ) { _ in
            completionCount += 1
        }
        defer { controller.cancel() }
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

        XCTAssertFalse(controller.isCaptureSessionEnded)
        XCTAssertEqual(provider.cancellationCount, 0)
        XCTAssertEqual(completionCount, 0)
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

    func testOverlaySurfaceCannotBeMovedOrResizedByScreenEdgeDrag() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.prepareSurface(for: screen)

        XCTAssertFalse(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.minSize, screen.frame.size)
        XCTAssertEqual(panel.maxSize, screen.frame.size)
        XCTAssertEqual(panel.contentMinSize, screen.frame.size)
        XCTAssertEqual(panel.contentMaxSize, screen.frame.size)
        XCTAssertTrue(panel.delegate === panel)
        XCTAssertEqual(
            panel.windowWillResize(panel, to: NSSize(width: 320, height: 240)),
            screen.frame.size
        )
        panel.close()
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
