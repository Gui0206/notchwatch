# Notch AI Control

Watch your AI coding agents from your MacBook notch.

When idle, your notch looks completely normal. **Hover it** and it springs open
into a panel showing every active **Claude Code**, **Claude Desktop**, and
**OpenAI Codex** session — what each is doing, whether it's **working**,
**waiting for you**, or **done** — across as many projects as you have running.
**Click a row** to jump straight to the window (VS Code, Cursor, iTerm, Terminal,
Claude Desktop…) that session is running in.

```
  closed:   (nothing drawn — the notch looks stock)

  hover ▾
        ╭──────────────  ◯ notch  ──────────────╮
        │  ● api-server         claude   $ npm test          2m 04s │
        │  ● notch_ai_control   codex    Refactored auth + tests   8s │
        ╰────────────────────────────────────────────────────────────╯
            ●  blue = working   ● amber = needs you   ● green = done
```

- A chime plays when a session **finishes**; a different tone when one **needs you**.
- Multiple sessions are sorted with "needs you" first.
- No special permissions required (no screen recording, accessibility, etc.).

---

## Requirements

- A **Mac with a notch** (MacBook Pro 14"/16", MacBook Air M2+) running **macOS 14+**.
- **Xcode 16+** or the matching **Command Line Tools** (provides a Swift 6 toolchain).
  Check with `swift --version` (should report Swift 6.x).
