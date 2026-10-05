# Sidekick

A native macOS quick-answer panel (SwiftPM, macOS 15+, Swift 6.4) that runs the user's `claude` CLI. Public repo, MIT license (made public by Jonni on 2026-10-05). Releases are signed zips on this repo's GitHub releases, delivered by Sparkle through `appcast.xml` on `main`; `scripts/release.sh` makes them.

## Layout

- `Sources/SidekickCore`: everything that runs without a window. The claude process (`ClaudeProcess`), the stream-json parser, the session (`Conversation`), markdown blocks, springs, the daily reset, settings.
- `Sources/SidekickApp`: the panel (`PanelController`, `PanelView`, `AnswerView`), the menu bar item and hotkey (`AppDelegate`), Settings, and the window probe (`Probe`).
- `Sources/sidekick-checks`: plain checks for the core, against `scripts/fake-claude`, plus the update checks (`UpdateChecks.swift`).
- `appcast.xml`: the Sparkle feed, newest release first. Written by `scripts/release.sh`.
- `scripts/fake-claude`: a stand-in for `claude -p` with the same stream-json shapes. Behavior depends on the question (`slow`, `stubborn`, `tool`, `fail`, `crash`, `long`, `kitchen one`, `kitchen two`). The kitchen answers hold every markdown form the panel renders.

## Scripts

| Script | What it does | Safe on Jonni's Mac |
| --- | --- | --- |
| `scripts/test.sh` | Checks (171, about 11 s) and a compile of the app | Yes |
| `scripts/test.sh --vm` | Then builds the app and runs the window probe in the VM | Yes (the window part runs in the VM) |
| `$(swift build --show-bin-path)/sidekick-checks --live` | One real question through the real claude. Costs a few cents | Yes, no windows |
| `scripts/build-app.sh` | Release build into `build/Sidekick.app`, ad hoc signed | Yes |
| `scripts/vm-run.sh 'scripts/vm-test.sh worst'` | The break-ui pass: worst-case questions and answers (long paste, empty, blank, error, a 34K answer, 40 turns), screenshots and main-thread stall timings | Yes |
| `scripts/vm-run.sh 'scripts/vm-demo.sh'` | Records the README demo take (`Sidekick --demo`, fake-claude with `FAKE_CLAUDE_DEMO=1`): `build/vm-out/demo.mov` and full screen stills. The script header has the ffmpeg steps that make `assets/demo.gif` and `assets/screenshot-dark.png`, both a 16:9 crop at the top right. Sets the Resend wallpaper `8-c` in the VM first | Yes |
| `scripts/vm-run.sh ['cmd']` | Syncs the repo and the built app to the Tart VM on iris-agi and runs `scripts/vm-test.sh` (or `cmd`). Results land in `build/vm-out/` | Yes |
| `scripts/install.sh` | Builds, quits the running copy, installs to `/Applications`, starts it | Installs the real app |
| `scripts/release.sh X.Y.Z [--publish]` | Bumps the version, tests, builds, zips, signs the zip with the Sparkle key from 1Password and puts it first in `appcast.xml`. A dry run undoes the bump and keeps `build/appcast-preview.xml`; `--publish` commits, tags, pushes and creates the GitHub release | Dry run by default |
| `scripts/update-test.sh` | End to end update test: builds a 0.0.1 and a 0.0.2 test copy (bundle id `com.jonnilundy.sidekick.updatetest`, throwaway key, feed on `127.0.0.1:8765`), then runs `scripts/vm-update-test.sh` in the VM: gentle reminder with no window, Sparkle's window from the menu item's code path, silent download, install and relaunch. Prints `UPDATE TEST PASS: n checks` | Yes (runs in the VM) |
| `scripts/appcast-add.sh` | Puts one release first in an appcast (release.sh and the checks run it) | Yes |
| `swift scripts/ed-public-key.swift` | Reads a Sparkle private key on stdin, prints its public key (the `SUPublicEDKey` value) | Yes |
| `swift scripts/make-icon.swift [--sheet]` | Draws `assets/AppIcon.icns` (style `paper`), or a sheet of all styles | Yes |

