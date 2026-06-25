#!/bin/bash
# Removes Notch AI Control and its Claude Code hooks.
set -euo pipefail

HOOK_BIN="$HOME/.notch-ai-control/bin/notch-hook"
SETTINGS="$HOME/.claude/settings.json"

echo "▸ Quitting app…"
killall NotchAIControl >/dev/null 2>&1 || true
# The Claude Desktop watcher self-exits once the app is gone, but stop it now too.
pkill -f "notch-hook desktop" >/dev/null 2>&1 || true

echo "▸ Removing app + hook helper…"
rm -rf "$HOME/Applications/NotchAIControl.app"
rm -rf "$HOME/.notch-ai-control/bin"

if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
    echo "▸ Removing notch-hook entries from ${SETTINGS}…"
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
    jq '
      def clean($event):
        if (.hooks[$event]?) then
          .hooks[$event] |= map(select(any(.hooks[]?; .command | test("notch-hook")) | not))
        else . end;
      clean("SessionStart") | clean("UserPromptSubmit") | clean("PreToolUse")
      | clean("PostToolUse") | clean("Notification") | clean("Stop") | clean("SessionEnd")
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ] && grep -q "notch-hook" "$CODEX_CONFIG"; then
    echo "▸ Removing Codex notify entry from ${CODEX_CONFIG}…"
    cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%s)"
    sed -i '' -E '/^[[:space:]]*notify[[:space:]]*=.*notch-hook/d' "$CODEX_CONFIG"
fi

echo "✓ Uninstalled. Session data left in ~/.notch-ai-control/sessions (delete manually if desired)."
