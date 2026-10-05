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

## Settings

- **Shortcut.** Default ⌥⌘Space.
- **Folder.** Where claude runs. Default `~/Workbench/work` if it exists, else your home folder.
- **Model and effort.** Default: your Claude Code model, low effort (fastest). The model names always run the newest model of each family; Settings shows which one gave the last answer.
- **Start fresh every day at 5 AM.** On by default.
- **Keep Claude ready.** One claude process waits in the background, so the first answer starts about 2 seconds sooner.
- **Open at login.**

## How it works

- One `claude -p --input-format stream-json --output-format stream-json --no-session-persistence` process per session. Questions go in on stdin; text streams back.
- A spare process starts ahead of time, so asking skips Claude Code's startup.
- An app started at login gets a bare environment, so Sidekick reads your login shell's environment once (`$SHELL -lic env`) and passes it to claude. Hooks and MCP servers then find their tools and tokens.
- The prompt Sidekick adds is in `Sources/SidekickCore/ClaudeCommand.swift`.

## Develop

See [AGENTS.md](AGENTS.md) for the scripts and the test rules.
