# Sidekick

A quick-answer panel for Claude on your Mac. Press ⌥⌘Space, ask, read the answer, press Esc. Nothing else.

Sidekick runs your own `claude` command, so it has your setup: your CLAUDE.md, skills, connectors, hooks and login. It answers in a line or three, then at most a few "worth knowing" bullets.

## Install

```sh
scripts/install.sh
```

This builds the app, installs it to `/Applications/Sidekick.app` and starts it. On the first start it turns on Open at Login and opens the panel once.

You need Claude Code installed and logged in (`claude` in Terminal works).

## Use

| Do this | To |
| --- | --- |
| ⌥⌘Space, or click ✦ in the menu bar | Open or close the panel |
| Return | Ask |
| Esc, ⌘W, or click another app | Put it away (the session stays) |
| ⌘N, or the ↺ button | Reset: start a fresh session |
| ⌘. | Stop the answer |
| ⇧⌘C | Copy the last answer |
| ⌘, or right-click ✦ | Settings |

While an answer runs, the panel stays up. If you put it away, it comes back when the answer is done, without taking your keyboard.

One session runs all day, so follow-ups know the earlier questions. It resets at 5 AM. Nothing is saved to disk.

After 3 minutes without activity, the panel opens as just the empty field, half width. The session keeps every turn: hover on the bottom edge of the card and drag down to pull the earlier questions back into view, or drag up to tuck them away.

## Settings

- **Shortcut.** Default ⌥⌘Space.
- **Folder.** Where claude runs. Default `~/Workbench/work` if it exists, else your home folder.
- **Model and effort.** Default: your Claude Code model, low effort (fastest). The model names always run the newest model of each family; Settings shows which one gave the last answer.
- **Start fresh every day at 5 AM.** On by default.
- **Keep Claude ready.** One claude process waits in the background, so the first answer starts about 2 seconds sooner.
- **Open at login.**
- **Updates.** Your version, Check Now with the result of the last check, and Check for updates automatically (on by default).

## Updates

Sidekick updates itself with [Sparkle](https://sparkle-project.org). It checks once a day, plus right after launch when a check is due.

- A found update never opens a window or takes the keyboard. A dot appears on ✦ in the menu bar, and the right-click menu gets **Update to Sidekick X.Y.Z…** at the top.
- That item, **Check for Updates…** in the same menu, or Check Now in Settings opens Sparkle's window: the release notes, then Install Update, the download, and Install and Relaunch.
- If you tick "Automatically download and install updates" in that window, later updates download in the background. The menu item then says **Install Sidekick X.Y.Z and Relaunch** and installs at once. An update that is not installed by hand installs when Sidekick quits.

The feed is `appcast.xml` at the root of this repo, read from `main`. The zips are on the repo's GitHub releases. Every zip is signed with an EdDSA key, and Sidekick installs only zips that match the public key in its Info.plist. `scripts/release.sh` makes a release (see [AGENTS.md](AGENTS.md)).

## How it works

- One `claude -p --input-format stream-json --output-format stream-json --no-session-persistence` process per session. Questions go in on stdin; text streams back.
- A spare process starts ahead of time, so asking skips Claude Code's startup.
- An app started at login gets a bare environment, so Sidekick reads your login shell's environment once (`$SHELL -lic env`) and passes it to claude. Hooks and MCP servers then find their tools and tokens.
- The prompt Sidekick adds is in `Sources/SidekickCore/ClaudeCommand.swift`.

## Develop

See [AGENTS.md](AGENTS.md) for the scripts and the test rules.
