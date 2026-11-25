import AppKit

/// 覆盖当前编辑画布的透明裁剪层，图片和标注仍由下方画布绘制
final class ScrollCropView: NSView {
    private let imageSize: NSSize
    private let pixelSize: NSSize
    var imageRect: NSRect {
        didSet {
            dragState = nil
            needsDisplay = true
            refreshCursorGeometry()
        }
    }
    private var cropFractions = NSRect(x: 0, y: 0, width: 1, height: 1)
    private var dragState: (handle: SelectionView.HandlePosition, rect: NSRect, point: NSPoint)?

    private let handleHitInset: CGFloat = 10

    init(frame frameRect: NSRect, image: NSImage, rotation: ImageRotation = .none, imageRect: NSRect? = nil) {
        self.imageRect = imageRect ?? NSRect(origin: .zero, size: frameRect.size)
        imageSize = rotation.orientedSize(image.size)
        if let cgImage = image.cgImagePreservingBacking() {
            pixelSize = rotation.orientedSize(NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            pixelSize = NSSize(width: max(1, imageSize.width.rounded()), height: max(1, imageSize.height.rounded()))
        }
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let imageFillsBounds = imageRect == bounds
        super.setFrameSize(newSize)
        if imageFillsBounds { imageRect = bounds }
        dragState = nil
        needsDisplay = true
        refreshCursorGeometry()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (index, rect) in handleRects.enumerated() {
            // 系统光标区只覆盖圆点本体，扩大命中区由最近圆点规则处理，避免小图区域重叠
            let hitRect = rect.intersection(visibleRect)
            guard !hitRect.isNull else { continue }
            addCursorRect(hitRect, cursor: SelectionView.cursorForHandle(SelectionView.HandlePosition.allCases[index]))
        }
    }

    private func refreshCursorGeometry() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard window.isKeyWindow, visibleRect.contains(point) else { return }
        updateCursor(at: point)
    }

    /// 比例不依赖显示缩放；四条边先对齐旋转后的实际像素，再返回逻辑坐标
    var cropRect: NSRect {
        let width = max(1, pixelSize.width)
        let height = max(1, pixelSize.height)
        let left = min(width - 1, max(0, (cropFractions.minX * width).rounded()))
        let right = min(width, max(left + 1, (cropFractions.maxX * width).rounded()))
        let bottom = min(height - 1, max(0, (cropFractions.minY * height).rounded()))
        let top = min(height, max(bottom + 1, (cropFractions.maxY * height).rounded()))
        return NSRect(
            x: left / width * imageSize.width,
            y: bottom / height * imageSize.height,
            width: (right - left) / width * imageSize.width,
            height: (top - bottom) / height * imageSize.height
        )
    }

    private var selectionRect: NSRect {
        NSRect(
            x: imageRect.minX + cropFractions.minX * imageRect.width,
            y: imageRect.minY + cropFractions.minY * imageRect.height,
            width: cropFractions.width * imageRect.width,
            height: cropFractions.height * imageRect.height
        )
    }

    /// 控制点中心落在真实裁剪边界，外侧圆点由独立浮层承载，顺序沿用选区的八点枚举
    var handleRects: [NSRect] {
        let rect = selectionRect
        let size = max(0, min(SelectionView.selectionHandleSize, rect.width / 3, rect.height / 3))
        let centers = SelectionView.handlePositions(for: rect)
        return centers.map {
            NSRect(x: $0.x - size / 2, y: $0.y - size / 2, width: size, height: size)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard imageRect.width > 0, imageRect.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = selectionRect
        let mask = NSBezierPath(rect: imageRect)
        mask.append(NSBezierPath(rect: rect))
        mask.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.62).setFill()
        mask.fill()

        SelectionView.drawSelectionBorder(context: context, rect: rect, dashed: false)
        SelectionView.drawSelectionHandles(context: context, rects: handleRects)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: point) else { return }
        dragState = (handle, selectionRect, point)
        SelectionView.setCursorForHandle(handle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragState, imageRect.width > 0, imageRect.height > 0 else { return }
        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: point.x - dragState.point.x, y: point.y - dragState.point.y)
        let original = dragState.rect
        // 从原框加鼠标位移，命中圆点边缘时首次拖动也不会跳边
        let minimumWidth = min(original.width, imageRect.width, max(12, imageRect.width / max(1, pixelSize.width)))
        let minimumHeight = min(original.height, imageRect.height, max(12, imageRect.height / max(1, pixelSize.height)))
        var left = original.minX, right = original.maxX
        var bottom = original.minY, top = original.maxY
        switch dragState.handle {
        case .topLeft, .bottomLeft, .leftCenter:
            left = max(imageRect.minX, min(original.maxX - minimumWidth, original.minX + delta.x))
        case .topRight, .bottomRight, .rightCenter:
            right = min(imageRect.maxX, max(original.minX + minimumWidth, original.maxX + delta.x))
        default:
            break
        }
        switch dragState.handle {
        case .bottomLeft, .bottomRight, .bottomCenter:
            bottom = max(imageRect.minY, min(original.maxY - minimumHeight, original.minY + delta.y))
        case .topLeft, .topRight, .topCenter:
            top = min(imageRect.maxY, max(original.minY + minimumHeight, original.maxY + delta.y))
        default:
            break
        }
        cropFractions = NSRect(
            x: (left - imageRect.minX) / imageRect.width,
            y: (bottom - imageRect.minY) / imageRect.height,
            width: (right - left) / imageRect.width,
            height: (top - bottom) / imageRect.height
        )
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateCursor(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        dragState = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func handle(at point: NSPoint) -> SelectionView.HandlePosition? {
        var closest: Int?
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for (index, rect) in handleRects.enumerated() where rect.insetBy(dx: -handleHitInset, dy: -handleHitInset).contains(point) {
            let dx = point.x - rect.midX, dy = point.y - rect.midY
            let distance = dx * dx + dy * dy
            if distance < closestDistance {
                closest = index
                closestDistance = distance
            }
        }
        return closest.map { SelectionView.HandlePosition.allCases[$0] }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        // macOS 会在移动事件后重新应用光标，必须在此阶段保留圆点的缩放方向
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: NSPoint) {
        if let handle = dragState?.handle ?? handle(at: point) {
            SelectionView.setCursorForHandle(handle)
        } else {
            NSCursor.arrow.set()
        }
    }
}
