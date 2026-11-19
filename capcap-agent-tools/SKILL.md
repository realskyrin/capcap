---
name: capcap-agent-tools
description: Capture screens or exact macOS windows, inspect screenshots, annotate supplied images, and produce PNG evidence with capcap's headless agent CLI. Use for arrows, boxes, labels, mosaic, magnifiers, spotlight regions, cropping and native beautification. Also documents stable accessibility identifiers for capcap's editor.
---

# capcap Agent Tools

## Start here

```bash
CAPCAP="/Applications/capcap.app/Contents/MacOS/capcap"
"$CAPCAP" agent schema --pretty
```

The executable is inside the app bundle; do not assume `capcap` is on PATH.
Agent commands are off by default; `help` and `<command> --help` still work.
If a command fails with exit 77 and `error.code` `agent_disabled`, ask the user
to turn on Agent Command Line in capcap Settings > Permissions; do not change
the preference yourself.
`schema` is the installed version's machine-readable contract: supported types,
fields, aliases, formats, style enums, presentation presets, and a working example.
For a development checkout, run `bash scripts/compile-check.sh`, then
`bash scripts/rebuild-and-open.sh` before testing the installed app.
`.build/debug/capcap` is useful for headless development tests, but its permission
identity may differ from the installed app.

Commands return one JSON object on stdout. Errors return JSON on stderr with
`ok:false`, `error.code`, `error.message`, and `exitCode`; exit 64 is invalid
arguments, exit 1 is an operation failure, exit 77 means agent commands are
disabled in Settings. Help is plain text and exits 0.
Use `--meta FILE` to save result JSON for windows/capture/annotate/validate/run.
Outputs must be distinct from inputs and from each other, including symlink aliases.

## Choose the workflow

**User supplied an image:** use that original file. Do not recapture the chat,
browser, or desktop to recreate it. Inspect it, write a spec, validate, annotate.

**Fresh screenshot:** discover the exact target, capture once, inspect that PNG,
then annotate the same PNG. Do not use `run` after inspecting a previous capture:
it captures a new frame and the content may have moved.

```bash
workdir=$(mktemp -d)
"$CAPCAP" agent windows --owner Safari --title "Release Studio" --pretty
# Select the intended ownerPID/title/frame, then use the returned windowID
"$CAPCAP" agent capture --window-id 12345 --out "$workdir/shot.png" --meta "$workdir/shot.json"
# Inspect shot.png; author marks.json using its actual pixel dimensions
"$CAPCAP" agent validate --input "$workdir/shot.png" --spec "$workdir/marks.json" --pretty
"$CAPCAP" agent annotate --input "$workdir/shot.png" --spec "$workdir/marks.json" --out "$workdir/result.png"
```

**Target and marks already known:** `run` combines capture and annotate. Optional
`--shot-out` retains the original. An `imageSize` guard rejects an unexpected size.

```bash
"$CAPCAP" agent run --window-id 12345 --spec marks.json --out result.png --shot-out raw.png
```

All headless commands avoid opening the editor, changing the clipboard, or adding
history entries. Return the final PNG file to the user and inspect it before
claiming correct visual placement. Validation is structural/renderability checking,
not proof that the annotation identifies the intended content.

## Targets and coordinates

```bash
"$CAPCAP" agent displays --pretty
"$CAPCAP" agent windows --owner capcap --all --pretty
```

`displays` returns connected display IDs, zero-based indices, CG bounds, scale,
and a Screen Recording permission preflight result. It does not request permission.

- `windows` defaults to normal windows; `--all` includes panels, overlays and menus
- `--owner` and `--title` are case-insensitive substring filters
- `--frontmost-only` respects these filters; `--limit N` limits returned results
- Window IDs are temporary: enumerate again after relaunch or panel transitions
- An LSUIElement app can show a panel while another app is frontmost
- For capcap, prefer `windows --owner capcap --all`; never infer its target from frontmost app

Capture targets:

| Target | Selector |
|---|---|
| Exact window | `--window-id ID` (infers `window-id`) |
| Display | `--screen-index N` or `--display-id ID` (infers `screen`) |
| Region | `--rect x,y,width,height` (infers `rect`; inside one display) |
| Cursor display | `--target mouse-screen` (default without selectors) |
| Cursor window | `--target window-at-cursor` |
| Active normal window | `--target frontmost-window` |

