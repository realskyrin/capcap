# Changelog

All notable changes to **capcap** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.4] - 2026-07-03

### Added
- Add screenshot quality compression settings (2da49ae)
- Add share extension and image open handling (83ab9fe)

### Changed
- Refresh update check before showing install prompt (b50de35)
- Simplify compressed screenshot quality hints (559af59)

## [1.6.3] - 2026-07-01

### Fixed
- Stabilize scroll capture finalization (35abc70)

## [1.6.2] - 2026-06-30

### Added
- Lock capture selection to a fixed aspect ratio (46f1bb2)

### Fixed
- Clamp aspect-locked selection to view bounds (f40d712)

### Changed
- Improve cursor chip aspect-ratio messaging (7705cbc)
- Improve toolbar tile tooltip handling (96cd1bf)
- Rename history panel shortcut hold-open flag (acfb872)
- Fix v1.6.1 changelog hash (44e4f41)

## [1.6.1] - 2026-06-30

### Added
- Add capture diagnostics logging for Scroll Stitch and OCR issue triage (883293b)

### Changed
- Refine history panel translations (b9a6720)

## [1.6.0] - 2026-06-28

### Added
- Add settings shortcut to history panel (ec91322)
- Add history panel localization strings (8163e09)
- Support scrolling toolbar previews (373ca58)

### Fixed
- Collapse translation config when provider switch is turned off (b41b9d1)
- Fix image provider config handling (7c565ff)
- Improve translation test failure alerts (0d9dbf8)
- Fix build warnings (702c8a7)

### Changed
- Refine history panel layout, previews, notch behavior, and settings UI (77a83c2, f7adc31, 06959cf, 1b193c4, b60aa7a, 8dd25f9, 94c2e8f)
- Gate scroll capture and allow Enter to confirm crop (44fcb5d)
- Confirm selection on double-click (0f013d5)

## [1.5.5] - 2026-06-24

### Fixed
- Lock OCR translation panel width during resize (21229a7)

### Changed
- Improve text callout editing (ec27e10)
- Remove temporary capture diagnostics logging (703c4e5)
- Clean up checked-in canvas state artifacts (22c35de)

## [1.5.4] - 2026-06-20

### Added
- Add QR code recognition to the editor (42ee423)
- Animate dictionary translation header (0a03adf)

### Fixed
- Exclude toast windows from capture (da145a1)

### Changed
- Show output shortcuts in toolbar tooltips (c956978)

## [1.5.3] - 2026-06-12

### Added
- Add edit suspension and resume flow (ea7f094)
- Add clipboard text pin toolbar and hotkey (0a13513)

### Fixed
- Fix text pin layout padding (7f502f2)

## [1.5.2] - 2026-06-11

### Added
- Add rounded rectangle shape style (2bdb5d4)
- 支持贴图跨桌面显示 (48345a4)

### Fixed
- 处理贴图跨桌面审核意见 (a564a01)

### Changed
- Tone down selection outline contrast (c9150ee)

## [1.5.1] - 2026-06-10

### Added
- Add agent CLI entrypoint (902ce5c)
- Add agent skill (eab696c)
- 支持编辑器切换历史截图 (b6d814e)

### Fixed
- 修复历史截图切换索引 (5842d47)
- 保留历史截图切换时的编辑草稿 (4bb5380)

### Changed
- Add README for capcap agent tools (8a00f33)
- Refine corner resize cursor (b44ca90)

## [1.5.0] - 2026-06-06

### Added
- Add OCR in Pin image (8964612)
- Add annotation hover highlighting (fffa7a7)
- Add unified save path and Finder reveal settings (4ad8402)

### Fixed
- Fix default upload badge vertical centering (5e94ea5)
- Fix magnifier connector and preserve focus on drag (102104d)
- Prevent filename fields from auto-focusing in Settings (680a9e0)

### Changed
- Refine OCR overlay highlighting (5a26808)
- Add OCR copyable text backplates (f3a7b7e)
- Persist editor color and line width choices (d59866f)
- Unify active button accents to green (4a490cf)
- Preserve pinned image pixel size and show edit resolution (3b3196c)
- Refine text callout dragging and labels (0bc1ad1)
- Refine HUD sliders for integer values and marker limit (41e685d)
- Narrow the slider's right edge (16fffa8)
- Refine text callout bubble geometry (5f591cd)
- Reduce editor line width maximum to 16 (b3083da)
- Refine shape fill and hand-drawn stroke rendering (321cf48)
- Refine hand-drawn rectangle rendering (f9c9df4)
- Refine hand-drawn shape previews and stroke rendering (e50131d)
- Refine filename rule layout and variable insertion (2b82626)

