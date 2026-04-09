# Beautify Padding Slider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users override the auto-computed beautify padding with a horizontal `NSSlider` (8–56 px, default 24) placed to the right of the swatches in `BeautifySubToolbar`, persisting the value across sessions.

**Architecture:** Introduce a user-controlled padding override that flows from the slider → `EditWindowController` state → `BeautifyContainerView` (live preview) and → `BeautifyRenderer.render(padding:)` overload (final composite). The existing `BeautifyRenderer.padding(for:)` auto-ratio stays intact as a fallback but is no longer used by the beautify flow. Persistence lives in `Defaults.lastBeautifyPadding`.

**Tech Stack:** Swift 5, AppKit, Swift Package Manager. No unit tests in this project — verification uses `bash scripts/compile-check.sh` after each task and `bash scripts/rebuild-and-open.sh` for end-to-end manual verification (per `CLAUDE.md`).

**Reference spec:** `docs/superpowers/specs/2026-04-10-beautify-padding-slider-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `capcap/Utilities/Defaults.swift` | Modify | Add `lastBeautifyPadding` UserDefaults property with 8–56 clamping. |
| `capcap/Editor/BeautifyRenderer.swift` | Modify | Add slider bounds constants and an explicit-padding `render(padding:)` overload. |
| `capcap/Editor/BeautifyContainerView.swift` | Modify | Add `customPadding` override + `setPadding(_:)`; use it in `relayout()`. |
| `capcap/Editor/EditCanvasView.swift` | Modify | Extend `compositeImage` with optional `beautifyPadding` parameter. |
| `capcap/Editor/EditWindowController.swift` | Modify | Extend `BeautifySubToolbar` with slider UI; wire `currentBeautifyPadding` state; pass value through live preview + composite. |

---

## Task 1: Add `Defaults.lastBeautifyPadding`

**Files:**
- Modify: `capcap/Utilities/Defaults.swift`

- [ ] **Step 1: Add the property**

Open `capcap/Utilities/Defaults.swift` and insert the following property inside the `Defaults` struct, right after the existing `lastBeautifyPresetID` property (around line 108):

```swift
static var lastBeautifyPadding: Double {
    get {
        if defaults.object(forKey: "lastBeautifyPadding") == nil {
            return 24
        }
        let val = defaults.double(forKey: "lastBeautifyPadding")
        return min(max(val, 8), 56)
    }
    set {
        defaults.set(min(max(newValue, 8), 56), forKey: "lastBeautifyPadding")
    }
}
```

Rationale: first-launch default is 24; any stored value is clamped on both read and write so pre-existing bad data or future range changes can't produce out-of-range values.

- [ ] **Step 2: Compile check**

Run: `bash scripts/compile-check.sh`
Expected: `✓ No compilation errors found`

- [ ] **Step 3: Commit**

```bash
git add capcap/Utilities/Defaults.swift
git commit -m "$(cat <<'EOF'
feat(defaults): add lastBeautifyPadding with 8-56 clamp

Introduces a persisted user-controlled padding value for the
beautify screenshot feature, defaulting to 24 px and clamped
to the 8-56 px slider range on both read and write.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `BeautifyRenderer` slider constants and explicit-padding render overload

**Files:**
- Modify: `capcap/Editor/BeautifyRenderer.swift`

- [ ] **Step 1: Add slider bounds constants**

Open `capcap/Editor/BeautifyRenderer.swift` and add three constants inside the `BeautifyRenderer` enum, in the `// MARK: - Layout constants` section (after `shadowOffset`, around line 14):

```swift
// MARK: - Slider bounds (user-controlled padding)
static let paddingSliderMin: CGFloat = 8
static let paddingSliderMax: CGFloat = 56
static let paddingSliderDefault: CGFloat = 24
```

- [ ] **Step 2: Add explicit-padding geometry helpers**

Still in `BeautifyRenderer.swift`, add two helpers just after the existing `innerRect(for:)` method (around line 32, inside `// MARK: - Geometry`):

```swift
static func outputSize(innerSize: CGSize, padding: CGFloat) -> CGSize {
    return CGSize(
        width: innerSize.width + 2 * padding,
        height: innerSize.height + 2 * padding
    )
}

static func innerRect(innerSize: CGSize, padding: CGFloat) -> CGRect {
    return CGRect(x: padding, y: padding, width: innerSize.width, height: innerSize.height)
}
```