## Test rules

1. Never run the app or the probe on Jonni's Mac. Anything that opens a window or takes focus runs in the VM through `scripts/vm-run.sh`.
2. The probe (`Sidekick --probe out`) drives the real panel with real key events against `fake-claude`, prints `PROBE PASS: n checks`, saves a screenshot per state and records `out/probe.mov`. Review motion by pulling frames with ffmpeg from `build/vm-out/probe.mov`.
3. Parallel worktrees: set `VM_DIR=sidekick-<task>` so syncs do not collide. The VM screen is shared with Deck through the lock `~/vm-sync/.vm-gui.lock` on iris-agi; only the VM command holds it.
4. The VM screen often shows notification banners from other runs. They are noise in screenshots, not Sidekick bugs.

## Gotchas

- `makeKey()` activates the app even for a `.nonactivatingPanel` on macOS 26. The panel remembers the app that was in front and activates it again on hide (`PanelController.returnFocus`).
- The window is a fixed strip at the screen's right edge, full height, and never resizes: resizing in step with SwiftUI animations dropped frames, and a big shrink left the card undrawn. Outside the card the window sets `ignoresMouseEvents` from the pointer position (`PanelController.updatePointer`), so clicks reach the app underneath. The card slides on and off by offset only; the window clips it at the screen edge, so the slide never shows on a second display.
- Streaming stays smooth because text deltas are batched (30 per second, `Conversation.textBatchInterval`), `StreamingMarkdown` parses only the newly settled part and the tail, `BlockView` and `ListRow` are Equatable, and each inline regex runs only when its trigger character is present. `wantsShown` is the truth for show and hide decisions; `model.shown` follows a frame later.
- SwiftUI skips `withAnimation` completions when nothing changed on screen. `hide()` has a timed fallback.
- The input row always lays out at full card width and the card clips it while compact (220 pt). A field that wraps at the narrow width keeps that wrap after the card widens.
- `PanelModel.visibleFrom` hides earlier turns from view only; `Conversation.turns` keeps them all. The grabber decides open or close with `HistoryDrag.outcome` (projection at the 0.99 rate).
- `scripts/vm-test.sh` stops Notification Center for the run (banners cover the top right) and starts it again on exit.
- An app without a main menu gets no Edit menu, so the panel maps ⌘X/C/V/A/Z itself.
- claude in stream-json mode runs SessionStart hooks before the first message and sends `system/init` only after it. Any `system` line counts as "process is up".
- An interrupt (`control_request` subtype `interrupt`) ends the turn with `is_error: true` and `result: null`; the session survives.
- The built app needs `KeyboardShortcuts_KeyboardShortcuts.bundle` in `Contents/Resources`, or it stops at launch.
- Updates: Sparkle.framework goes into `Contents/Frameworks` and is signed inside out (build-app.sh). A scheduled check never shows a window (`standardUserDriverShouldHandleShowingScheduledUpdate` returns false); it sets `UpdateState.available`, which draws the badge and the menu item. `SUPublicEDKey` set to `REPLACE-WITH-PUBLIC-KEY` keeps the updater off. The signing key is `op://Iris Agi/Sidekick Sparkle EdDSA key/credential`; a lost key means installed copies cannot update.
- Test copies (any bundle id but the release one) listen for the distributed notifications `<id>.install-update` and `<id>.dump-update-state`. The menu bar icon has its own window (`NSStatusBarWindow`, title "Item-0"); the state dump leaves it out.
- In the VM test scripts (zsh), `log` is a zsh builtin. Use `/usr/bin/log stream`. The test feed's Python server brings up a "find devices on local networks" prompt in the VM; it is noise in the screenshots.