- **[`jq`](https://jqlang.github.io/jq/)** — used to safely merge the Claude Code
  hook config. Install with `brew install jq`.
- Whatever agents you want to track: **Claude Code** and/or **OpenAI Codex**.

## Quick start

```bash
git clone <this-repo> notch_ai_control
cd notch_ai_control
brew install jq          # if you don't have it
./install.sh
```

`install.sh` builds everything, installs the app to `~/Applications`, and wires
up both agents (details below). Then:

- **Claude Code:** open a **new** session (hooks load at startup) and start working.
- **Codex:** just run `codex` — the `notify` hook is already configured.

Hover your notch to watch them. Optionally enable **Start at Login** from the
menu-bar **✦** icon so it's always running.

> First launch: the app is ad-hoc signed locally, so Gatekeeper won't normally
> complain. If it ever does, right-click `~/Applications/NotchAIControl.app` →
> **Open** once.

## Using it

- **Hover** the notch → expands. **Move away** → collapses.
- **Click a row** → focuses the editor/terminal window for that session.
- **Hover a row** → an `×` appears to dismiss it.
- **Menu-bar ✦ icon** → Show Panel · Clear Finished · Play Sounds · Start at Login · Quit.
- **Stop the app:** ✦ → Quit, or `killall NotchAIControl`.

## How it works

Two pieces, decoupled by a folder of status files (`~/.notch-ai-control/sessions/`):

1. **`NotchAIControl.app`** — a tiny accessory app (no Dock icon) that draws over
   the notch and live-renders whatever status files exist.
2. **`notch-hook`** — a CLI the agents call to write those status files.

### Claude Code

`install.sh` merges hooks into `~/.claude/settings.json` (existing hooks are kept;
a timestamped backup is saved):

| Claude Code hook   | Shown as            |
|--------------------|---------------------|
| `SessionStart`     | Idle                |
| `UserPromptSubmit` | Working — "Thinking…" |
| `PreToolUse`       | Working — "Editing main.swift", "$ npm test", … |
| `Notification`     | **Needs you** (permission / input) |
| `Stop`             | **Done** — "Finished" |
| `SessionEnd`       | session removed     |

### OpenAI Codex

`install.sh` registers `notch-hook` in `~/.codex/config.toml`:

```toml
notify = ["~/.notch-ai-control/bin/notch-hook", "codex"]
```

Codex fires `notify` on **agent-turn-complete**, so a Codex session shows as
**Done** with its last message when a turn finishes (and plays the chime).
Concurrent Codex runs appear as separate rows.

### Claude Desktop

Claude Desktop has no hook or `notify` mechanism, but its local **agent / cowork**
sessions run Claude Code under the hood and write a structured, append-only event
log on disk:

```
~/Library/Application Support/Claude/local-agent-mode-sessions/…/local_<id>/audit.jsonl
```

The app spawns a small background watcher (`notch-hook desktop`) that **tails
those logs** and republishes each active session as a status file — so it needs
**no setup, no MCP server, and no extra permissions**. It maps:

| Claude Desktop audit event              | Shown as                              |
|-----------------------------------------|---------------------------------------|
| user prompt / `status: requesting`      | Working — "Thinking…"                 |
| assistant `tool_use` (Bash, Edit, …)    | Working — "$ npm test", "Editing …"   |
| assistant `AskUserQuestion`             | **Needs you** — the question text     |
| `result` (turn complete)                | **Done** — "Finished"                 |
| `rate_limit_event`                       | **Needs you** — "Rate limited"        |

The project label is the chat's **title**, and **clicking a row focuses Claude
Desktop**. Only live activity is surfaced — existing history is skipped on launch,
and the watcher self-exits when the app quits. (Codex still appears as its own
rows; this is separate.)

Because the UI only reads status files, **any tool** can drive it — write a JSON
file into the sessions dir using the schema below.

## Build without installing

```bash
./build_app.sh          # produces ./NotchAIControl.app (no install, no hooks)
swift build -c release  # just the two binaries
open ./NotchAIControl.app
```

## Uninstall

```bash
./uninstall.sh
```

Quits the app, removes it and `notch-hook`, and strips the `notch-hook` entries
from your Claude settings and Codex config (everything else untouched). Backups
are saved next to each config.

## Troubleshooting

- **Nothing shows when I hover** — that's correct when there are no active
  sessions. Start a Claude Code / Codex session, or test it:
  ```bash
  ~/.notch-ai-control/bin/notch-hook codex \
    '{"type":"agent-turn-complete","last-assistant-message":"hello from codex"}'
  ```
  A "Done" row should appear in your notch.
- **My existing Claude session doesn't appear** — hooks load at session start.
  Open a **new** Claude Code session.
- **App didn't start** — `open ~/Applications/NotchAIControl.app`, or rebuild with
  `./install.sh`.
- **Build fails** — confirm `swift --version` is 6.x (Xcode 16+ / `xcode-select --install`).

## Status file schema

`~/.notch-ai-control/sessions/<id>.json`:

```json
{
  "session_id": "abc123",
  "tool": "claude",                 // or "codex"
  "cwd": "/Users/me/code/api-server",
  "project": "api-server",
  "state": "working",               // idle | working | waiting | done | error
  "activity": "Editing main.swift",
  "started_at": 1780970000.0,
  "updated_at": 1780970120.0,
  "owner_bundle_id": "com.microsoft.VSCode",  // optional, for click-to-jump
  "owner_app_path": "/Applications/Visual Studio Code.app",
  "owner_name": "Visual Studio Code",
  "owner_kind": "vscode"
}
```

The app auto-marks long-silent `working` sessions as **stale** and auto-dismisses
`done` sessions after 15 minutes.

## Project layout

```
Package.swift
Sources/NotchAIControl/      # the app (Swift 6 / SwiftUI + AppKit)
  main.swift                 #   window, hover + click-through, menu bar, login item
  NotchView.swift            #   SwiftUI: notch shape, expand animation, rows
  SessionStore.swift         #   FSEvents watcher, state model, pruning, sounds
  Focuser.swift              #   click-to-jump (editor CLI / app activation)
  Sounds.swift               #   finish / needs-you chimes
Sources/notch-hook/          # the CLI the agents call
  main.swift                 #   Claude (stdin) + Codex (notify) modes
  Owner.swift                #   detects the owning terminal/editor app
build_app.sh  install.sh  uninstall.sh
```

Requires macOS 14+ and a Mac with a notch. Built with Swift 6 / SwiftUI + AppKit.
