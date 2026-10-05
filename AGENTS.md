# Sidekick

A native macOS quick-answer panel (SwiftPM, macOS 15+, Swift 6.4) that runs the user's `claude` CLI. Private repo. It runs Claude Code on the user's own login, so builds are for Jonni only: releases go to this private repo's GitHub releases, never anywhere public.

## Layout

- `Sources/SidekickCore`: everything that runs without a window. The claude process (`ClaudeProcess`), the stream-json parser, the session (`Conversation`), markdown blocks, springs, the daily reset, settings.
- `Sources/SidekickApp`: the panel (`PanelController`, `PanelView`, `AnswerView`), the menu bar item and hotkey (`AppDelegate`), Settings, and the window probe (`Probe`).
- `Sources/sidekick-checks`: plain checks for the core, against `scripts/fake-claude`.
- `scripts/fake-claude`: a stand-in for `claude -p` with the same stream-json shapes. Behavior depends on the question (`slow`, `stubborn`, `tool`, `fail`, `crash`, `long`, `kitchen one`, `kitchen two`). The kitchen answers hold every markdown form the panel renders.

## Scripts

| Script | What it does | Safe on Jonni's Mac |
| --- | --- | --- |
| `scripts/test.sh` | Checks (142, about 10 s) and a compile of the app | Yes |
| `scripts/test.sh --vm` | Then builds the app and runs the window probe in the VM | Yes (the window part runs in the VM) |
| `$(swift build --show-bin-path)/sidekick-checks --live` | One real question through the real claude. Costs a few cents | Yes, no windows |
| `scripts/build-app.sh` | Release build into `build/Sidekick.app`, ad hoc signed | Yes |
| `scripts/vm-run.sh ['cmd']` | Syncs the repo and the built app to the Tart VM on iris-agi and runs `scripts/vm-test.sh` (or `cmd`). Results land in `build/vm-out/` | Yes |
| `scripts/install.sh` | Builds, quits the running copy, installs to `/Applications`, starts it | Installs the real app |
| `scripts/release.sh X.Y.Z [--publish]` | Bumps the version, tests, zips; with `--publish` tags and creates a GitHub release | Dry run by default |
| `swift scripts/make-icon.swift [--sheet]` | Draws `assets/AppIcon.icns` (style `paper`), or a sheet of all styles | Yes |

## Test rules

1. Never run the app or the probe on Jonni's Mac. Anything that opens a window or takes focus runs in the VM through `scripts/vm-run.sh`.
2. The probe (`Sidekick --probe out`) drives the real panel with real key events against `fake-claude`, prints `PROBE PASS: n checks`, saves a screenshot per state and records `out/probe.mov`. Review motion by pulling frames with ffmpeg from `build/vm-out/probe.mov`.
3. Parallel worktrees: set `VM_DIR=sidekick-<task>` so syncs do not collide. The VM screen is shared with Deck through the lock `~/vm-sync/.vm-gui.lock` on iris-agi; only the VM command holds it.
4. The VM screen often shows notification banners from other runs. They are noise in screenshots, not Sidekick bugs.

## Gotchas

- `makeKey()` activates the app even for a `.nonactivatingPanel` on macOS 26. The panel remembers the app that was in front and activates it again on hide (`PanelController.returnFocus`).
- The card slides with SwiftUI springs inside a window flush with the screen's right edge, so the slide never shows on a second display. `wantsShown` is the truth for show and hide decisions; `model.shown` follows a frame later.
- SwiftUI skips `withAnimation` completions when nothing changed on screen. `hide()` has a timed fallback.
- The input row always lays out at full card width and the card clips it while compact (220 pt). A field that wraps at the narrow width keeps that wrap after the card widens.
- `PanelModel.visibleFrom` hides earlier turns from view only; `Conversation.turns` keeps them all. The grabber decides open or close with `HistoryDrag.outcome` (projection at the 0.99 rate).
- `scripts/vm-test.sh` stops Notification Center for the run (banners cover the top right) and starts it again on exit.
- An app without a main menu gets no Edit menu, so the panel maps ⌘X/C/V/A/Z itself.
- claude in stream-json mode runs SessionStart hooks before the first message and sends `system/init` only after it. Any `system` line counts as "process is up".
- An interrupt (`control_request` subtype `interrupt`) ends the turn with `is_error: true` and `result: null`; the session survives.
- The built app needs `KeyboardShortcuts_KeyboardShortcuts.bundle` in `Contents/Resources`, or it stops at launch.
