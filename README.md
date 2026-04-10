# capcap

A lightweight, native macOS screenshot tool that lives in your menu bar. Double-tap `⌘ Command` to capture any region of your screen — instantly copied to clipboard, or annotate first with pen and mosaic tools.

## Features

- **Instant Capture** — drag to select any area, screenshot goes straight to your clipboard
- **Built-in Editor** — annotate with a pen tool or pixelate sensitive info with mosaic before copying
- **Double-tap ⌘ to Trigger** — no awkward key combos, just double-tap Command
- **Multi-monitor Support** — works seamlessly across all connected displays
- **Retina Ready** — captures at full 2x resolution on HiDPI screens
- **Menu Bar App** — stays out of your way, no dock icon

## Capture Modes

| Mode | Flow |
|------|------|
| **Direct** | Select region → copied to clipboard |
| **Edit First** | Select region → annotate with pen/mosaic → copied to clipboard |

Switch between modes in Settings.

## Getting Started

### Requirements

- macOS 14.0+
- Accessibility permission (for hotkey detection)
- Screen Recording permission (for ScreenCaptureKit)

### Install with Homebrew

This repository now ships a Homebrew cask at `Casks/capcap.rb`.

Because the repository name is `capcap` rather than `homebrew-capcap`, tap it with an explicit URL:

```bash
brew tap realskyrin/capcap https://github.com/realskyrin/capcap
brew install --cask capcap
```

See [docs/homebrew.md](docs/homebrew.md) for the release/update workflow.

### Build

```bash
# Build and bundle into .app
./scripts/bundle.sh
```

The app bundle will be output to `build/capcap.app`.

### Run

Open `build/capcap.app` — a camera icon will appear in your menu bar.

## Usage

1. **Double-tap `⌘ Command`** (or click "Take Screenshot" from the menu bar)
2. **Drag** to select a region
3. Done — the screenshot is on your clipboard. Paste it anywhere.

In **Edit First** mode, a toolbar appears after selection with:
- **Pen** — draw annotations (red by default)
- **Mosaic** — pixelate areas to hide sensitive content
- **Confirm** — save to clipboard
- **Cancel** — discard

## Built With

Swift + AppKit + ScreenCaptureKit, packaged with Swift Package Manager. No third-party dependencies.

## License

MIT