## [1.4.0] - 2026-06-04

### Added
- Add copy image text shortcut (30b1eb6)

### Fixed
- Fix popup capture timing and hover detection (744ecf2)

### Changed
- Install minimal Edit menu for save panel shortcuts (3be14cf)

### Documentation
- Add Star History to READMEs (a071b56)
- Refresh README with multilingual intro and Chinese default (8d7f1e1)

## [1.3.29] - 2026-06-03

### Added
- Add color picker shortcut support (c7e6748)

### Changed
- Move filename rules to General settings (47825c8)
- Refine emoji subtoolbar recent-selection behavior (fbd55fc)
- Add manual scroll option to long screenshot capture (53b9288)
- Add edit button to pinned image toolbar (e36ff8f)
- Make emoji Shift-resize square (db0f953)

## [1.3.28] - 2026-06-03

### Added
- Add full-screen screenshot shortcut and menu entry (07372ed)

### Fixed
- Fix shape resize handle flipping (a55374f)
- Disable history cache slider when caching is off (72fa110)

### Changed
- Support Shift resizing and endpoint snapping in editor (246c8de)
- Show instant Markdown hint on cloud history items (e3f8e80)
- Move history actions to top of menu (0e6015d)

## [1.3.27] - 2026-06-02

### Fixed
- Prevent toolbar double-clicks from closing pinned images (002b9ff)
- Fallback to screen backdrop for transparent window captures (34c6af1)

### Changed
- Preserve active window appearance in window screenshots (1a2f0cc)

## [1.3.26] - 2026-05-30

### Added
- Add image merge support and localized strings (e7b5da4)

### Fixed
- Fix image merge thumbnail dragging and auto-scroll (3f66a97)
- Fix selected annotation style sync and arrow widths (d22acfd)

### Changed
- Improve editing scale for large preset images (f254e4a)
- Preserve image size in scaled edit previews (45e8d9d)
- Support clipboard fallback and persist merge settings (7284dd6)
- Gate startup on permissions and add Vietnamese locale (662e494)
- Split DeepLX translation into its own provider (b72a97a)
- Launch silently at login (6eae743)

### Documentation
- Add image merge design spec (37db725)

## [1.3.25] - 2026-05-28

### Added
- Add DeepLX translation provider support (ce5f6da)

### Fixed
- Allow empty API key for self-hosted DeepLX instances (bf93824)

### Changed
- Add DMG artifacts to release workflow (aafbcb6)
- Refine arrow styles to match numbered arrows (c3ed7b4)
- Make translation providers default to off and mark DeepLX key optional (6f8d4b1)
- Expand provider cards when required fields are missing (dbbd68c)
- Make double-click close pinned images (dee774b)
- Refine settings slider rendering to match native controls (e7794b2)
- Add mosaic granularity subtoolbar (c59fd20)

## [1.3.24] - 2026-05-28

### Changed
- Add emoji and image editor tools (fcca0e5)

## [1.3.23] - 2026-05-27

### Changed
- Move Homebrew cask to shared tap (06bdd27)
- Expand scroll crop edge preview width (81264c6)
- Address review: raw pixel signature, crop bounds, scrollbar edge guard (89b8161)
- Reduce auto-scroll step to ~15% of selection height (917c38d)
- Exclude scrollbar and sticky headers from Vision overlap detection (6002ecd)
- Wait for frame settlement before measuring scroll offset (c77ebda)
- Use Apple Vision for scroll-capture overlap detection (9633012)
- Add Shift constraints for shape drawing (09cb3cb)
- Consolidate agent docs and add verification wrappers (1fd1c87)
- Add multi-select selection handling (b337f58)
- Add redo shortcut and undo tips (7c52a5a)
- Add scroll crop confirm tooltip (95ffc2e)

### Chore
- Bump cask to 1.3.22 (302c224)

## [1.3.22] - 2026-05-26

### Changed
- Darken capture overlay dimming (7bc3da2)
- Support multiline text editing and preserve rotation (587f980)
- Cancel active eyedropper on editor teardown (849d1ad)
- Handle Cmd+W in settings window (0c5fb3a)

### Chore
- Bump cask to 1.3.21 (a0fd1b0)

