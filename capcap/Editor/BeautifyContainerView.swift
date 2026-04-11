import AppKit
import CoreGraphics

/// Wraps `EditCanvasView` as a subview. When a beautify preset is set, the
/// container grows to `innerSize + 2·padding`, repositions the canvas at
/// `(padding, padding)`, and draws the gradient background + inner shadow +
/// base screenshot behind the canvas. The canvas itself is never resized,
/// so `EditCanvasView`'s tool/hit-test/draw logic stays identical to the
/// pre-beautify behavior and mouse events route correctly in both states.
final class BeautifyContainerView: NSView {
    private(set) weak var canvasView: EditCanvasView?
    private(set) var beautifyPreset: BeautifyPreset?

    /// Cached wallpaper image for the wallpaper preset.
    var wallpaperImage: NSImage?

    /// User-driven padding override. When `nil`, `relayout()` falls back to
    /// `BeautifyRenderer.padding(for:)`. When set, the live preview uses this
    /// value and the controller is responsible for forwarding the same value
    /// to `BeautifyRenderer.render(innerImage:preset:padding:)` at save time.
    private(set) var customPadding: CGFloat?

    var isBeautifyEnabled: Bool { beautifyPreset != nil }

    var innerImageSize: CGSize {
        canvasView?.frame.size ?? .zero
    }

    var outerSize: CGSize { frame.size }

    init(canvasView: EditCanvasView) {
        self.canvasView = canvasView
        super.init(frame: NSRect(origin: .zero, size: canvasView.frame.size))
        addSubview(canvasView)
        canvasView.setFrameOrigin(.zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Let mouse events route normally to the canvas subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }

    override var isFlipped: Bool { false }

    // MARK: - Beautify API

    func setBeautify(preset: BeautifyPreset?) {
        beautifyPreset = preset
        relayout()
        needsDisplay = true
    }

    func setPadding(_ padding: CGFloat?) {
        customPadding = padding
        relayout()
        needsDisplay = true
    }

    /// Called by the controller when the canvas's intrinsic size changes
    /// (selection resize or long-screenshot preview load).
    func canvasSizeDidChange() {
        relayout()
        needsDisplay = true
    }

    private func relayout() {
        guard let canvasView else { return }
        let inner = canvasView.frame.size
        if beautifyPreset != nil, inner.width > 0, inner.height > 0 {
            let p = customPadding ?? BeautifyRenderer.padding(for: inner)
            let newSize = CGSize(
                width: inner.width + 2 * p,
                height: inner.height + 2 * p
            )
            setFrameSize(newSize)
            canvasView.setFrameOrigin(CGPoint(x: p, y: p))
        } else {
            setFrameSize(inner)
            canvasView.setFrameOrigin(.zero)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard
            let preset = beautifyPreset,
            let canvasView,
            let context = NSGraphicsContext.current?.cgContext
        else { return }

        let inner = canvasView.frame.size
        guard inner.width > 0, inner.height > 0 else { return }

        let outerRect = CGRect(origin: .zero, size: bounds.size)
        let innerRect = canvasView.frame

        // 1. Background
        if preset.isWallpaper, let wp = wallpaperImage {
            BeautifyRenderer.drawWallpaperBackground(in: outerRect, wallpaper: wp)
        } else {
            BeautifyRenderer.drawBackground(in: outerRect, preset: preset)
        }

        // 2. Soft shadow silhouette under the canvas's rounded rect
        BeautifyRenderer.drawInnerShadow(
            innerRect: innerRect,
            cornerRadius: BeautifyRenderer.innerCornerRadius,
            context: context
        )
    }
}
