#!/bin/bash
# Installs Notch AI Control and wires it into Claude Code's hooks.
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchAIControl.app"
APP_DEST="$HOME/Applications/$APP"
HOOK_DIR="$HOME/.notch-ai-control/bin"
HOOK_BIN="$HOOK_DIR/notch-hook"
SETTINGS="$HOME/.claude/settings.json"

echo "▸ Building…"
./build_app.sh

echo "▸ Installing app to ${APP_DEST}…"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$APP" "$APP_DEST"

echo "▸ Installing hook helper to ${HOOK_BIN}…"
mkdir -p "$HOOK_DIR"
cp "$APP/Contents/Resources/notch-hook" "$HOOK_BIN"
chmod +x "$HOOK_BIN"

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required to merge Claude Code settings. Install with: brew install jq"
    echo "  App is installed; re-run after installing jq to wire up hooks."
    exit 1
fi

echo "▸ Wiring Claude Code hooks in ${SETTINGS}…"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

# Merge our hooks idempotently: for each event we drop any prior notch-hook
# entry, then append a fresh one. Existing unrelated hooks are preserved.
jq --arg hook "$HOOK_BIN" '
  def entry($matcher):
    if $matcher == "" then {hooks:[{type:"command", command:$hook}]}
    else {matcher:$matcher, hooks:[{type:"command", command:$hook}]} end;
  def strip($event):
    (.hooks[$event] // [])
    | map(select(any(.hooks[]?; .command == $hook) | not));
  .hooks = (.hooks // {})
  | .hooks.SessionStart     = (strip("SessionStart")     + [entry("")])
  | .hooks.UserPromptSubmit = (strip("UserPromptSubmit") + [entry("")])
  | .hooks.PreToolUse       = (strip("PreToolUse")       + [entry("*")])
  | .hooks.PostToolUse      = (strip("PostToolUse")      + [entry("*")])
  | .hooks.Notification     = (strip("Notification")     + [entry("")])
  | .hooks.Stop             = (strip("Stop")             + [entry("")])
  | .hooks.SessionEnd       = (strip("SessionEnd")       + [entry("")])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# --- OpenAI Codex (optional) ---
# Codex calls a `notify` program (configured in ~/.codex/config.toml) with a
# JSON event argument. We register notch-hook in "codex" mode.
CODEX_CONFIG="$HOME/.codex/config.toml"
NOTIFY_LINE="notify = [\"$HOOK_BIN\", \"codex\"]"
if command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then
    mkdir -p "$HOME/.codex"
    touch "$CODEX_CONFIG"
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%s)" 2>/dev/null || true
    if grep -qE '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG"; then
        if grep -q "notch-hook" "$CODEX_CONFIG"; then
            : # already wired
        else
            # Replace the existing notify line (old value is backed up above).
            sed -i '' -E "s|^[[:space:]]*notify[[:space:]]*=.*|$NOTIFY_LINE|" "$CODEX_CONFIG"
            echo "▸ Replaced existing Codex notify in $CODEX_CONFIG (backup saved)"
        fi
    else
        # Prepend so it's a top-level key (TOML keys after a [section] belong to it).
        tmp="$(mktemp)"; { printf '%s\n' "$NOTIFY_LINE"; cat "$CODEX_CONFIG"; } > "$tmp" && mv "$tmp" "$CODEX_CONFIG"
    fi
    echo "▸ Wired Codex notify in $CODEX_CONFIG"
    CODEX_NOTE="  • Codex notify wired in $CODEX_CONFIG"
else
    echo "▸ Codex not detected — skipping (install codex, then re-run ./install.sh)"
    CODEX_NOTE="  • Codex: not installed (re-run ./install.sh after installing it)"
fi

# --- Claude Desktop (automatic) ---
# Claude Desktop has no hooks, but its local "cowork" agent sessions write audit
# logs we can tail. The app spawns `notch-hook desktop` to watch them, so there's
# nothing to wire up — we just report whether Claude Desktop is present.
if [ -d "/Applications/Claude.app" ] || [ -d "$HOME/Applications/Claude.app" ]; then
    echo "▸ Claude Desktop detected — local agent sessions are tracked automatically."
    CLAUDE_DESKTOP_NOTE="  • Claude Desktop: tracked automatically (no setup)"
else
    echo "▸ Claude Desktop not detected — it'll be picked up automatically if installed later."
    CLAUDE_DESKTOP_NOTE="  • Claude Desktop: not installed (tracked automatically once it is)"
fi

echo "▸ Launching app…"
# Relaunch cleanly. (The desktop watcher is a child of the app and self-exits.)
killall NotchAIControl >/dev/null 2>&1 || true
open "$APP_DEST"

cat <<DONE

✓ Installed.

  • App:   $APP_DEST  (also added to login? run: see README)
  • Hook:  $HOOK_BIN
  • Claude Code hooks merged into $SETTINGS (backup saved alongside)
$CODEX_NOTE
$CLAUDE_DESKTOP_NOTE

Open a new Claude Code or Codex session and hover your notch.
To uninstall:  ./uninstall.sh
DONE
