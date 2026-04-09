# Beautify Padding Slider — Design

## Background

`BeautifyRenderer.padding(for:)` currently auto-computes the beautify
padding as 10% of the short edge, clamped to 16–220 px. This produces
borders that feel too wide in practice. Users want explicit control.

Scope: add a horizontal `NSSlider` to the right of the swatches in
`BeautifySubToolbar` so the user can override padding on the fly, with
the value persisted across sessions.

## Requirements

- Slider is horizontal, continuous, range `8…56` px, default `24`.
- Lives inside `BeautifySubToolbar`, placed to the right of the existing
  color swatches.
- Dragging updates the live preview immediately (container re-layouts,
  scroll view recenters the beautified canvas inside the overlay).
- Value applies to both the live preview and the final composited image
  produced on save/copy/pin.
- Value persists across sessions via `Defaults.lastBeautifyPadding`.
  Fresh installs start at `24`.
- No numeric label next to the slider; the live preview is the feedback.

## Non-goals

- No per-preset padding memory — one padding value shared across all
  gradient presets.
- No settings-panel configuration of the default; persistence is just
  last-used-value.
- No change to `BeautifyRenderer.padding(for:)`'s auto-scaling path. It
  is retained as a safety fallback but the beautify flow will always
  pass an explicit override.

## Architecture

### 1. `Defaults.swift`

Add a new property:

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

### 2. `BeautifyRenderer.swift`

Add three constants:

```swift
static let paddingSliderMin: CGFloat = 8
static let paddingSliderMax: CGFloat = 56
static let paddingSliderDefault: CGFloat = 24
```

Add an overload that takes an explicit padding value and skips the
auto-ratio logic:

```swift
static func render(
    innerImage: NSImage,
    preset: BeautifyPreset,
    padding: CGFloat
) -> NSImage
```

Internally, `outputSize` / `innerRect` computations use the supplied
`padding` directly. The existing `render(innerImage:preset:)` stays
intact; the beautify flow will call the new overload.

### 3. `BeautifyContainerView.swift`

Add a stored property and setter:

```swift
private(set) var customPadding: CGFloat?

func setPadding(_ padding: CGFloat?) {
    customPadding = padding
    relayout()
    needsDisplay = true
}
```

Modify `relayout()`:

```swift
let p = customPadding ?? BeautifyRenderer.padding(for: inner)
```

### 4. `EditCanvasView.swift`

Extend the composite entry point:

```swift
func compositeImage(
    fallbackBaseImage: NSImage?,
    beautifyPreset: BeautifyPreset? = nil,
    beautifyPadding: CGFloat? = nil
) -> NSImage?
```

When `preset` is present, the final branch becomes:

```swift
let pad = beautifyPadding ?? BeautifyRenderer.paddingSliderDefault
return BeautifyRenderer.render(innerImage: innerImage, preset: preset, padding: pad)
```

### 5. `BeautifySubToolbar` (inside `EditWindowController.swift`)

New responsibilities:

- Layout: swatches at the left (unchanged), then a 1 px vertical
  separator, then an `NSSlider` sized roughly `120 × 20` centered
  vertically inside the 36 px toolbar, with trailing padding.
- Update `preferredWidth(presetCount:)`:

  ```
  innerPadding          = 12
  swatchesWidth         = presetCount·24 + (presetCount - 1)·8
  separatorGap          = 10        // 4 px spacing + 1 px separator + 4 px spacing
  sliderWidth           = 120
  trailingPadding       = 12
  total = innerPadding + swatchesWidth + separatorGap + sliderWidth + trailingPadding
  ```

  For 8 presets this yields `12 + 8·24 + 7·8 + 10 + 120 + 12 = 402` px.

- New init signature:

  ```swift
  init(frame: NSRect, presets: [BeautifyPreset], initialPadding: CGFloat)
  ```

- New callback:

  ```swift
  var onPaddingChanged: ((CGFloat) -> Void)?
  ```

- Slider wiring:

  ```swift
  slider.minValue     = Double(BeautifyRenderer.paddingSliderMin)
  slider.maxValue     = Double(BeautifyRenderer.paddingSliderMax)
  slider.doubleValue  = Double(initialPadding)
  slider.isContinuous = true
  slider.target       = self
  slider.action       = #selector(paddingChanged(_:))
  ```

- `draw(_:)` is unchanged aside from the fact that the rounded rect
  now covers the wider frame.

### 6. `EditWindowController.swift`

Additions:

- `private var currentBeautifyPadding: CGFloat = CGFloat(Defaults.lastBeautifyPadding)`
- In `activateBeautify()`, before `updateCanvasFrameForBeautify()`:

  ```swift
  container.setPadding(currentBeautifyPadding)
  ```

- `showBeautifySubToolbar(selecting:)` passes `currentBeautifyPadding`
  into the sub-toolbar init, and wires:

  ```swift
  view.onPaddingChanged = { [weak self] padding in
      self?.applyBeautifyPadding(padding)
  }
  ```

- New method:

  ```swift
  private func applyBeautifyPadding(_ padding: CGFloat) {
      currentBeautifyPadding = padding
      Defaults.lastBeautifyPadding = Double(padding)
      beautifyContainerView?.setPadding(padding)
      updateCanvasFrameForBeautify()
  }
  ```

- `currentCompositeImage()` passes padding through:

  ```swift
  canvasView?.compositeImage(
      fallbackBaseImage: fallbackBaseImage,
      beautifyPreset: currentBeautifyPreset,
      beautifyPadding: isBeautifyActive ? currentBeautifyPadding : nil
  )
  ```

- `deactivateBeautify()` clears `container.setPadding(nil)` so the view
  reverts cleanly if beautify is toggled off.

## Data flow

```
slider drag
  └─► BeautifySubToolbar.paddingChanged
        └─► onPaddingChanged(padding)
              └─► EditWindowController.applyBeautifyPadding
                    ├─► currentBeautifyPadding = padding
                    ├─► Defaults.lastBeautifyPadding = padding
                    ├─► beautifyContainerView.setPadding(padding)
                    │     └─► relayout() → canvas repositioned inside padded frame
                    └─► updateCanvasFrameForBeautify() → scroll view recentered

save/copy/pin
  └─► currentCompositeImage()
        └─► canvasView.compositeImage(... beautifyPadding: currentBeautifyPadding)
              └─► BeautifyRenderer.render(innerImage: preset: padding:)
```

## Edge cases

- **Beautify off:** `customPadding` is `nil`; `relayout()` falls back to
  the zero-padding branch. `compositeImage` is passed `nil`, falling
  back to the inner image unchanged.
- **Very small selections:** padding of 8 is safe — slightly thinner
  than the current 16 clamp but still legible.
- **Very large selections:** padding of 56 is well below the current
  220 clamp, so no layout or memory concerns.
- **HiDPI:** `render(padding:)` reuses the existing `innerPixelScale`
  path, so retina rendering is unchanged.
- **Long-screenshot preview loads:** `canvasSizeDidChange()` calls
  `relayout()`, which now reads `customPadding` — preserved correctly.

## Testing

Manual verification (build via `bash scripts/rebuild-and-open.sh`):

1. Take a screenshot, open editor, toggle beautify.
2. Slider starts at the persisted value (default `24`).
3. Drag slider left → padding shrinks live; drag right → padding grows.
4. Pick different gradient presets → padding unchanged.
5. Save → output image uses slider value (not the old 10%-ratio value).
6. Close and reopen editor → slider restores the last value.
7. Toggle beautify off then back on → slider value preserved.
