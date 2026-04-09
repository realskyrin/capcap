# Screenshot Beautify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-click screenshot beautify feature to capcap's editor — wraps the captured image in a gradient background with rounded corners and soft shadow, picked from 8 presets.

**Architecture:** A pure `BeautifyRenderer` handles the geometry (padding, gradient, shadow, corner clipping). `EditCanvasView` gains a `beautifyPreset` state; when non-nil, its `draw()` renders the gradient frame live and its `compositeImage()` wraps the final output through `BeautifyRenderer.render`. A new `BeautifySubToolbar` lets the user pick among 8 preset gradients, wired into `EditWindowController` via a new toolbar button.

**Tech Stack:** Swift, AppKit (no SwiftUI), `NSGradient`, `CGContext`, `NSBitmapImageRep`.

**Spec reference:** `docs/superpowers/specs/2026-04-09-screenshot-beautify-design.md`

**Verification model:** capcap has no unit tests; after each task run `bash scripts/compile-check.sh` to confirm the tree compiles. Final task runs `bash scripts/rebuild-and-open.sh` and walks through the manual test checklist.

---

## Task 1: BeautifyPreset data model + Defaults persistence + L10n

**Files:**
- Create: `capcap/Editor/BeautifyPreset.swift`
- Modify: `capcap/Utilities/Defaults.swift`

- [ ] **Step 1: Create `BeautifyPreset.swift`**

Write the full file at `capcap/Editor/BeautifyPreset.swift`:

```swift
import AppKit

struct BeautifyPreset: Equatable {
    let id: String
    let displayName: String
    let startColor: NSColor
    let endColor: NSColor
    let angleDegrees: CGFloat

    static func == (lhs: BeautifyPreset, rhs: BeautifyPreset) -> Bool {
        lhs.id == rhs.id
    }

    static let defaults: [BeautifyPreset] = [
        BeautifyPreset(
            id: "peach-blue",
            displayName: L10n.beautifyPresetPeachBlue,
            startColor: NSColor(red: 0xFD/255.0, green: 0xE8/255.0, blue: 0xEF/255.0, alpha: 1),
            endColor:   NSColor(red: 0xC7/255.0, green: 0xD7/255.0, blue: 0xF2/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "mint-teal",
            displayName: L10n.beautifyPresetMintTeal,
            startColor: NSColor(red: 0xD4/255.0, green: 0xF1/255.0, blue: 0xE5/255.0, alpha: 1),
            endColor:   NSColor(red: 0xA7/255.0, green: 0xD8/255.0, blue: 0xC6/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "peach-pink",
            displayName: L10n.beautifyPresetPeachPink,
            startColor: NSColor(red: 0xFD/255.0, green: 0xE1/255.0, blue: 0xD3/255.0, alpha: 1),
            endColor:   NSColor(red: 0xF9/255.0, green: 0xA8/255.0, blue: 0xA8/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "blue-purple",
            displayName: L10n.beautifyPresetBluePurple,
            startColor: NSColor(red: 0xC9/255.0, green: 0xD6/255.0, blue: 0xFF/255.0, alpha: 1),
            endColor:   NSColor(red: 0xE2/255.0, green: 0xB0/255.0, blue: 0xFF/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "warm-orange",
            displayName: L10n.beautifyPresetWarmOrange,
            startColor: NSColor(red: 0xFE/255.0, green: 0xF3/255.0, blue: 0xC7/255.0, alpha: 1),
            endColor:   NSColor(red: 0xFB/255.0, green: 0xBF/255.0, blue: 0x85/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "teal-pink",
            displayName: L10n.beautifyPresetTealPink,
            startColor: NSColor(red: 0xA8/255.0, green: 0xED/255.0, blue: 0xEA/255.0, alpha: 1),
            endColor:   NSColor(red: 0xFE/255.0, green: 0xD6/255.0, blue: 0xE3/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "deep-purple",
            displayName: L10n.beautifyPresetDeepPurple,
            startColor: NSColor(red: 0x66/255.0, green: 0x7E/255.0, blue: 0xEA/255.0, alpha: 1),
            endColor:   NSColor(red: 0x76/255.0, green: 0x4B/255.0, blue: 0xA2/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "neutral-gray",
            displayName: L10n.beautifyPresetNeutralGray,
            startColor: NSColor(red: 0xE9/255.0, green: 0xEC/255.0, blue: 0xEF/255.0, alpha: 1),
            endColor:   NSColor(red: 0xCE/255.0, green: 0xD4/255.0, blue: 0xDA/255.0, alpha: 1),
            angleDegrees: 135
        ),
    ]

    static func preset(forID id: String?) -> BeautifyPreset? {
        guard let id else { return nil }
        return defaults.first(where: { $0.id == id })
    }

    static var defaultPreset: BeautifyPreset {
        preset(forID: Defaults.lastBeautifyPresetID) ?? defaults[0]
    }
}
```