## [1.3.21] - 2026-05-26

### Changed
- Restore source focus and support annotation nudging (07d67b7)
- Address review: chord-based scaling + truncated cp for curved shaft (46bf3bb)
- Address review: centralize arrow geometry + consistent live preview (632f35e)
- Address review: scale short arrows, tight hit-test, accurate bounds (111ad5c)
- Address review: precise head hit-test + simpler cp tangent (ec23dfd)
- Drop unused stroke state from arrow draw (e8373b4)
- Improve arrow shape: tapered shaft + swept head (dac9707)
- Add fill toggle shortcut to editor (c915d9a)

### Chore
- Bump cask to 1.3.20 (9e2d068)

## [1.3.20] - 2026-05-26

### Changed
- Add editor hotkeys and tooltips (53e6444)
- Add ink-bottle hover tips for picked colors (c42b35b)

### Chore
- Bump cask to 1.3.19 (0b9cb75)

## [1.3.19] - 2026-05-25

### Changed
- Delay pin navigator activation and cancel on right click (443ffa2)
- Refine pin navigator hover hiding (e9a7d21)
- Remove beautify debug logs and standardize save filename (61ef976)

### Chore
- Bump cask to 1.3.18 (ed07d1d)

## [1.3.18] - 2026-05-25

### Changed
- Disable window dragging in OCR preview (067d699)
- Refine pin zoom and drag behavior (f4faaa2)
- Make scroll capture stop on any key (5cbe741)
- Make the menu bar icon adapt to appearance (2b58d19)

### Chore
- Bump cask to 1.3.17 (b22fdb3)

## [1.3.17] - 2026-05-24

### Changed
- Trigger silent update checks from screenshot shortcuts (69df444)

### Chore
- Bump cask to 1.3.16 (a3b00c6)

## [1.3.16] - 2026-05-24

### Added
- Add undo state and annotation clipboard shortcuts (451ce2e)

### Chore
- Bump cask to 1.3.15 (d9c4f19)

## [1.3.15] - 2026-05-24

### Added
- Add resize handles for rectangles and ellipses (53931f0)
- Add fill toggle for rectangle and ellipse tools (cc6196c)
- Add OCR and translation cursor chip hints (b1e4c30)
- Add Traditional Chinese localization (a9814e9)

### Fixed
- Fix off-screen window screenshot sizing (d325b95)

### Documentation
- Update language switch links in all three README files (d5e8130)
- Add README.zh-TW.md translated from README.zh-CN.md in Traditional Chinese (Taiwan) (56b294c)

### Chore
- Bump cask to 1.3.14 (7fa20d3)

## [1.3.14] - 2026-05-23

### Added
- Record screen captures (8b284df)

### Fixed
- Fix DeepSeek default link (908fdf8)

### Changed
- Unify recording save flow and keyboard handling (2a48494)
- Show inferred target language in OCR button (fb5a9bf)
- Persist picked color swatch across editor sessions (ae58b55)
- Refine dictionary mode translation UI (f46da28)

### Documentation
- Link README license to LICENSE file (8c5f385)

### Chore
- Bump cask to 1.3.13 (767065f)

## [1.3.13] - 2026-05-23

### Changed
- Bundle PermissionFlow resources in app packaging (ba9b757)

### Chore
- Bump cask to 1.3.12 (5bd5846)

## [1.3.12] - 2026-05-23

### Fixed
- Localize permission flow button title (016fc15)

## [1.3.11] - 2026-05-23

### Changed
- Vendor PermissionFlow and update permission flow (0446c89)

### Chore
- Bump cask to 1.3.10 (8567220)

## [1.3.10] - 2026-05-23

### Changed
- Defer wallpaper loading off the main thread (0cf01c7)

### Chore
- Bump cask to 1.3.9 (b5135f7)

## [1.3.9] - 2026-05-22

### Changed
- Add translation provider reordering and collapse controls (6dfcfa3)
- Increase history cache range to 100 (e05d02f)
- Support DeepL (94a1bb8)
- Support DeepL (6a0a0fe)
- Add pin behavior to OCR panels (de6f441)
- Move OCR and screenshot translation shortcuts to the end (692781b)
- Split OCR into text recognition and screenshot translation (22ec3e0)

### Chore
- Bump cask to 1.3.8 (e3b5323)

## [1.3.8] - 2026-05-21

