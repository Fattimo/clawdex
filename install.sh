#!/bin/sh
# clawdex — installer. Wires the hook scripts into ~/.claude/settings.json,
# creates a launchd agent so the daemon starts at login, and prints the
# next-steps banner.
#
# Idempotent: safe to re-run. Will not stomp existing keys in your settings.json
# beyond the clawdex-managed ones.

set -e

CLAWDEX_HOME="${CLAWDEX_HOME:-$HOME/.clawdex}"
HOOKS_DIR="$CLAWDEX_HOME/hooks"
SETTINGS="$HOME/.claude/settings.json"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.clawdex.daemon.plist"
DAEMON_BIN="${CLAWDEX_DAEMON:-$(command -v clawdexd 2>/dev/null || true)}"

if [ -z "$DAEMON_BIN" ]; then
  if [ -x "$(dirname "$0")/.build/release/clawdexd" ]; then
    DAEMON_BIN="$(cd "$(dirname "$0")/.build/release" && pwd)/clawdexd"
  elif [ -x "$(dirname "$0")/.build/debug/clawdexd" ]; then
    DAEMON_BIN="$(cd "$(dirname "$0")/.build/debug" && pwd)/clawdexd"
  else
    echo "clawdex install: cannot find clawdexd binary on PATH or in .build/." >&2
    echo "Build first: swift build -c release" >&2
    exit 1
  fi
fi

echo "==> Installing clawdex hooks to $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"
cp "$(dirname "$0")/hooks/clawdex-hook"       "$HOOKS_DIR/"
cp "$(dirname "$0")/hooks/clawdex-statusline" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/clawdex-hook" "$HOOKS_DIR/clawdex-statusline"

echo "==> Wiring hooks into $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

# Merge with jq if available; otherwise print manual instructions.
if command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp)"
  jq --arg hook "$HOOKS_DIR/clawdex-hook" --arg statusline "$HOOKS_DIR/clawdex-statusline" '
    .hooks = (.hooks // {}) |
    .hooks.SessionStart     = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.UserPromptSubmit = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.PreToolUse       = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.PostToolUse      = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.Notification     = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.Stop             = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.SubagentStop     = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .hooks.PreCompact       = [{ "hooks": [{ "type": "command", "command": $hook }] }] |
    .statusLine             = { "type": "command", "command": $statusline }
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "    settings.json updated."
else
  echo "    jq not installed — merge hooks/settings.example.json into $SETTINGS manually,"
  echo "    replacing HOOKS_DIR with $HOOKS_DIR."
fi

echo "==> Installing launchd agent at $LAUNCH_AGENT"
mkdir -p "$(dirname "$LAUNCH_AGENT")"
cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>dev.clawdex.daemon</string>
  <key>ProgramArguments</key> <array><string>$DAEMON_BIN</string></array>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>$CLAWDEX_HOME/clawdexd.log</string>
  <key>StandardErrorPath</key><string>$CLAWDEX_HOME/clawdexd.log</string>
</dict>
</plist>
PLIST

launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
launchctl load -w "$LAUNCH_AGENT"

echo ""
echo "✓ clawdex installed."
echo "  Daemon binary:  $DAEMON_BIN"
echo "  Hooks:          $HOOKS_DIR"
echo "  Settings:       $SETTINGS"
echo "  Logs:           $CLAWDEX_HOME/clawdexd.log"
echo ""
echo "  Try:"
echo "    clawdex list          # see your pets"
echo "    clawdex wake          # show the pet"
echo "    clawdex tuck          # hide it"
echo "    npx petdex install noir-webling     # grab a sample pet"