These are overloads that take an explicit padding instead of running `padding(for:)`.

- [ ] **Step 3: Add the explicit-padding `render` overload**

Still in `BeautifyRenderer.swift`, add a new method immediately after the existing `render(innerImage:preset:)` method (around line 143, before the closing brace of the enum):

```swift
/// Variant of `render` that uses an explicit padding value (in points)
/// instead of running the auto-ratio `padding(for:)`. Used by the
/// beautify editor when the user drives padding from the sub-toolbar slider.
static func render(innerImage: NSImage, preset: BeautifyPreset, padding: CGFloat) -> NSImage {
    let innerSize = innerImage.size
    guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

    let outer = outputSize(innerSize: innerSize, padding: padding)
    let outerRect = CGRect(origin: .zero, size: outer)
    let inner = innerRect(innerSize: innerSize, padding: padding)

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
```

The implementation is a near-copy of the existing `render(innerImage:preset:)`; the only difference is it uses the explicit `padding` instead of `padding(for: innerSize)`. The existing method stays untouched to avoid cascading changes to non-beautify callers (there are none right now, but it's a safety net).

- [ ] **Step 4: Compile check**

Run: `bash scripts/compile-check.sh`
Expected: `✓ No compilation errors found`

- [ ] **Step 5: Commit**

```bash
git add capcap/Editor/BeautifyRenderer.swift
git commit -m "$(cat <<'EOF'
feat(beautify): add slider constants and explicit-padding render

Exposes paddingSliderMin/Max/Default constants and introduces
render(innerImage:preset:padding:) plus matching geometry
helpers that skip the auto-ratio padding math. The existing
auto-ratio render() is untouched.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `customPadding` override to `BeautifyContainerView`

**Files:**
- Modify: `capcap/Editor/BeautifyContainerView.swift`

- [ ] **Step 1: Add the stored property and setter**

Open `capcap/Editor/BeautifyContainerView.swift` and add a property + setter inside the class, directly under the existing `beautifyPreset` property (around line 13):

```swift
/// User-driven padding override. When `nil`, `relayout()` falls back to
/// `BeautifyRenderer.padding(for:)`. When set, the live preview uses this
/// value and the controller is responsible for forwarding the same value
/// to `BeautifyRenderer.render(innerImage:preset:padding:)` at save time.
private(set) var customPadding: CGFloat?
```

Then add a `setPadding(_:)` method right next to `setBeautify(preset:)` (around line 46):

```swift
func setPadding(_ padding: CGFloat?) {
    customPadding = padding
    relayout()
    needsDisplay = true
}
```

- [ ] **Step 2: Update `relayout()` to honor the override**

Still in `BeautifyContainerView.swift`, replace the body of `relayout()` so it uses the override when present. The current method (around line 55) reads:

```swift
private func relayout() {
    guard let canvasView else { return }
    let inner = canvasView.frame.size
    if beautifyPreset != nil, inner.width > 0, inner.height > 0 {
        let p = BeautifyRenderer.padding(for: inner)
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
```

Change the `let p` line to:

```swift
        let p = customPadding ?? BeautifyRenderer.padding(for: inner)
```

So the full method becomes:

```swift
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
```

- [ ] **Step 3: Compile check**

Run: `bash scripts/compile-check.sh`
Expected: `✓ No compilation errors found`

Behavior check (reasoning, no runtime check yet): because `customPadding` defaults to `nil`, existing call sites continue to produce the same auto-ratio behavior. The new override is dormant until Task 6 wires it up.

- [ ] **Step 4: Commit**

```bash
git add capcap/Editor/BeautifyContainerView.swift
git commit -m "$(cat <<'EOF'
feat(beautify): honor customPadding override in container layout

Adds BeautifyContainerView.customPadding (plus a setPadding() setter)
and uses it in relayout() when non-nil, falling back to
BeautifyRenderer.padding(for:) otherwise. Dormant until the
editor wires a value in.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Thread optional padding through `EditCanvasView.compositeImage`

**Files:**
- Modify: `capcap/Editor/EditCanvasView.swift`

- [ ] **Step 1: Extend the method signature**

Open `capcap/Editor/EditCanvasView.swift` and locate `compositeImage(fallbackBaseImage:beautifyPreset:)` (around line 322). Change the signature to:

```swift
func compositeImage(
    fallbackBaseImage: NSImage?,
    beautifyPreset: BeautifyPreset? = nil,
    beautifyPadding: CGFloat? = nil
) -> NSImage?
```

- [ ] **Step 2: Use the new renderer overload when padding is provided**

Still in `compositeImage`, locate the tail of the method (around line 355):

```swift
        if let preset = beautifyPreset {
            return BeautifyRenderer.render(innerImage: innerImage, preset: preset)
        }
        return innerImage
```

Replace it with:

```swift
        if let preset = beautifyPreset {
            let pad = beautifyPadding ?? BeautifyRenderer.paddingSliderDefault
            return BeautifyRenderer.render(innerImage: innerImage, preset: preset, padding: pad)
        }
        return innerImage
```

Rationale: once the feature ships, the controller always passes an explicit padding. If some future caller forgets, we use the sane 24 px default instead of silently going back to the old auto-ratio that the user already rejected.

- [ ] **Step 3: Compile check**

Run: `bash scripts/compile-check.sh`
Expected: `✓ No compilation errors found`

The existing call in `EditWindowController.currentCompositeImage` doesn't pass `beautifyPadding`, so it defaults to `nil` and the compositeImage method uses 24 — a harmless default that will be overridden by Task 6.

- [ ] **Step 4: Commit**

```bash
git add capcap/Editor/EditCanvasView.swift
git commit -m "$(cat <<'EOF'
feat(beautify): thread explicit padding through compositeImage

Extends EditCanvasView.compositeImage with an optional
beautifyPadding parameter and forwards it to the new
BeautifyRenderer.render(padding:) overload. Defaults to the
slider's default (24) when omitted.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add slider UI to `BeautifySubToolbar`

**Files:**
- Modify: `capcap/Editor/EditWindowController.swift`

- [ ] **Step 1: Add new stored state and layout constants**

Open `capcap/Editor/EditWindowController.swift` and locate the `BeautifySubToolbar` class (around line 1448). Replace its stored-property block:

```swift
private var swatchButtons: [BeautifySwatchView] = []
private let presets: [BeautifyPreset]
private let swatchDiameter: CGFloat = 24
private let swatchSpacing: CGFloat = 8
private let innerPadding: CGFloat = 12
```

With:

```swift
var onPaddingChanged: ((CGFloat) -> Void)?

private var swatchButtons: [BeautifySwatchView] = []
private let presets: [BeautifyPreset]
private let initialPadding: CGFloat
private var paddingSlider: NSSlider?
private let swatchDiameter: CGFloat = 24
private let swatchSpacing: CGFloat = 8
private let innerPadding: CGFloat = 12
private let sliderWidth: CGFloat = 120
private let sliderHeight: CGFloat = 20
```

(Trailing padding, separator width, and separator gap are only needed once each — they are inlined at their point of use rather than hoisted into stored properties. The stored constants above are the ones the setup routine references repeatedly.)

(`onPaddingChanged` is intentionally placed with the other public callback-style API, near `onPresetSelected`.)

- [ ] **Step 2: Update the initializer**

Replace the existing init:

```swift
init(frame: NSRect, presets: [BeautifyPreset]) {
    self.presets = presets
    super.init(frame: frame)
    setup()
}
```

With a new init that accepts an initial padding value (default keeps existing call sites working for the moment):

```swift
init(frame: NSRect, presets: [BeautifyPreset], initialPadding: CGFloat = BeautifyRenderer.paddingSliderDefault) {
    self.presets = presets
    self.initialPadding = initialPadding
    super.init(frame: frame)
    setup()
}
```

- [ ] **Step 3: Update `preferredWidth`**

Replace the static method:

```swift
static func preferredWidth(presetCount: Int) -> CGFloat {
    let diameter: CGFloat = 24
    let spacing: CGFloat = 8
    let padding: CGFloat = 12
    return padding * 2 + CGFloat(presetCount) * diameter + CGFloat(max(presetCount - 1, 0)) * spacing
}
```

With:

```swift
static func preferredWidth(presetCount: Int) -> CGFloat {
    let diameter: CGFloat = 24
    let spacing: CGFloat = 8
    let innerPad: CGFloat = 12
    let separatorGap: CGFloat = 10
    let sliderWidth: CGFloat = 120
    let trailingPad: CGFloat = 12
    let swatches = CGFloat(presetCount) * diameter + CGFloat(max(presetCount - 1, 0)) * spacing
    return innerPad + swatches + separatorGap + sliderWidth + trailingPad
}
```

For 8 presets this yields `12 + (8·24 + 7·8) + 10 + 120 + 12 = 12 + 248 + 10 + 120 + 12 = 402 px`.

- [ ] **Step 4: Extend `setup()` to add the separator and slider**

Replace the existing `setup()`:

```swift
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
```

With:

```swift
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

    // After the loop, `x` has an extra swatchSpacing; back up to the right
    // edge of the last swatch, then lay out: 4 px gap → 1 px separator →
    // 5 px gap → slider. Total = separatorGap (10 px).
    let lastSwatchRightEdge = x - swatchSpacing
    let sepX = lastSwatchRightEdge + 4
    let sep = NSView(frame: NSRect(x: sepX, y: 6, width: 1, height: bounds.height - 12))
    sep.wantsLayer = true
    sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
    addSubview(sep)

    // Horizontal padding slider, 5 px to the right of the separator.
    let sliderX = sepX + 1 + 5
    let slider = NSSlider(
        value: Double(initialPadding),
        minValue: Double(BeautifyRenderer.paddingSliderMin),
        maxValue: Double(BeautifyRenderer.paddingSliderMax),
        target: self,
        action: #selector(paddingSliderChanged(_:))
    )
    slider.isContinuous = true
    slider.frame = NSRect(
        x: sliderX,
        y: midY - sliderHeight / 2,
        width: sliderWidth,
        height: sliderHeight
    )
    addSubview(slider)
    paddingSlider = slider
}
```

- [ ] **Step 5: Add the slider action method**

Add a new `@objc` method inside `BeautifySubToolbar`, right after the existing `swatchTapped(_:)` method (around line 1510):

```swift
@objc private func paddingSliderChanged(_ sender: NSSlider) {
    let clamped = max(
        BeautifyRenderer.paddingSliderMin,
        min(BeautifyRenderer.paddingSliderMax, CGFloat(sender.doubleValue))
    )
    onPaddingChanged?(clamped)
}
```

- [ ] **Step 6: Compile check**

Run: `bash scripts/compile-check.sh`
Expected: `✓ No compilation errors found`

At this point, opening the beautify editor would show the wider toolbar with a working slider — but the slider's callback is nil (wired in the next task), so dragging it has no effect yet.

- [ ] **Step 7: Commit**

```bash
git add capcap/Editor/EditWindowController.swift
git commit -m "$(cat <<'EOF'
feat(beautify): add horizontal padding slider to sub-toolbar

Extends BeautifySubToolbar with a 120 px continuous NSSlider
placed to the right of the color swatches, separated by a
thin vertical rule. Exposes onPaddingChanged callback plus an
initialPadding init parameter. Not yet wired into the editor
controller.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `EditWindowController` state, persistence, and composite

**Files:**
- Modify: `capcap/Editor/EditWindowController.swift`

- [ ] **Step 1: Add `currentBeautifyPadding` state**

Still in `capcap/Editor/EditWindowController.swift`. Locate the instance-property block near the top of `EditWindowController` (around line 16–18):

```swift
private var beautifySubToolbarView: BeautifySubToolbar?
private var isBeautifyActive: Bool = false
private var currentBeautifyPreset: BeautifyPreset?
```

Add a new property right below them:

```swift
private var currentBeautifyPadding: CGFloat = CGFloat(Defaults.lastBeautifyPadding)
```

- [ ] **Step 2: Apply the stored padding when beautify activates**

Locate `activateBeautify()` (around line 249). Find this block:

```swift
currentBeautifyPreset = preset
container.setBeautify(preset: preset)
isBeautifyActive = true
```

Insert a `setPadding` call directly after `container.setBeautify(preset: preset)`:

```swift
currentBeautifyPreset = preset
container.setBeautify(preset: preset)
container.setPadding(currentBeautifyPadding)
isBeautifyActive = true
```

- [ ] **Step 3: Clear the override when beautify deactivates**

Locate `deactivateBeautify()` (around line 278). Find:

```swift
container.setBeautify(preset: nil)
isBeautifyActive = false
```

Change it to:

```swift
container.setBeautify(preset: nil)
container.setPadding(nil)
isBeautifyActive = false
```

- [ ] **Step 4: Wire the slider into the sub-toolbar init**

Locate `showBeautifySubToolbar(selecting:)` (around line 331). Find:

```swift
let view = BeautifySubToolbar(frame: subRect, presets: BeautifyPreset.defaults)
view.currentPresetID = preset.id
view.onPresetSelected = { [weak self] selected in
    self?.applyBeautifyPreset(selected)
}
```

Replace with:

```swift
let view = BeautifySubToolbar(
    frame: subRect,
    presets: BeautifyPreset.defaults,
    initialPadding: currentBeautifyPadding
)
view.currentPresetID = preset.id
view.onPresetSelected = { [weak self] selected in
    self?.applyBeautifyPreset(selected)
}
view.onPaddingChanged = { [weak self] padding in
    self?.applyBeautifyPadding(padding)
}
```

- [ ] **Step 5: Add the `applyBeautifyPadding` method**

Add a new method right after `applyBeautifyPreset(_:)` (around line 310):

```swift
private func applyBeautifyPadding(_ padding: CGFloat) {
    currentBeautifyPadding = padding
    Defaults.lastBeautifyPadding = Double(padding)
    beautifyContainerView?.setPadding(padding)
    updateCanvasFrameForBeautify()
    canvasView?.needsDisplay = true
}
```

- [ ] **Step 6: Pass padding through to the composite path**

Locate `currentCompositeImage()` (around line 555). Change the final return to pass the padding only when beautify is active:

```swift
return canvasView?.compositeImage(
    fallbackBaseImage: fallbackBaseImage,
    beautifyPreset: currentBeautifyPreset,
    beautifyPadding: isBeautifyActive ? currentBeautifyPadding : nil
)
```

- [ ] **Step 7: Compile check**

Run: `bash scripts/compile-check.sh`
Expected: `✓ No compilation errors found`

- [ ] **Step 8: Rebuild and launch for manual verification**

Run: `bash scripts/rebuild-and-open.sh`
Expected: the script reports the app built and relaunched.

Then manually verify:

1. Take a screenshot (double-tap ⌘ or menu bar item).
2. Click the beautify (美化) toolbar button — editor shows the gradient preview.
3. The beautify sub-toolbar should appear with the 8 gradient swatches **followed by a thin separator and a horizontal slider** on the right.
4. Slider thumb sits at ~43% of the track (corresponding to 24 px on the 8…56 range) on first run.
5. Drag the slider to the left — the padding around the screenshot shrinks live. All the way left it should be 8 px (a thin gradient border).
6. Drag to the right — padding grows up to 56 px.
7. Pick a different gradient preset — padding stays exactly where the slider left it.
8. Save / copy / pin the result — the output image is composited with the chosen padding (not the old auto-ratio value).
9. Close the editor without any screenshot. Take a new screenshot and toggle beautify again — the slider restores the last value you left it at.
10. Toggle beautify off, then back on — slider value survives the toggle (because `currentBeautifyPadding` is a stored property on the controller, and `Defaults` also has it).

If any of those fail, stop and diagnose before committing.

- [ ] **Step 9: Commit**

```bash
git add capcap/Editor/EditWindowController.swift
git commit -m "$(cat <<'EOF'
feat(beautify): wire padding slider into editor controller

Introduces currentBeautifyPadding state backed by
Defaults.lastBeautifyPadding, feeds it into the container's
live preview via setPadding(), pushes slider updates back
into the controller through onPaddingChanged, and threads
the value into compositeImage so saved/copied/pinned images
use the user-chosen padding.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (for the implementer after all tasks)

- [ ] Slider appears in the beautify sub-toolbar, to the right of the swatches.
- [ ] Dragging the slider updates the live preview continuously.
- [ ] The same value is used when saving the composite image.
- [ ] Value persists across editor reopens and across toggling beautify.
- [ ] No regressions in the existing swatch selection behavior.
- [ ] `compile-check.sh` passes at every commit.
- [ ] All six commits exist on the branch, in order.
