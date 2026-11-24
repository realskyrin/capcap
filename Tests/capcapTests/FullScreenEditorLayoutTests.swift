import AppKit
import XCTest
@testable import capcap

final class FullScreenEditorLayoutTests: XCTestCase {
    @MainActor
    func testLoadingLongImageDiscardsPreviousCanvasCoordinateScale() throws {
        _ = NSApplication.shared
        let image = try makeLongImage()
        for scale: CGFloat in [0.5, 2] {
            let canvas = EditCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            canvas.setPresentationScale(scale)

            canvas.loadPreviewImage(image)

            XCTAssertEqual(canvas.bounds.size, image.size,
                           "新长图不能继承上一视口的坐标比例，原缩放为 \(scale)")
        }
    }

    @MainActor
    func testCroppingKeepsHandlesVisibleAndRestoresEditorAcrossDisplays() throws {
        _ = NSApplication.shared
        let originalCursor = NSCursor.current
        let previousBeautify = Defaults.lastBeautifyEnabled
        let previousToolbarLayout = UserDefaults.standard.object(forKey: "editor.toolbarLayout")
        Defaults.lastBeautifyEnabled = false
        Defaults.toolbarLayout = .default
        defer {
            Defaults.lastBeautifyEnabled = previousBeautify
            UserDefaults.standard.set(previousToolbarLayout, forKey: "editor.toolbarLayout")
            originalCursor.set()
        }
        XCTAssertFalse(NSScreen.screens.isEmpty)
        for screen in NSScreen.screens {
            let window = NSPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // 集成测试走真实视图层级，但不覆盖用户当前正在操作的屏幕
            window.alphaValue = 0
            let host = SelectionView(frame: screen.frame)
            window.contentView = host
            let redBackground = try XCTUnwrap(CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            redBackground.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            redBackground.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            host.setBackgroundSnapshot(cgImage: try XCTUnwrap(redBackground.makeImage()), pointSize: host.bounds.size)
            let selection = NSRect(x: 80, y: 120, width: 400, height: 200)
            host.updateSelectionRect(selection)
            let controller = EditWindowController(
                captureRect: selection,
                screen: screen,
                selectionRect: selection,
                selectionViewRect: selection,
                hostSelectionView: host,
                onComplete: { _ in }
            )
            controller.show()
            defer {
                controller.tearDown()
                window.orderOut(nil)
                ToastWindow.dismiss()
            }
            let scroll = try XCTUnwrap(host.subviews.compactMap { $0 as? EditorScrollView }.first)
            let container = try XCTUnwrap(scroll.documentView as? BeautifyContainerView)
            let canvas = try XCTUnwrap(container.canvasView)
            let originalState = try XCTUnwrap(controller.restorableState())
            let image = try makeLongImage(size: NSSize(width: screen.frame.width * 2, height: screen.frame.width * 8))
            canvas.setPresentationScale(2)
            canvas.loadPreviewImage(image)
            controller.restoreState(EditWindowController.RestorableState(
                canvasState: canvas.restorableState(),
                beautifyState: originalState.beautifyState,
                overrideBaseImageCropRect: originalState.overrideBaseImageCropRect,
                overrideBaseImage: originalState.overrideBaseImage,
                selectionRect: originalState.selectionRect,
                selectionViewRect: originalState.selectionViewRect,
                captureRect: originalState.captureRect,
                selectionAdjustmentBounds: originalState.selectionAdjustmentBounds
            ))
            host.layoutSubtreeIfNeeded()
            let canvasInHost = canvas.convert(canvas.bounds, to: host)

            XCTAssertEqual(host.bounds.size, screen.frame.size)
            XCTAssertGreaterThan(scroll.frame.width, selection.width)
            XCTAssertEqual(canvas.bounds.width, image.size.width, accuracy: 0.0001,
                           "全屏布局必须基于长图本身的逻辑尺寸")
            XCTAssertEqual(canvas.bounds.height, image.size.height, accuracy: 0.0001)
            XCTAssertEqual(container.frame.width, scroll.contentView.bounds.width, accuracy: 1,
                           "长图必须铺满全屏工作区宽度，不能只缩在左侧")
            XCTAssertEqual(canvasInHost.width, scroll.contentView.bounds.width, accuracy: 1)
            XCTAssertGreaterThan(container.frame.height, scroll.contentView.bounds.height)
            XCTAssertEqual(scroll.contentView.bounds.maxY, container.frame.maxY, accuracy: 1,
                           "进入长图编辑时应显示顶部，不能留下大块空白")

            let scrollIndex = try XCTUnwrap(host.subviews.firstIndex { $0 === scroll })
            let background = try XCTUnwrap(host.subviews.prefix(scrollIndex).last)
            XCTAssertEqual(background.frame, host.bounds)
            XCTAssertNotNil(background.layer?.backgroundColor)
            let toolbars = host.subviews.compactMap { $0 as? ToolbarView }
            XCTAssertEqual(toolbars.count, 2)
            for toolbar in toolbars {
                let toolbarIndex = try XCTUnwrap(host.subviews.firstIndex { $0 === toolbar })
                XCTAssertGreaterThan(toolbarIndex, scrollIndex, "工具栏必须位于全屏背景和画布上方")
                XCTAssertFalse(toolbar.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(host.bounds.contains(toolbar.frame), "工具栏必须留在可视屏幕内")
                XCTAssertFalse(scroll.frame.intersects(toolbar.frame), "图片视口不能覆盖工具栏")
            }

            XCTAssertLessThan(canvas.presentationScale, 1)
            let middleOrigin = NSPoint(x: 0, y: (container.frame.height - scroll.contentView.bounds.height) * 0.4)
            scroll.contentView.scroll(to: middleOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
            let originBeforeCrop = scroll.contentView.bounds.origin
            let cropButton = try XCTUnwrap(toolbars.flatMap(\.subviews).compactMap { $0 as? ToolButton }.first {
                $0.hoverTip == L10n.tipCrop
            })
            cropButton.performClick(nil)
            let firstCropView = try XCTUnwrap(host.subviews.compactMap { $0 as? ScrollCropView }.first)
            let imageRect = canvas.convert(canvas.bounds, to: host)
            // AppKit 会把滚动视口吸附到实际屏幕像素，允许半个逻辑点以内的显示取整
            XCTAssertEqual(firstCropView.imageRect.minX, imageRect.minX, accuracy: 0.5)
            XCTAssertEqual(firstCropView.imageRect.minY, imageRect.minY, accuracy: 0.5)
            XCTAssertEqual(firstCropView.imageRect.width, imageRect.width, accuracy: 0.5)
            XCTAssertEqual(firstCropView.imageRect.height, imageRect.height, accuracy: 0.5)
            let overlayIndex = try XCTUnwrap(host.subviews.firstIndex { $0 === firstCropView })
            XCTAssertGreaterThan(overlayIndex, scrollIndex)
            for toolbar in toolbars {
                XCTAssertLessThan(overlayIndex, try XCTUnwrap(host.subviews.firstIndex { $0 === toolbar }))
            }
            let positions = SelectionView.handlePositions(for: firstCropView.imageRect)
            for (handle, position) in zip(firstCropView.handleRects, positions) {
                XCTAssertEqual(handle.midX, position.x, accuracy: 0.001)
                XCTAssertEqual(handle.midY, position.y, accuracy: 0.001)
            }
            for handle in firstCropView.handleRects {
                XCTAssertTrue(firstCropView.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(handle),
                              "完整控制点应留在当前屏幕裁剪视口内")
            }
            XCTAssertTrue(canvas.trackingAreas.isEmpty, "裁剪浮层应独占悬停追踪，底层画布不能抢回光标")
            for (index, handle) in SelectionView.HandlePosition.allCases.enumerated() {
                let rect = firstCropView.handleRects[index]
                let location = firstCropView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                let moved = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 0, pressure: 0
                ))
                let entered = try XCTUnwrap(NSEvent.enterExitEvent(
                    with: .mouseEntered, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil
                ))
                let exited = try XCTUnwrap(NSEvent.enterExitEvent(
                    with: .mouseExited, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil
                ))
                let cursorUpdate = try XCTUnwrap(NSEvent.enterExitEvent(
                    with: .cursorUpdate, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil
                ))
                for updatesCursorRect in [false, true] {
                    NSCursor.arrow.set()
                    if updatesCursorRect {
                        firstCropView.cursorUpdate(with: cursorUpdate)
                    } else {
                        firstCropView.mouseMoved(with: moved)
                    }
                    // 即使停用前已排队的画布事件迟到，也不能覆盖裁剪控制点的方向光标
                    canvas.mouseEntered(with: entered)
                    canvas.mouseMoved(with: moved)
                    canvas.mouseExited(with: exited)
                    XCTAssertEqual(NSCursor.current, SelectionView.cursorForHandle(handle),
                                   "\(handle) 的光标不能被底层画布的迟到悬停事件覆盖")
                }
            }
            XCTAssertTrue(controller.cancelCrop())
            XCTAssertNil(firstCropView.superview)
            XCTAssertFalse(canvas.trackingAreas.isEmpty, "退出裁剪应恢复正常标注画布的悬停追踪")
            XCTAssertEqual(scroll.contentView.bounds.origin.x, originBeforeCrop.x, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, originBeforeCrop.y, accuracy: 1,
                           "取消裁剪应恢复进入前的滚动位置")

            XCTAssertTrue(canvas.insertEmoji("🎯"))
            let annotationBeforeCrop = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)
            cropButton.performClick(nil)
            let cropView = try XCTUnwrap(host.subviews.compactMap { $0 as? ScrollCropView }.first)
            for handle in cropView.handleRects {
                XCTAssertTrue(cropView.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(handle))
            }
            // 以当前适配整图后的尺寸拖动四边，不能使用只适合原比例的固定像素偏移
            let drags: [(SelectionView.HandlePosition, NSPoint)] = [
                (.bottomLeft, NSPoint(x: 0.1, y: 0.15)),
                (.topRight, NSPoint(x: -0.1, y: -0.2)),
            ]
            for (handle, fraction) in drags {
                let index = try XCTUnwrap(SelectionView.HandlePosition.allCases.firstIndex(of: handle))
                let rect = cropView.handleRects[index]
                let start = NSPoint(x: rect.midX, y: rect.midY)
                let end = NSPoint(x: start.x + cropView.imageRect.width * fraction.x,
                                  y: start.y + cropView.imageRect.height * fraction.y)
                drag(cropView, from: start, to: end, window: window)
            }
            let expectedCrop = cropView.cropRect
            XCTAssertLessThan(expectedCrop.width, image.size.width)
            XCTAssertLessThan(expectedCrop.height, image.size.height)
            let confirm = try XCTUnwrap(host.subviews.flatMap(\.subviews).compactMap { $0 as? ToolButton }.first {
                $0.hoverTip == L10n.tipScrollCropConfirm
            })
            confirm.performClick(nil)
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(cropView.superview)
            let croppedImage = try XCTUnwrap(canvas.previewImage)
            XCTAssertEqual(croppedImage.size.width, expectedCrop.width, accuracy: 0.0001)
            XCTAssertEqual(croppedImage.size.height, expectedCrop.height, accuracy: 0.0001)
            XCTAssertEqual(canvas.bounds.width, expectedCrop.width, accuracy: 0.0001)
            XCTAssertEqual(canvas.bounds.height, expectedCrop.height, accuracy: 0.0001)
            XCTAssertEqual(container.frame.width, scroll.contentView.bounds.width, accuracy: 1,
                           "确认裁剪后仍应铺满当前屏幕工作区")
            XCTAssertEqual(canvas.convert(canvas.bounds, to: host).width, scroll.contentView.bounds.width, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.maxY, container.frame.maxY, accuracy: 1,
                           "确认裁剪后不能保留失效的滚动原点")
            canvas.selectAllAnnotations()
            let annotationAfterCrop = try XCTUnwrap(canvas.selectedAnnotation as? EmojiAnnotation)
            XCTAssertEqual(annotationAfterCrop.rect.minX, annotationBeforeCrop.rect.minX - expectedCrop.minX,
                           accuracy: 0.0001)
            XCTAssertEqual(annotationAfterCrop.rect.minY, annotationBeforeCrop.rect.minY - expectedCrop.minY,
                           accuracy: 0.0001)

            // 直接缓存真实视图层级，验证旧的红色桌面被盖住，工作区实际绘制白色长图
            let white = try cachedColor(in: host, at: NSPoint(x: scroll.frame.midX, y: scroll.frame.midY))
            XCTAssertGreaterThan(white.redComponent, 0.95)
            XCTAssertGreaterThan(white.greenComponent, 0.95)
            XCTAssertGreaterThan(white.blueComponent, 0.95)
            let dark = try cachedColor(in: host, at: NSPoint(x: host.bounds.minX + 8, y: host.bounds.midY))
            XCTAssertLessThan(dark.redComponent, 0.2)
            XCTAssertLessThan(dark.greenComponent, 0.2)
            XCTAssertLessThan(dark.blueComponent, 0.2)
            XCTAssertGreaterThan(dark.alphaComponent, 0.95)
        }
    }