### Changed
- Add eraser tool for drag-to-delete annotations (6f703c5)
- Enable backspace deletion for selected annotations (731dbf6)
- Reset numbered badge counter after edits and deletions (cd0397b)

## [1.3.7] - 2026-05-21

### Changed
- Add persistent beautify diagnostics (1209f0a)
- Add magnifier lens annotation tool to the editor (1a29b27)
- Add text outline option to the text tool sub-toolbar (77ed2be)

## [1.3.6] - 2026-05-21

### Fixed
- Ship menu bar icon in release bundle (58904c7)

### Changed
- Tighten window capture shadow padding (5068756)
- Refresh image assets (198e63f)

### Chore
- Update release actions to node24 (1d79d56)

## [1.3.5] - 2026-05-20

### Fixed
- Fix beautify toolbar controls (6bd2399)

### Changed
- Adjust menu bar icon size (573bdff)
- Load menu bar icon from bundled SVG (85057a7)

## [1.3.4] - 2026-05-20

### Added
- Add explicit image edit shortcuts (25efe4f)
- Add Star on GitHub link to About pane (6634fb8)
- Add customizable save hotkey with Return fallback (1fe21ef)

### Fixed
- Fix toolbar preview overflow (2f14bb2)
- Fix toolbar tile drop animation (cd73299)
- Reject conflicting hotkey assignments and clean stale update artifacts (e1e737b)
- Fix blunt arrowhead tips by stopping shaft at head base (27505b6)

### Changed
- Make X exit image-edit mode instead of switching to capture (f918d32)
- Auto-apply toolbar edits and reorder shortcut settings (5dfac23)
- Split pin shortcut into image-specific hotkeys (aad3fcb)
- Split editor save hotkey into clipboard and file-save (1571e54)
- Show settings on reopen after app initialization (8d57366)

## [1.3.3] - 2026-05-19

### Added
- Add rounded corners and drop shadow to window captures (29954a2)
- Add beautify shadow toggle and zero padding (6988ea7)

### Changed
- Center image-edit hint toast in selection (83fc49d)
- Improve beautify shadows for window captures (17d8dc4)
- Use real window alpha for captures (45f8f13)
- Allow window detection to select capcap's own content windows (935902d)

## [1.3.2] - 2026-05-19

### Added
- Add line annotation tool with endpoint and rotation handles (bae136e)

### Fixed
- Cache and downscale wallpaper to fix beautify hang (8d64fb6)

### Changed
- Quit on startup dialog close to allow clean relaunch (7522ef4)

## [1.3.1] - 2026-05-19

### Added
- Add side toolbar to the editor (60b4b3c)
- Add Toolbar settings tab with layout preview (c3572be)
- Add drag-and-drop editing to the toolbar layout grids (8936c58)
- Add ToolbarLayout data model for customizable toolbars (c737ebb)
- Pin multiple images in one action (61f58b7)

### Changed
- Keep side toolbar clear of the primary toolbar and split the default layout (715ec86)
- Localize toolbar settings and handle an empty primary toolbar (0b46b92)
- Make ToolbarView data-driven and orientation-aware (a7fa0b5)
- Rework mosaic as a draggable rectangle with resize handles (ae993dc)
- Move history cache and countdown cards to General settings pane (8acd138)
- Prioritize file URL over icon data when editing image from clipboard (debf214)
- Switch to capture mode instead of exiting on X in image-edit (3a86bb6)

## [1.3.0] - 2026-05-18

### Added
- `feat(hotkey): add pin image shortcut` (61dce57)
- `feat(about): add feature-request and bug-report links with issue templates` (88fbf63)

### Fixed
- `fix(hotkey): allow recording shortcuts that use the A key` (d61eb83)

### Changed
- `Add pinned image zoom controls` (a48e9a0)

## [1.2.1] - 2026-05-18

### Fixed
- `fix(ci): copy .lproj localization bundles into release .app` (b98d7b1) — the v1.2.0 release shipped with no localization resources, causing every UI string to render as its raw key

## [1.2.0] - 2026-05-18

### Added
- `feat(upload): add copy-as-Markdown-link toggle and ⌘-click in history` (b09b8ff)
- `feat(upload): reveal-toggle on translation API key and fix upload button gating` (f17e58c)

### Changed
- `refactor(i18n): move UI strings to .lproj resource bundles via Localizer` (1966378)
- `i18n: clarify edit-mode cancel hints with source context` (de128cf)

## [1.1.7] - 2026-05-17