- [ ] **Step 2: Add persistence key and L10n strings in `Defaults.swift`**

Open `capcap/Utilities/Defaults.swift`. In the `L10n` enum, locate the `// Toast` section (around line 42) and add these entries immediately after `mergedLongScreenshot`:

```swift
    // Beautify
    static var beautify: String { lang == .zh ? "美化" : "Beautify" }
    static var beautifyPresetPeachBlue: String { lang == .zh ? "粉蓝" : "Peach Blue" }
    static var beautifyPresetMintTeal: String { lang == .zh ? "薄荷青" : "Mint Teal" }
    static var beautifyPresetPeachPink: String { lang == .zh ? "桃粉" : "Peach Pink" }
    static var beautifyPresetBluePurple: String { lang == .zh ? "蓝紫梦" : "Blue Purple" }
    static var beautifyPresetWarmOrange: String { lang == .zh ? "暖橘黄" : "Warm Orange" }
    static var beautifyPresetTealPink: String { lang == .zh ? "青粉" : "Teal Pink" }
    static var beautifyPresetDeepPurple: String { lang == .zh ? "深邃紫" : "Deep Purple" }
    static var beautifyPresetNeutralGray: String { lang == .zh ? "中性灰" : "Neutral Gray" }
```

Then inside the `struct Defaults` block, after the `mosaicBlockSize` property (around line 92), add:

```swift
    static var lastBeautifyPresetID: String? {
        get { defaults.string(forKey: "lastBeautifyPresetID") }
        set { defaults.set(newValue, forKey: "lastBeautifyPresetID") }
    }
```

- [ ] **Step 3: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`

- [ ] **Step 4: Commit**

```bash
git add capcap/Editor/BeautifyPreset.swift capcap/Utilities/Defaults.swift
git commit -m "$(cat <<'EOF'
feat(beautify): add BeautifyPreset model and persistence

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: BeautifyRenderer (geometry + rendering)

**Files:**
- Create: `capcap/Editor/BeautifyRenderer.swift`

- [ ] **Step 1: Create `BeautifyRenderer.swift`**

Write the full file at `capcap/Editor/BeautifyRenderer.swift`:

```swift
import AppKit
import CoreGraphics

enum BeautifyRenderer {
    // MARK: - Layout constants

    static let paddingRatio: CGFloat = 0.08
    static let paddingMin: CGFloat = 32
    static let paddingMax: CGFloat = 96
    static let innerCornerRadius: CGFloat = 12
    static let shadowBlur: CGFloat = 18
    static let shadowOpacity: CGFloat = 0.18
    static let shadowOffset: CGSize = CGSize(width: 0, height: -6)

    // MARK: - Geometry

    static func padding(for innerSize: CGSize) -> CGFloat {
        let shortEdge = min(innerSize.width, innerSize.height)
        guard shortEdge > 0 else { return paddingMin }
        let base = shortEdge * paddingRatio
        return max(paddingMin, min(paddingMax, base))
    }

    static func outputSize(for innerSize: CGSize) -> CGSize {
        let p = padding(for: innerSize)
        return CGSize(width: innerSize.width + 2 * p, height: innerSize.height + 2 * p)
    }

    static func innerRect(for innerSize: CGSize) -> CGRect {
        let p = padding(for: innerSize)
        return CGRect(x: p, y: p, width: innerSize.width, height: innerSize.height)
    }

    // MARK: - Drawing primitives

    /// Draws a linear gradient across `outerRect` using the preset colors and angle.
    /// Caller must ensure `NSGraphicsContext.current` is set.
    static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset) {
        guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
            preset.startColor.setFill()
            outerRect.fill()
            return
        }
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    }

    /// Draws a shadow cast by a rounded-rect silhouette at `innerRect`. The fill
    /// under the shadow is opaque black, so callers should draw the actual image
    /// content on top afterwards.
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, context: CGContext) {
        context.saveGState()
        let shadowColor = NSColor.black.withAlphaComponent(shadowOpacity).cgColor
        context.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
        let path = CGPath(
            roundedRect: innerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: - Full composite

    /// Returns a new NSImage containing `innerImage` wrapped in the beautified frame.
    static func render(innerImage: NSImage, preset: BeautifyPreset) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        let outer = outputSize(for: innerSize)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(for: innerSize)

        // Preserve backing scale by mirroring the inner image's pixel density.
        let innerPixelScale: CGFloat
        if let rep = innerImage.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.size.width > 0 {
            innerPixelScale = CGFloat(rep.pixelsWide) / rep.size.width
        } else {
            innerPixelScale = 1
        }
        let pixelsWide = Int((outer.width * innerPixelScale).rounded())
        let pixelsHigh = Int((outer.height * innerPixelScale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            return innerImage
        }
        rep.size = outer

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return innerImage }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let cg = ctx.cgContext

        // 1. Gradient background across full outer area
        drawBackground(in: outerRect, preset: preset)

        // 2. Soft shadow under the inner rounded rect
        drawInnerShadow(innerRect: inner, cornerRadius: innerCornerRadius, context: cg)

        // 3. Clip to the inner rounded rect and draw the image
        cg.saveGState()
        let clipPath = CGPath(
            roundedRect: inner,
            cornerWidth: innerCornerRadius,
            cornerHeight: innerCornerRadius,
            transform: nil
        )
        cg.addPath(clipPath)
        cg.clip()
        innerImage.draw(
            in: inner,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        return image
    }
}
```

