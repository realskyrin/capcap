# capcap

macOS menu bar screenshot tool. Pure AppKit, Swift Package Manager, no third-party dependencies.

## Build & Run

After each completed code change, build, install, and run the app:

```bash
bash scripts/rebuild-and-open.sh
```

This script builds the app bundle, replaces the installed app, launches it, and
confirms the process started. Run it once after the final edit in a related set
of changes, and rerun it if code or resources change afterward. Documentation-only
changes do not require an app restart.

Do not run `scripts/compile-check.sh`, `swift test`, other test commands, or
interactive UI checks unless the user explicitly requests testing or UI
verification. Launching the app confirms startup only; do not claim that the
changed behavior was tested. After the app starts, hand off the result.

## Interactive UI Testing (Only When Explicitly Requested)

capcap is an `LSUIElement` menu-bar app, so the macOS frontmost application is
often ChatGPT, Terminal, Finder, or another unrelated app even while a capcap
panel is visible. Do not infer the UI automation target from the frontmost app.
If the user explicitly requests interactive UI testing, use this workflow:

1. Ensure the installed app matches the current source and resources, following
   Build & Run above. Reuse an already current build.
2. Confirm that the intended capcap surface exists before sending input:

   ```bash
   /Applications/capcap.app/Contents/MacOS/capcap agent windows \
     --owner capcap --all --pretty
   ```

   `capcap agent` is off by default. If it exits with code 77
   (`agent_disabled`), ask the user to turn on Agent Command Line in
   Settings > Permissions instead of writing the preference yourself.

   Verify `ownerName`, `ownerPID`, window frame, and layer. A shallow
   Accessibility tree is normal for custom AppKit panels and is not evidence
   that another app should be targeted.
3. Lock every state read and UI action to `/Applications/capcap.app` using the
   current tool's documented app-targeting API. Do not begin with a generic
   frontmost app, reuse another app's element index, or operate
   ChatGPT/Terminal/Finder to bring capcap forward. Use app discovery only if
   targeting the exact path fails.
4. When the next action depends on UI state or element location, use fresh state.
   If the previous action already returned sufficient current state, no extra
   read is needed. Reacquire elements after rebuilds, relaunches, panel
   transitions, or layout changes.
5. Follow the current tool documentation for initialization, key syntax, and
   available pointer actions.

Dragging holds the mouse button and must not be treated as proof that ordinary
`mouseMoved`, `mouseEntered`, or hover behavior works. Verify hover-sensitive behavior with
real pointer movement when possible. If existing entry points cannot reach a
panel or hover state whose observation is necessary for this task's acceptance,
you may add a narrowly scoped `#if DEBUG` launch argument or keyboard hook.
Follow Build & Run, use the hook only to isolate the relevant behavior,
then remove it before final verification.
Search for the unique hook name afterward so temporary test code cannot ship.

When interactive UI testing is explicitly requested, final verification must
use the clean installed app after all debug hooks have been removed, following
Build & Run above. Reuse checks only if they cover this final state. Treat
incomplete Computer Use observations as a limitation, not as proof that an
`LSUIElement` surface passed or failed.

## Project Structure

- `capcap/App/` — Entry point (`main.swift`, `AppDelegate.swift`, `Info.plist`)
- `capcap/Capture/` — Screen capture logic (ScreenCaptureKit, selection overlay)
- `capcap/Editor/` — Post-capture annotation editor
- `capcap/Trigger/` — Double-tap ⌘ key detection
- `capcap/UI/` — Status bar, toast, cursor chip
- `capcap/Settings/` — Settings dialog (startup + preferences)
- `capcap/Utilities/` — UserDefaults wrapper
- `scripts/` — Build and bundle scripts

## Key Rules

- No SwiftUI — this project uses AppKit exclusively with programmatic UI.
- No storyboards or XIBs.
- Minimum deployment target: macOS 14.0.
- All newly added user-facing copy must not end with punctuation. Punctuation
  inside the sentence is fine, but the final character of every visible string,
  tooltip, alert, toast, menu item, placeholder, and localized value must not be
  punctuation.

## Packaging Lessons

- SwiftPM target resources are not automatically present in the hand-assembled
  `.app` bundle. When adding or changing resource declarations, resource bundles,
  or packaging paths, check both `scripts/bundle.sh` and the release workflow.
  Update missing copy logic so the generated `<package>_<target>.bundle` reaches
  `capcap.app/Contents/Resources/`.
- Treat a missing SwiftPM resource bundle as a release-blocking error, not a
  runtime fallback. The failure may only surface when a UI path first touches
  `Bundle.module`, such as the PermissionFlow authorization panel.
- When the user explicitly requests packaging or release verification, check the
  final `.app` contents directly with
  `find build/capcap.app/Contents/Resources -maxdepth 2 -name '*.bundle'` and,
  for release builds, confirm the universal app still contains both `arm64` and
  `x86_64` slices.

## Hotspot Ownership

Apply Build & Run above to changes in these files.

- `capcap/Editor/EditWindowController.swift` owns editor session wiring,
  toolbar callbacks, scroll capture, crop mode, and output actions. Keep tool
  state changes paired with toolbar/sub-toolbar updates.
- `capcap/Editor/EditCanvasView.swift` owns annotation state, mouse handling,
  selection chrome, undo/redo, and export compositing. Preserve value-typed
  annotation mutation and snapshot-based undo.
- `capcap/Editor/Annotations.swift` owns annotation model structs and drawing
  behavior. Keep drawing and hit-testing logic together for each annotation
  type.
- `capcap/Settings/SettingsView.swift` owns the settings window and preference
  controls. Keep persisted defaults in `Defaults.swift` aligned with visible
  controls and localized strings.
- `capcap/Translation/OCRTranslatePanel.swift` owns OCR/translation result
  presentation and provider interaction. Keep translation latency work off the
  main actor except for UI updates.
- `capcap/Capture/PinLauncher.swift` owns pinned-image window behavior,
  toolbar visibility, drag/resize behavior, and zoom interaction. Keep hover
  affordances and the above/below-100% drag model stable.
- `capcap/Utilities/Defaults.swift` owns persisted preferences and localized
  string accessors. Keep new settings normalized at the persistence boundary and
  add matching keys to every `Resources/*.lproj/Localizable.strings` file.
- `capcap/Settings/UploadSettingsPane.swift` owns image-host provider settings.
  Keep provider-specific validation, default-provider selection, and stored
  credentials isolated to this settings surface and `Defaults.swift`.
- `capcap/Trigger/HotkeyManager.swift` owns global shortcut registration and
  keyboard trigger dispatch. Keep shortcut recording, defaults, and active
  registration behavior aligned with Settings.

## Adding an Editor Tool

Whenever a new annotation/editor tool is added, it MUST also be wired into the
toolbar — a tool that isn't in `ToolbarLayout` never appears for the user.
Checklist:

- Add the `ToolbarItemID` case and update `editTool`, `symbolName`, `tooltip`,
  and the `kind` switch in `ToolbarLayout.swift`.
- Add the case to **both** `ToolbarLayout.canonicalOrder` and the `default`
  layout's `primary`/`side`/`hidden` buckets. A tool missing from
  `canonicalOrder` is invisible even though the enum case exists.
- Add the `tipXxx` localization key to `Defaults.swift` and to every
  `Resources/*.lproj/Localizable.strings` file.
- Use the user's specified toolbar position. Otherwise, follow the layout of
  similar tools and explain the choice. Ask only when the position involves an
  important product tradeoff that cannot be inferred from the existing layout
  or task context.