Conflicting or irrelevant selectors are errors. `--target screen` without a
selector uses the main screen. Explicit target aliases are listed in command help/source.

**Do not confuse points and pixels.** `windows.frame` and capture `--rect` use
global CG **points**, top-left of the primary display. Annotation coordinates are
**pixels in the captured image**, top-left. A 1249 × 836 point window can produce
a 2498 × 1672 pixel PNG. If an image viewer scales a preview, convert its displayed
coordinates to the PNG dimensions before writing marks.

Read `image.width/height`; do not guess Retina scale. `target.captureMode` (or
`capture.captureMode` for run) indicates isolated `window` capture or
`composited-rect` fallback for menu-level surfaces. A composited rect includes
whatever is visible behind that surface; inspect it before sharing. High-level
capcap editors are captured as independent windows.

## Annotation contract

```json
{
  "version": 1,
  "coordinateSpace": "pixels",
  "origin": "top-left",
  "imageSize": [1200, 800],
  "annotations": [
    {"type":"rect","rect":[80,80,280,120],"strokeStyle":"rounded","color":"#6858EE","lineWidth":4},
    {"type":"arrow","from":[520,240],"to":[350,140],"style":"tapered","color":"#6858EE"},
    {"type":"text","at":[80,35],"text":"Review this area","fontSize":28,"color":"#6858EE"}
  ]
}
```

Use `imageSize` whenever possible: it rejects a spec made for a differently sized
image. It is a size guard, not a content hash. Unknown fields and excess coordinate
components are rejected; annotation failures identify their zero-based index.

- rect/ellipse: `rect`; optional lineWidth, fillMode, strokeStyle, rotation
- arrow/line: `from`, `to`; arrow supports `controlPoint` and style
- text: `at`, `text`; optional fontSize, stroke, callout, tip, rotation
- number: `center`; optional number, tip, controlPoint
- mosaic: `rect`, optional blockSize; `blur` is **pixelation**, not Gaussian blur
- magnifier: `center`; optional radius, zoom, source, lineWidth
- spotlight: `rect`; multiple regions share one dimming overlay, applied last
- pen/marker: nonempty `points`; marker's visible width is **6 × lineWidth**

Run `agent schema` for exact per-type fields. Rects are `[x,y,width,height]`,
points are `[x,y]`; object forms are also accepted. Styles include explicit
`standard` and `tapered` defaults. Color accepts #RGB, #RRGGBB and #RRGGBBAA;
marker uses the editor's fixed translucent brush opacity.

## Crop and beautify

Optional document fields use the same native beautify renderer as the GUI:

```json
{
  "imageSize": [1200,800],
  "annotations": [],
  "crop": [40,40,1120,720],
  "beautify": {"preset":"blue-purple","padding":64,"shadow":true}
}
```

Order is **annotate → crop → beautify**. Marks and crop always use original
input pixels. Crop must fit inside the input; padding is an integer 0…512 pixels
(default 64). `schema` lists preset IDs; wallpaper is intentionally unavailable
in headless specs. `annotationImage` describes the original coordinate canvas;
`image` describes the final PNG. `presentation.inputToOutputOffset` translates
original points to output pixels; cropped-away content remains absent.

## GUI operation when needed

The CLI produces flattened PNGs; it does not create editable GUI sessions, perform
OCR/translation, upload files, stitch scrolling pages or record video. Use the
actual interface for those workflows. `open -a /Applications/capcap.app image.png`
opens an image for editing, with the existing marks flattened into that image.

Lock Computer Use to `/Applications/capcap.app`. Editor controls expose stable
IDs such as `capcap.toolbar.arrow`, `.mosaic`, `.spotlight`, `.magnifier`,
`.beautify`, `.ocr`, `.save`, and `.close`, plus localized labels and shortcuts.
Reacquire the accessibility tree after every UI transition. Do not treat a drag
as proof of ordinary hover behavior.

The [README demo](examples/readme-demo/README.md) contains reusable source content,
annotation specs and a rendering script for an actual end-to-end example.