- [ ] **Step 2: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`

- [ ] **Step 3: Commit**

```bash
git add capcap/Editor/BeautifyRenderer.swift
git commit -m "$(cat <<'EOF'
feat(beautify): add BeautifyRenderer for gradient + frame composition

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: EditCanvasView — beautify state, innerImageSize, setBeautify

**Files:**
- Modify: `capcap/Editor/EditCanvasView.swift`

- [ ] **Step 1: Add state fields and setBeautify method**

Open `capcap/Editor/EditCanvasView.swift`. Find the property block near the top of the class (starting with `var captureRect: CGRect?` on line 15). Add these lines immediately after `private(set) var previewImage: NSImage?`:

```swift
    private(set) var beautifyPreset: BeautifyPreset?
    private var innerImageSize: CGSize = .zero
    var isBeautifyEnabled: Bool { beautifyPreset != nil }
```

- [ ] **Step 2: Add `setBeautify` method + inner size helpers**

Find the `// MARK: - Composite` marker (around line 288). Immediately before it, insert a new MARK section:

```swift
    // MARK: - Beautify

    func setBeautify(_ preset: BeautifyPreset?) {
        beautifyPreset = preset
        if preset != nil {
            let padding = BeautifyRenderer.padding(for: innerImageSize)
            frame = NSRect(
                origin: frame.origin,
                size: CGSize(
                    width: innerImageSize.width + 2 * padding,
                    height: innerImageSize.height + 2 * padding
                )
            )
        } else {
            frame = NSRect(origin: frame.origin, size: innerImageSize)
        }
        needsDisplay = true
    }

    var currentPadding: CGFloat {
        BeautifyRenderer.padding(for: innerImageSize)
    }

    var outerSizeWithBeautify: CGSize {
        guard isBeautifyEnabled else { return innerImageSize }
        let p = currentPadding
        return CGSize(
            width: innerImageSize.width + 2 * p,
            height: innerImageSize.height + 2 * p
        )
    }
```

- [ ] **Step 3: Track `innerImageSize` in `loadPreviewImage` and `updateViewportSize`**

Find `loadPreviewImage` (around line 319) and `updateViewportSize` (around line 327). Replace them with:

```swift
    func loadPreviewImage(_ image: NSImage) {
        cancelInFlightInteraction()
        previewImage = image
        mosaicBaseImage = nil
        innerImageSize = image.size
        if beautifyPreset != nil {
            let padding = BeautifyRenderer.padding(for: innerImageSize)
            frame = NSRect(
                origin: .zero,
                size: CGSize(
                    width: innerImageSize.width + 2 * padding,
                    height: innerImageSize.height + 2 * padding
                )
            )
        } else {
            frame = NSRect(origin: .zero, size: image.size)
        }
        needsDisplay = true
    }

    func updateViewportSize(_ size: NSSize) {
        guard !hasPreviewImage else { return }
        innerImageSize = size
        if beautifyPreset != nil {
            let padding = BeautifyRenderer.padding(for: innerImageSize)
            frame = NSRect(
                origin: .zero,
                size: CGSize(
                    width: size.width + 2 * padding,
                    height: size.height + 2 * padding
                )
            )
        } else {
            frame = NSRect(origin: .zero, size: size)
        }
        needsDisplay = true
    }
```

