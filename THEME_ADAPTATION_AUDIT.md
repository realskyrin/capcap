# Light theme adaptation audit

## Scope

Included: every custom popup dialog, popover, toolbar, sub-toolbar, and transient HUD outside Settings and the History panel

Excluded by product requirement:

- Settings window and Settings panes
- History floating panel and notch panel
- Image-content overlays whose fixed contrast is part of the editing result rather than app chrome, such as selection handles, crop masks, QR target markers, and pinned text paper

## Inventory

The audit found 26 custom theme-sensitive surfaces and 8 native AppKit dialog or sheet call sites, for 34 reviewed user-visible entry points

| Group | Surfaces | Count | Adaptation |
| --- | --- | ---: | --- |
| Editor chrome | Primary toolbar, side toolbar, color and size sub-toolbar, mosaic sub-toolbar, text sub-toolbar, emoji sub-toolbar, beautify sub-toolbar | 7 | Adaptive backgrounds, borders, icons, separators, sliders, checkboxes, and selected states |
| Editor popups | Emoji picker | 1 | Adaptive popover background, border, hover, and selected states |
| Scroll capture | Hint, active control, crop confirm control, preview | 4 | Adaptive floating backgrounds and control colors |
| Pin toolbars | Image pin toolbar, text pin toolbar | 2 | Adaptive capsule backgrounds, borders, labels, and icons |
| Custom dialogs | OCR and translation panel, language picker, text QR dialog, Image Merge window, History item preview and action tooltip | 5 | Removed forced dark appearance, adopted semantic text and surfaces, refreshed layer colors on appearance changes |
| Transient HUDs | Toast, tooltip, cursor chip, countdown, update progress, upload progress, recording HUD | 7 | Adaptive floating surfaces, borders, text, indicators, and live appearance refresh |
| Native AppKit dialogs | 5 `NSAlert` call sites and 3 open or save panel call sites | 8 | Reviewed; these inherit the system appearance after forced-dark parent windows were removed |

## Root causes

- Three in-scope custom windows explicitly forced `darkAqua`: OCR and translation, text QR, and update progress
- Editor and pin toolbars used fixed dark gray fills plus white icons and separators
- Several layer-backed controls converted semantic `NSColor` values to `CGColor` only once, so they could become stale after a live system appearance change
- OCR and translation content used white text and translucent white cards throughout because the whole panel assumed a dark background

## Implementation contract

- `AdaptiveChrome` owns the semantic floating, toolbar, panel, popover, card, border, separator, and selected-state colors
- Custom drawing reads dynamic AppKit colors at draw time
- Layer-backed reusable surfaces resolve their colors against `effectiveAppearance` and reapply them from `viewDidChangeEffectiveAppearance`
- Accent-green selected states retain white foregrounds for contrast in both appearances
- Image content and QR code rendering remain color-stable and are not tinted by the app theme
