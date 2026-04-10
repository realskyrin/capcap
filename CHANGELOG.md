# Changelog

All notable changes to **capcap** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