- [ ] **Step 4: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`. If the compiler complains about the `_ = preset` lines, they're defensive leftovers — remove them.

- [ ] **Step 5: Commit**

```bash
git add capcap/Editor/EditCanvasView.swift
git commit -m "$(cat <<'EOF'
feat(beautify): track beautify state and inner size in EditCanvasView

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: EditCanvasView — draw() beautify branch

**Files:**
- Modify: `capcap/Editor/EditCanvasView.swift`

- [ ] **Step 1: Extract current draw body into `drawInnerContent`**

Open `capcap/Editor/EditCanvasView.swift`. Find the existing `override func draw(_ dirtyRect: NSRect)` method (around line 204). Replace it with the following, which splits the body and adds a beautify branch:

```swift
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let preset = beautifyPreset, innerImageSize.width > 0, innerImageSize.height > 0 {
            let padding = BeautifyRenderer.padding(for: innerImageSize)
            let outerRect = CGRect(origin: .zero, size: bounds.size)
            let innerRect = CGRect(
                x: padding,
                y: padding,
                width: innerImageSize.width,
                height: innerImageSize.height
            )

            // 1. Gradient background
            BeautifyRenderer.drawBackground(in: outerRect, preset: preset)

            // 2. Soft shadow under the inner rounded rect
            BeautifyRenderer.drawInnerShadow(
                innerRect: innerRect,
                cornerRadius: BeautifyRenderer.innerCornerRadius,
                context: context
            )

            // 3. Clip to rounded inner area + translate, then draw inner content
            context.saveGState()
            let clipPath = CGPath(
                roundedRect: innerRect,
                cornerWidth: BeautifyRenderer.innerCornerRadius,
                cornerHeight: BeautifyRenderer.innerCornerRadius,
                transform: nil
            )
            context.addPath(clipPath)
            context.clip()
            context.translateBy(x: padding, y: padding)

            let innerBounds = CGRect(origin: .zero, size: innerImageSize)
            drawInnerContent(in: context, bounds: innerBounds)

            context.restoreGState()
            return
        }

        drawInnerContent(in: context, bounds: bounds)
    }

    private func drawInnerContent(in context: CGContext, bounds: CGRect) {
        if let previewImage {
            previewImage.draw(in: NSRect(origin: .zero, size: bounds.size))
        }

        // Draw all committed annotations
        for annotation in annotations {
            annotation.draw(in: context, bounds: bounds)
        }

        // Draw in-progress pen stroke
        if let path = currentPenPath {
            currentColor.setStroke()
            path.lineWidth = currentLineWidth
            path.stroke()
        }

        // Draw in-progress shape preview
        if let start = shapeStart, let current = shapeCurrent {
            context.setStrokeColor(currentColor.cgColor)
            context.setLineWidth(currentLineWidth)

            switch activeTool {
            case .rectangle:
                let rect = rectFromTwoPoints(start, current)
                context.stroke(rect)
            case .ellipse:
                let rect = rectFromTwoPoints(start, current)
                context.strokeEllipse(in: rect)
            case .arrow:
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: current)
                context.strokePath()
                let dx = current.x - start.x
                let dy = current.y - start.y
                let length = sqrt(dx * dx + dy * dy)
                if length > 0 {
                    let headLength: CGFloat = max(12, currentLineWidth * 4)
                    let headWidth: CGFloat = max(8, currentLineWidth * 3)
                    let unitX = dx / length
                    let unitY = dy / length
                    let baseX = current.x - unitX * headLength
                    let baseY = current.y - unitY * headLength
                    context.setFillColor(currentColor.cgColor)
                    context.move(to: current)
                    context.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
                    context.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
                    context.closePath()
                    context.fillPath()
                }
            default:
                break
            }
        }

        // Draw mosaic preview (points being brushed)
        if !currentMosaicPoints.isEmpty {
            let brushRadius = currentMosaicBlockSize * 1.5
            context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            for point in currentMosaicPoints {
                context.fillEllipse(in: NSRect(
                    x: point.x - brushRadius,
                    y: point.y - brushRadius,
                    width: brushRadius * 2,
                    height: brushRadius * 2
                ))
            }
        }
    }
```

- [ ] **Step 2: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`

- [ ] **Step 3: Commit**

```bash
git add capcap/Editor/EditCanvasView.swift
git commit -m "$(cat <<'EOF'
feat(beautify): render live beautify frame in EditCanvasView.draw

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: EditCanvasView — compositeImage wraps through BeautifyRenderer