### Added
- `feat(ocr): add OCR text extraction and BYOK AI translation` (5c8c2b5)
- `feat(translation): test AI config on save and default DeepSeek to deepseek-v4-flash` (a6546b0)

### Changed
- `build: sign local builds with shared self-signed cert and install to /Applications` (6444ea3)

## [1.1.6] - 2026-05-17

### Added
- `feat(update): show progress HUD during update check, download, and install` (0696e43)

## [1.1.5] - 2026-05-17

### Added
- `feat(update): auto-download and install updates with version skipping` (fce4a4a)
- `feat(capture): support editing clipboard images via image-edit shortcut` (137b42d)
- `feat(about): add expandable error log viewer for crash reports` (bd603ae)

### Fixed
- `fix(about): keep error log chevron rotating around its center` (0c13611)
- `fix(beautify): keep size label visible above gradient frame` (dd653f4)

## [1.1.4] - 2026-05-17

### Added
- `feat(upload): add Amazon S3 and Cloudflare R2 image hosts` (e8f4cb6)

### Changed
- `ci(release): sign builds with a reusable self-signed certificate` (c254931) — keeps macOS Screen Recording / Accessibility grants across updates

## [1.1.3] - 2026-05-16

### Added
- `feat(update): add GitHub release update detection` (c558475)
- `feat(settings): add About tab with version and open-source info` (6ebfa66)
- `feat(image-edit): add X shortcut to bail out of stale Finder selection` (52cf64b)

## [1.1.2] - 2026-05-16

### Added
- `feat(scroll-capture): auto-scroll capture with fit-to-screen crop mode` (c4962c8)

### Fixed
- `fix(ci): copy app icon into release bundle` (65642cc)
- `fix(scroll-capture): block manual scroll during auto-scroll, add finish hint` (803e420)
- `fix(scroll-capture): make crop loupe follow cursor horizontally` (def7399)

### Documentation
- `docs(readme): acknowledge Linux.do community` (ece4259)

## [1.1.1] - 2026-05-14

### Fixed
- `fix(scroll-capture): stop overlay chrome from bleeding into stitched frames` (50857c5)

### Documentation
- `docs(readme): update app banner image` (c784d25)
- `docs(readme): add app banner image to top of README` (6f246d9)
- `docs(readme): add scroll-stitch and beautify screenshots to showcase` (89e7173)
- `docs(readme): document image-host upload feature with screenshot` (fb08dfc)
- `docs(readme): add hero screenshot and showcase section` (c1d3409)

## [1.1.0] - 2026-05-12

### Added
- `feat(capture): add countdown screenshot triggered by Option modifier` (3d36405)
- `feat(capture): edit Finder-selected image via the screenshot shortcut` (274ee1e)
- `feat(upload): add Tencent COS / Qiniu / Aliyun OSS image-host uploaders` (8debfab)
- `feat(upload): test config on save with status pill and per-card log` (3db53f4)
- `feat(upload): set x-oss-object-acl public-read on Aliyun OSS PUT` (0dda4d9)
- `feat(history): preview uploaded images and copy cloud URL on click` (3ec8854)
- `feat(history): preserve thumbnail aspect ratio and record picked colors` (49d0aa5)
- `feat(settings): redesign settings page with sidebar tab layout` (b3503a0)
- `feat(settings): redesign settings with card layout and NSSwitch` (6b0c8d6)
- `feat(settings): decouple provider card expand from enable switch` (ffe9482)
- `feat(settings): add eye toggle to reveal secret input fields` (504a8c4)
- `feat(settings): add demo mode to let recorders capture overlay` (257b37a)
- `feat(hotkey): add customizable screenshot shortcut with restore-to-default` (cec2655)
- `feat(menu): add SF Symbol icons to status bar menu items` (51c1579)
- `feat(editor): add adjust mode and cross-tool annotation drag` (28db13a)
- `feat(editor): make adjust mode tool-agnostic and add per-mark action chrome` (cb1fb71)
- `feat(editor): add marker, arrow curving, rotation handles, drag-handle button` (4e6749f)
- `feat(editor): add arrow endpoint handles and smooth pen strokes` (c1074fb)
- `feat(editor): add curve handle to numbered badge arrow` (5c3d409)
- `feat(editor): add hover tooltips, redo, and color picker to toolbar` (ee60c62)
- `feat(editor): allow moving and deleting mosaic annotations` (feb1cec)
- `feat(editor): adjust text size and color from sub-toolbar without entering edit mode` (6bca838)
- `feat(editor): keep selection adjustable while beautify is on` (26b73ef)
- `feat(editor): defer text editor open to mouseUp on empty canvas` (25578f0)
- `feat(editor): defer number creation to mouseUp and allow drag-to-reposition` (78fb983)
- `feat(editor): add #D77757 swatch and enable standard editing shortcuts in text field` (080b14f)