    @MainActor
    private func drag(_ view: NSView, from start: NSPoint, to end: NSPoint, window: NSWindow) {
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, at: start))
        view.mouseDragged(with: event(.leftMouseDragged, at: end))
        view.mouseUp(with: event(.leftMouseUp, at: end))
    }

    @MainActor
    private func cachedColor(in view: NSView, at point: NSPoint) throws -> NSColor {
        let rect = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    }

    @MainActor
    private func makeLongImage(size: NSSize = NSSize(width: 2_400, height: 9_600)) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 240, height: 960, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 960))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: size)
    }

    func testWorkspaceReservesBottomControlsAndSideToolbarOnSelectedDisplay() {
        let bounds = NSRect(x: -1_440, y: 200, width: 1_440, height: 900)
        let workspace = EditorToolbarPlacement.fullScreenWorkspaceRect(
            in: bounds, primaryToolbarHeight: 44, sideToolbarWidth: 44
        )

        XCTAssertEqual(workspace.minX, bounds.minX + 16)
        XCTAssertEqual(workspace.minY, bounds.minY + 44 + 108)
        XCTAssertEqual(workspace.maxX, bounds.maxX - 16 - 44 - 16)
        XCTAssertEqual(workspace.maxY, bounds.maxY - 16)
        XCTAssertTrue(bounds.contains(workspace))

        let withoutSideToolbar = EditorToolbarPlacement.fullScreenWorkspaceRect(
            in: bounds, primaryToolbarHeight: 44, sideToolbarWidth: 0
        )
        XCTAssertEqual(withoutSideToolbar.maxX, bounds.maxX - 16)
    }

    func testLongImageFitsWidthAndKeepsScrollableHeight() {
        let workspace = NSRect(x: 100, y: 150, width: 900, height: 600)
        let imageSize = NSSize(width: 2_400, height: 12_000)
        let layout = EditorToolbarPlacement.fullScreenImageLayout(
            imageSize: imageSize,
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            in: workspace
        )

        XCTAssertEqual(layout.scale, 0.375, accuracy: 0.001)
        XCTAssertEqual(layout.viewport, workspace)
        XCTAssertGreaterThan(imageSize.height * layout.scale, layout.viewport.height)
    }

    func testShortImageIsNotEnlargedAndBeautifyPaddingStaysInsideWorkspace() {
        let workspace = NSRect(x: 100, y: 150, width: 900, height: 600)
        let shortImage = EditorToolbarPlacement.fullScreenImageLayout(
            imageSize: NSSize(width: 200, height: 100),
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            in: workspace
        )

        XCTAssertEqual(shortImage.scale, 1)
        XCTAssertEqual(shortImage.viewport.size, NSSize(width: 200, height: 100))
        XCTAssertEqual(shortImage.viewport.midX, workspace.midX)
        XCTAssertEqual(shortImage.viewport.midY, workspace.midY)

        let padding = NSEdgeInsets(top: 24, left: 40, bottom: 56, right: 60)
        let paddedImage = EditorToolbarPlacement.fullScreenImageLayout(
            imageSize: NSSize(width: 1_400, height: 1_800),
            padding: padding,
            in: workspace
        )

        XCTAssertEqual(paddedImage.scale, 800.0 / 1_400, accuracy: 0.001)
        XCTAssertEqual(paddedImage.viewport.width, 1_400 * paddedImage.scale + padding.left + padding.right,
                       accuracy: 0.001)
        XCTAssertEqual(paddedImage.viewport.height, workspace.height)
        XCTAssertEqual(paddedImage.viewport.midX, workspace.midX)
        XCTAssertEqual(paddedImage.viewport.midY, workspace.midY)
        XCTAssertTrue(workspace.contains(paddedImage.viewport))
    }
}