**Files:**
- Modify: `capcap/Editor/EditCanvasView.swift`

- [ ] **Step 1: Modify `compositeImage` to wrap through the renderer**

Find `func compositeImage(fallbackBaseImage: NSImage?) -> NSImage?` (around line 290). Replace the whole function with:

```swift
    func compositeImage(fallbackBaseImage: NSImage?) -> NSImage? {
        guard let baseImage = previewImage ?? fallbackBaseImage else { return nil }

        let innerImage: NSImage
        if annotations.isEmpty {
            innerImage = baseImage
        } else if
            let compositeRep = baseImage.bitmapImageRepPreservingBacking(),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: compositeRep)
        {
            // compositeRep is created from baseImage's CGImage, so it already
            // contains the base image pixels. We only need to draw annotations
            // on top — do NOT call baseImage.draw here or you'll double-composite.
            let imageBounds = NSRect(origin: .zero, size: baseImage.size)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            graphicsContext.imageInterpolation = .high

            let context = graphicsContext.cgContext
            for annotation in annotations {
                annotation.draw(in: context, bounds: imageBounds)
            }

            NSGraphicsContext.restoreGraphicsState()

            let merged = NSImage(size: baseImage.size)
            merged.addRepresentation(compositeRep)
            innerImage = merged
        } else {
            innerImage = baseImage
        }

        if let preset = beautifyPreset {
            return BeautifyRenderer.render(innerImage: innerImage, preset: preset)
        }
        return innerImage
    }
```

- [ ] **Step 2: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`

- [ ] **Step 3: Commit**

```bash
git add capcap/Editor/EditCanvasView.swift
git commit -m "$(cat <<'EOF'
feat(beautify): wrap compositeImage output through BeautifyRenderer

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: BeautifySubToolbar + BeautifySwatchView

**Files:**
- Modify: `capcap/Editor/EditWindowController.swift`

- [ ] **Step 1: Append `BeautifySubToolbar` and `BeautifySwatchView` to the end of the file**

Open `capcap/Editor/EditWindowController.swift`. Scroll to the very end of the file (after the last closing brace of `ColorSwatchView` and any other helper classes). Append:

```swift

// MARK: - Beautify Sub-toolbar

private class BeautifySubToolbar: NSView {
    var onPresetSelected: ((BeautifyPreset) -> Void)?
    var currentPresetID: String? {
        didSet { updateSelection() }
    }

    private var swatchButtons: [BeautifySwatchView] = []
    private let presets: [BeautifyPreset]
    private let swatchDiameter: CGFloat = 24
    private let swatchSpacing: CGFloat = 8
    private let innerPadding: CGFloat = 12

    init(frame: NSRect, presets: [BeautifyPreset]) {
        self.presets = presets
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func preferredWidth(presetCount: Int) -> CGFloat {
        let diameter: CGFloat = 24
        let spacing: CGFloat = 8
        let padding: CGFloat = 12
        return padding * 2 + CGFloat(presetCount) * diameter + CGFloat(max(presetCount - 1, 0)) * spacing
    }

    private func setup() {
        var x: CGFloat = innerPadding
        let midY = bounds.midY
        for (i, preset) in presets.enumerated() {
            let rect = NSRect(
                x: x,
                y: midY - swatchDiameter / 2,
                width: swatchDiameter,
                height: swatchDiameter
            )
            let swatch = BeautifySwatchView(
                frame: rect,
                preset: preset,
                isSelected: preset.id == currentPresetID
            )
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(swatchTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            swatchButtons.append(swatch)
            x += swatchDiameter + swatchSpacing
        }
    }

    @objc private func swatchTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? BeautifySwatchView else { return }
        let index = view.itemIndex
        guard index < presets.count else { return }
        let preset = presets[index]
        currentPresetID = preset.id
        onPresetSelected?(preset)
    }

    private func updateSelection() {
        for swatch in swatchButtons {
            swatch.isSelected = (swatch.preset.id == currentPresetID)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.9).setFill()
        path.fill()
    }
}

private class BeautifySwatchView: NSView {
    let preset: BeautifyPreset
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    var itemIndex: Int = 0

    init(frame: NSRect, preset: BeautifyPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isSelected ? 1 : 2
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let clipPath = NSBezierPath(ovalIn: circleRect)
        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()

        if let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) {
            gradient.draw(in: circleRect, angle: preset.angleDegrees)
        } else {
            preset.startColor.setFill()
            circleRect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Subtle outer border so light presets remain visible on dark toolbar
        let border = NSBezierPath(ovalIn: circleRect)
        NSColor.white.withAlphaComponent(0.15).setStroke()
        border.lineWidth = 0.5
        border.stroke()

        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds)
            accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
```

