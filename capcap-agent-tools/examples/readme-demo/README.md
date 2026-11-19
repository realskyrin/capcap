# README screenshot exercise

These examples were captured from the working app and a local, fictional design-review page. They demonstrate the current editor, spotlight, magnifier, native beautification and five image-host providers. They contain no customer content. The app README documents retain their existing text and gallery layout; these files also provide alternative spotlight and magnifier examples for future documentation updates.

The `capcap agent` commands below require Agent Command Line to be on in capcap Settings > Permissions. While it is off, they exit with code 77.

## Capture the source

From this directory, serve `index.html` with a local HTTP server:

```bash
python3 -m http.server 48763 --bind 127.0.0.1
```

Open `http://127.0.0.1:48763/` in Safari. This example was composed with a 1249 × 836 point Safari window, on a 2× Retina display. Use the real window catalog to discover its current ID:

```bash
CAPCAP="/Applications/capcap.app/Contents/MacOS/capcap"
"$CAPCAP" agent windows --owner Safari --title 'Release Studio' --pretty
"$CAPCAP" agent capture --window-id ACTUAL_ID --out /tmp/source.png
```

Inspect the PNG. `marks.json`, `spotlight.json`, and `magnifier.json` expect 2498 × 1672 input pixels. If the window layout differs, update both the marks and `imageSize` after inspection. Never simply change the dimension guard to suppress an error.

```bash
"$CAPCAP" agent validate --input /tmp/source.png --spec marks.json
"$CAPCAP" agent annotate --input /tmp/source.png --spec marks.json --out /tmp/annotated.png
open -a /Applications/capcap.app /tmp/annotated.png
```

## Capture actual capcap UI

The editor samples were captured on a 1470 × 956 point display. The app fits the imported image to its editor; the raw editor PNG is 2940 × 1912 pixels.

1. Discover `agent windows --owner capcap --all --pretty`. Choose the full-size editor, not the notch panel. Capture its exact window ID into `/tmp/editor.png`
2. Use the accessibility control `capcap.toolbar.beautify`, then the “more colors” control. Capture the editor into `/tmp/beautify.png`. Inspect it to confirm the palette and toolbars are present
3. Close the editor and open settings. Select image hosting and collapse any expanded credential cards by clicking the inert card header. Do not toggle provider enablement, save fields or upload anything. Verify all five provider cards are visible and no credentials appear
4. Discover the settings window by owner and title. Capture it into `/tmp/settings.png`; expected dimensions are 1592 × 1120 pixels

App screenshots must use isolated `window` capture mode, not a composited screen rect. This prevents unrelated windows behind the editor from appearing in public examples. The frames around the screenshots are added by capcap's native beautify renderer; the inner UI is actual captured UI.

## Render

```bash
./render.sh /tmp/source.png /tmp/editor.png /tmp/beautify.png /tmp/settings.png /absolute/path/to/capcap/images
```

The script validates each source/spec pair before writing the five PNGs. Every output uses the same `blue-purple` preset. `crop` is applied after annotations, and padding is added last. Inspect the generated files at README width before accepting them.

`marks.json` creates four marks on the original source before opening it in the editor. Those marks are flattened into the imported image; this sample does not claim to demonstrate an editable CLI project format. The live toolbar belongs to the current app.

## Findings fixed during this exercise

- Explicit documented `standard` shape and `tapered` arrow styles failed
- An implicit screen selector was ignored, and conflicting targets were accepted
- `windows --frontmost-only` bypassed owner/title filters
- Full-screen high-level editors were missing from `windows --all`
- Editor capture used a composited fallback that included unrelated applications
- Annotation typos and extra point/rect components were ignored
- Metadata/output paths could overwrite input files or each other
- Failures lacked machine-readable structure and useful annotation indices
- Tool buttons exposed blank or icon-derived accessibility names
- Native beautification could introduce an unwanted 2× scale in a pixel-based pipeline

The CLI now exposes `schema`, `displays` and `validate`, plus spotlight, crop and beautify. It remains a headless PNG renderer: GUI editing sessions, scrolling capture, OCR, uploads and recording still use their existing interfaces.
