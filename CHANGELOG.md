# Changelog

All notable changes to **capcap** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