- [ ] **Step 2: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`

- [ ] **Step 3: Commit**

```bash
git add capcap/Editor/EditWindowController.swift
git commit -m "$(cat <<'EOF'
feat(beautify): add BeautifySubToolbar and swatch view

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Toolbar button + EditWindowController wiring

**Files:**
- Modify: `capcap/Editor/EditWindowController.swift`

This task has several related changes to `EditWindowController`; doing them together keeps the tree in a coherent state. Apply all steps, then compile check once, then commit once.

- [ ] **Step 1: Add `onBeautify` callback + `beautifyBtn` property + `setBeautifyActive` on `ToolbarView`**

Find `class ToolbarView: NSView` (around line 511). In the callback declarations section add:

```swift
    var onBeautify: (() -> Void)?
```

(put it next to `var onScrollCapture: (() -> Void)?`).

In the private properties section, add:

```swift
    private var beautifyBtn: ToolButton?
```

(next to `scrollCaptureBtn`).

Add a new method next to `setScrollCaptureActive`:

```swift
    func setBeautifyActive(_ active: Bool) {
        beautifyBtn?.isSelected = active
    }
```

- [ ] **Step 2: Insert beautify button into `setupButtons`**

In `setupButtons()`, update `totalButtons` and insert a new button between the scrollCapture button and the separator. Replace the block that starts with `let totalButtons = 12` through the separator bump with:

Before (approx lines 543-599):

```swift
        // 12 buttons: rect, ellipse, arrow, pen, mosaic, numbered, undo, scrollCapture | save, pin, cancel, confirm
        let totalButtons = 12
```

After:

```swift
        // 13 buttons: rect, ellipse, arrow, pen, mosaic, numbered, undo, scrollCapture, beautify | save, pin, cancel, confirm
        let totalButtons = 13
```

Then, still in `setupButtons()`, locate the scroll capture button block. After it adds `scrollBtn` and before the line that does `x += buttonSize + spacing + separatorWidth`, replace that step with:

```swift
        scrollBtn.target = self
        scrollBtn.action = #selector(scrollCaptureTapped)
        addSubview(scrollBtn)
        scrollCaptureBtn = scrollBtn
        x += buttonSize + spacing

        // Beautify button
        let beautifyBtn = ToolButton(
            frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
            symbolName: "sparkles",
            normalColor: .white,
            selectedColor: accentGreen
        )
        beautifyBtn.target = self
        beautifyBtn.action = #selector(beautifyTapped)
        addSubview(beautifyBtn)
        self.beautifyBtn = beautifyBtn
        x += buttonSize + spacing + separatorWidth
```

- [ ] **Step 3: Add `beautifyTapped` selector**

Near the existing `@objc private func scrollCaptureTapped() { onScrollCapture?() }`, add:

```swift
    @objc private func beautifyTapped() { onBeautify?() }
```

- [ ] **Step 4: Bump toolbar width in `EditWindowController.toolbarRect`**

Find `private func toolbarRect(in bounds: NSRect) -> NSRect` (around line 443). Change:

```swift
        let width: CGFloat = 480
```

to:

```swift
        let width: CGFloat = 520
```

- [ ] **Step 5: Track beautify state on the controller + add helper methods**

Find the property list at the top of `class EditWindowController` (around line 3). After `private var activeTool: EditTool = .none`, add:

```swift
    private var beautifySubToolbarView: BeautifySubToolbar?
    private var isBeautifyActive: Bool = false
```

Wire up `onBeautify` in `showToolbar()`. Find the block that assigns closures on `tv` (around line 86) and add:

```swift
        tv.onBeautify = { [weak self] in self?.toggleBeautify() }
```

next to `tv.onScrollCapture = ...`.

Add these helper methods inside `class EditWindowController`, placed near the other private tool helpers (for example right after `showMosaicSubToolbar()` around line 181):