### Fixed
- `fix(capture): use display-local rect for sourceRect on extended screens` (cf29578)
- `fix(capture): redraw selection handles after drag or adjust` (7176480)
- `fix(menu): show both ⌘ glyphs for double-tap default hotkey` (24eabb1)
- `fix(settings): refresh upload pane labels on language change` (15c69e8)
- `fix(settings): enable copy/paste in upload provider input fields` (61de00a)
- `fix(editor): allow re-editing committed text annotations` (45ed35f)
- `fix(editor): stabilize text annotation edit and drag flow` (3a43a4a)
- `fix(editor): dismiss annotation chrome on empty-canvas click in adjust mode` (a66c06c)
- `fix(editor): tighten text selection box and contrast numbered badge digit` (46f1d12)
- `fix(editor): apply rotation when compositing annotations into exported image` (1ee3852)
- `fix(editor): move numbered tip stub above badge and add color picker for numbered tool` (601269a)
- `Fix text annotation editing` (dc1a289)

### Changed
- `build: ship universal arm64+x86_64 binary for Intel Mac support` (81991fe)

### Documentation
- `docs: rewrite README to cover full feature set` (4415659)

## [1.0.4] - 2026-04-19

### Added
- `feat(history): cache recent screenshots with thumbnail submenu` (4072ccb)
- `feat(settings): add launch-at-login option` (a529237)
- `feat(beautify): add wallpaper background preset and enhance floating shadow` (6ce2d6e)

### Fixed
- `fix(beautify): preserve Retina resolution in composite output` (b982ea9)

## [1.0.3] - 2026-04-10

### Added
- `feat(beautify): wire padding slider into editor controller` (6fe72ba)

### Changed
- `Add Chinese README and Gatekeeper workaround` (4dc83fa)

## [1.0.2] - 2026-04-10

### Added
- `feat(beautify): add BeautifyPreset model and persistence` (526eb86)
- `feat(beautify): add BeautifyRenderer for gradient + frame composition` (eec7abc)
- `feat(beautify): track beautify state and inner size in EditCanvasView` (2dfe529)
- `feat(beautify): render live beautify frame in EditCanvasView.draw` (94be4a0)
- `feat(beautify): wrap compositeImage output through BeautifyRenderer` (282ffa3)
- `feat(beautify): add BeautifySubToolbar and swatch view` (34a974e)
- `feat(beautify): wire beautify toolbar button and sub-toolbar` (a02d0ec)
- `feat(defaults): add lastBeautifyPadding with 8-56 clamp` (0add830)
- `feat(beautify): add slider constants and explicit-padding render` (8b8a406)
- `feat(beautify): honor customPadding override in container layout` (7044dd8)
- `feat(beautify): thread explicit padding through compositeImage` (7138f6e)
- `feat(beautify): add horizontal padding slider to sub-toolbar` (066664e)

### Fixed
- `fix(beautify): show inner screenshot in live preview and scale padding` (5a601ab)
- `fix(beautify): wrap canvas in BeautifyContainerView so tools keep working` (77842c5)
- `fix(beautify): keep beautify live when picking a tool, round long screenshots` (279784e)

### Changed
- `Add compile-check script and update build instructions` (8bee722)
- `Add Homebrew cask distribution support` (016a535)

### Documentation
- `docs: add screenshot beautify feature design spec` (9101318)
- `docs: add screenshot beautify implementation plan` (68aa5ac)
- `docs(beautify): add padding slider design spec` (ff0ee4c)
- `docs(beautify): add padding slider implementation plan` (cac8b03)

## [1.0.1] - 2026-04-09

### Added
- GitHub Actions release workflow: universal macOS `.app` build on `release-v*` tags, auto-publishes GitHub Release with artifact. (d6710ed)
- `CHANGELOG.md` scaffold following Keep a Changelog. (d6710ed)

### Changed
- Bump app version to `1.0.1` (from `1.0`).

## [0.1.0] - 2026-04-09

### Added
- Initial release.