```swift
    // MARK: - Beautify

    private func toggleBeautify() {
        if isBeautifyActive {
            deactivateBeautify()
        } else {
            activateBeautify()
        }
    }

    private func activateBeautify() {
        guard let canvasView else { return }
        let preset = BeautifyPreset.defaultPreset

        // Exit any active annotation tool first
        if activeTool != .none {
            activeTool = .none
            canvasView.activeTool = .none
            toolbarView?.updateSelection(tool: .none)
            subToolbarView?.removeFromSuperview()
            subToolbarView = nil
        }

        canvasView.setBeautify(preset)
        isBeautifyActive = true
        toolbarView?.setBeautifyActive(true)
        showBeautifySubToolbar(selecting: preset)
        Defaults.lastBeautifyPresetID = preset.id

        updateCanvasFrameForBeautify()
        updateEditorInteractionState()
        bringEditorToFront()
    }

    private func deactivateBeautify() {
        guard let canvasView else { return }
        canvasView.setBeautify(nil)
        isBeautifyActive = false
        toolbarView?.setBeautifyActive(false)
        beautifySubToolbarView?.removeFromSuperview()
        beautifySubToolbarView = nil

        updateCanvasFrameForBeautify()
        updateEditorInteractionState()
        bringEditorToFront()
    }

    private func applyBeautifyPreset(_ preset: BeautifyPreset) {
        guard let canvasView else { return }
        canvasView.setBeautify(preset)
        Defaults.lastBeautifyPresetID = preset.id
        beautifySubToolbarView?.currentPresetID = preset.id
        updateCanvasFrameForBeautify()
    }

    private func showBeautifySubToolbar(selecting preset: BeautifyPreset) {
        guard let hostSelectionView, let toolbarFrame = toolbarView?.frame else { return }

        beautifySubToolbarView?.removeFromSuperview()

        let width = BeautifySubToolbar.preferredWidth(presetCount: BeautifyPreset.defaults.count)
        let height: CGFloat = 36
        let subRect = subToolbarRect(
            width: width,
            height: height,
            toolbarFrame: toolbarFrame,
            in: hostSelectionView.bounds
        )

        let view = BeautifySubToolbar(frame: subRect, presets: BeautifyPreset.defaults)
        view.currentPresetID = preset.id
        view.onPresetSelected = { [weak self] selected in
            self?.applyBeautifyPreset(selected)
        }
        styleFloatingHUD(view)
        hostSelectionView.addSubview(view)
        beautifySubToolbarView = view
    }

    private func updateCanvasFrameForBeautify() {
        guard
            let canvasView,
            let canvasScrollView,
            let hostSelectionView
        else { return }

        if isBeautifyActive {
            let outer = canvasView.outerSizeWithBeautify
            let overlayBounds = hostSelectionView.bounds
            let targetWidth = min(outer.width, overlayBounds.width)
            let targetHeight = min(outer.height, overlayBounds.height)
            let centerX = selectionViewRect.midX
            let centerY = selectionViewRect.midY
            var x = centerX - targetWidth / 2
            var y = centerY - targetHeight / 2
            x = max(overlayBounds.minX, min(overlayBounds.maxX - targetWidth, x))
            y = max(overlayBounds.minY, min(overlayBounds.maxY - targetHeight, y))
            canvasScrollView.frame = NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
        } else {
            canvasScrollView.frame = selectionViewRect
        }

        canvasView.needsDisplay = true
    }
```

- [ ] **Step 6: Auto-close beautify when entering an annotation tool or starting scroll capture**

Find `private func selectTool(_ tool: EditTool)` (around line 118). At the very top of the method add:

```swift
        if isBeautifyActive {
            deactivateBeautify()
        }
```

Find `private func startScrollCapture()` (around line 208). At the very top add the same guard:

```swift
        if isBeautifyActive {
            deactivateBeautify()
        }
```

- [ ] **Step 7: Freeze selection interaction when beautify is active**

Find `private func updateEditorInteractionState()` (around line 435). Replace its body with:

```swift
        let hasPreview = canvasView?.hasPreviewImage == true
        hostSelectionView?.annotationToolActive = (activeTool != .none) || isBeautifyActive
        hostSelectionView?.selectionInteractionEnabled = !(isScrollCapturing || hasPreview || isBeautifyActive)
        canvasScrollView?.isInteractionEnabled = (activeTool != .none) || hasPreview || isBeautifyActive
        hostSelectionView?.needsDisplay = true
```

- [ ] **Step 8: Keep beautify in sync on layout changes**

Find `func updateLayout(selectionRect: NSRect, selectionViewRect: NSRect, captureRect: CGRect)` (around line 98). At the end of its body (after the subtoolbar position update) add:

```swift
        if isBeautifyActive {
            updateCanvasFrameForBeautify()
            if let hostSelectionView, let toolbarFrame = toolbarView?.frame {
                let width = BeautifySubToolbar.preferredWidth(presetCount: BeautifyPreset.defaults.count)
                beautifySubToolbarView?.frame = subToolbarRect(
                    width: width,
                    height: 36,
                    toolbarFrame: toolbarFrame,
                    in: hostSelectionView.bounds
                )
            }
        }
```

- [ ] **Step 9: Clean up beautify state in `tearDown`**

Find `func tearDown()` (around line 325). Immediately after it hides `subToolbarView`, add:

```swift
        beautifySubToolbarView?.removeFromSuperview()
        beautifySubToolbarView = nil
        isBeautifyActive = false
```

- [ ] **Step 10: Compile check**

```bash
bash scripts/compile-check.sh
```

Expected: `✓ No compilation errors found`

If the compiler complains about `hostSelectionView?.annotationToolActive` being unknown, leave that attribute alone — it already exists. The change just ORs `isBeautifyActive` into the expression.

- [ ] **Step 11: Commit**

```bash
git add capcap/Editor/EditWindowController.swift
git commit -m "$(cat <<'EOF'
feat(beautify): wire beautify toolbar button and sub-toolbar

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Manual verification

**Files:** None (runtime verification)

- [ ] **Step 1: Build and relaunch the app**

```bash
bash scripts/rebuild-and-open.sh
```

Expected: app launches, menu bar icon appears, no crash.

- [ ] **Step 2: Walk the manual test checklist from the spec**

Double-tap ⌘ to trigger a screenshot, drag out a selection, and verify:

1. **Basic beautify** — Click the ✨ button. The canvas expands, default gradient (last used, or "Peach Blue" on first run) is applied live. Press Enter. Paste somewhere — the clipboard contains the beautified image.
2. **Preset switching** — Click ✨, then click each of the 8 swatches in the sub-toolbar. The live preview updates for each.
3. **Annotate, then beautify** — Take a new screenshot, draw a rectangle and a pen scribble, click ✨. The annotations are visible inside the inner image. Press Enter. Paste and verify annotations appear inside the framed image.
4. **Beautify, then draw** — Take a new screenshot, click ✨, then click the pen tool. Beautify should auto-close (button un-highlights, canvas shrinks back) and the pen tool activates.
5. **Undo** — Draw a few shapes, click ✨, click ✨ again to turn off, press undo — last annotation is removed. Turn beautify back on — the undone state persists.
6. **Scroll capture + beautify** — Take a screenshot of a scrollable view, start scroll capture, capture a few pages, stop. On the merged preview, click ✨. The long image is wrapped in the frame. Confirm.
7. **Persistence** — Pick gradient #5 (Warm Orange), confirm. Quit capcap completely. Relaunch. Take a new screenshot, click ✨ — it should default to Warm Orange.
8. **Small selection** — Select a tiny region (~60×60). Click ✨. The frame renders; inner image is not collapsed.
9. **Pin** — Click ✨, then the pin button. A floating window appears sized to the beautified image and displays it correctly.
10. **Save as PNG** — Click ✨, then save. Open the PNG — it matches the beautified preview.

- [ ] **Step 3: If everything looks right, there's nothing left to commit**

All the implementation commits happened in earlier tasks. If manual testing reveals any bug, fix it (add a dedicated commit) and re-run the checklist.

---

## Self-review checklist

After finishing the plan, re-read the spec side by side:

- **BeautifyPreset struct + 8 defaults + persistence** → Task 1 ✓
- **BeautifyRenderer (padding, outputSize, drawBackground, drawInnerShadow, render)** → Task 2 ✓
- **EditCanvasView state (beautifyPreset, innerImageSize) + setBeautify** → Task 3 ✓
- **Live preview (draw branch)** → Task 4 ✓
- **Composite wrap** → Task 5 ✓
- **BeautifySubToolbar UI** → Task 6 ✓
- **Toolbar button + controller wiring + auto-close + scroll view sync** → Task 7 ✓
- **Manual verification** → Task 8 ✓
- **Spec §"交互流程"** — all 8 steps covered across Tasks 3, 4, 5, 7 ✓
- **Spec §"边界情况"** — small/large selection handled by `padding(for:)` clamp; scroll overflow handled by `updateCanvasFrameForBeautify`; long screenshot handled because `loadPreviewImage` updates `innerImageSize`; HiDPI handled via `innerPixelScale` computation in `BeautifyRenderer.render` ✓
- **YAGNI items** — no custom gradient picker, no sliders, no dark mode presets ✓
