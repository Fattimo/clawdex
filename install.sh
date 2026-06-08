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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build from source if no binaries are present and we're inside a checkout.
# If clawdexd is already on PATH (e.g. a prior install), we reuse it.
if [ ! -x "$SCRIPT_DIR/.build/release/clawdexd" ] \
   && [ ! -x "$SCRIPT_DIR/.build/debug/clawdexd" ] \
   && ! command -v clawdexd >/dev/null 2>&1 \
   && [ -f "$SCRIPT_DIR/Package.swift" ]; then
  echo "==> Building clawdex (swift build -c release; ~30-60s first time)"
  (cd "$SCRIPT_DIR" && swift build -c release)
fi

DAEMON_BIN="${CLAWDEX_DAEMON:-$(command -v clawdexd 2>/dev/null || true)}"
if [ -z "$DAEMON_BIN" ]; then
  if [ -x "$SCRIPT_DIR/.build/release/clawdexd" ]; then
    DAEMON_BIN="$SCRIPT_DIR/.build/release/clawdexd"
  elif [ -x "$SCRIPT_DIR/.build/debug/clawdexd" ]; then
    DAEMON_BIN="$SCRIPT_DIR/.build/debug/clawdexd"
  else
    echo "clawdex install: cannot find clawdexd binary on PATH or in .build/." >&2
    exit 1
  fi
fi

CLI_BIN="${CLAWDEX_CLI:-$(command -v clawdex 2>/dev/null || true)}"
if [ -z "$CLI_BIN" ]; then
  if   [ -x "$SCRIPT_DIR/.build/release/clawdex" ]; then CLI_BIN="$SCRIPT_DIR/.build/release/clawdex"
  elif [ -x "$SCRIPT_DIR/.build/debug/clawdex"   ]; then CLI_BIN="$SCRIPT_DIR/.build/debug/clawdex"
  fi
fi

# Symlink the CLI into a writable PATH dir so `clawdex wake` works post-install.
# Skip if a CLI is already on PATH (e.g. a prior install).
if ! command -v clawdex >/dev/null 2>&1 && [ -n "$CLI_BIN" ]; then
  for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      ln -sf "$CLI_BIN"    "$candidate/clawdex"
      ln -sf "$DAEMON_BIN" "$candidate/clawdexd"
      LINKED_DIR="$candidate"
      break
    fi
  done
  if [ -z "$LINKED_DIR" ]; then
    mkdir -p "$HOME/.clawdex/bin"
    ln -sf "$CLI_BIN"    "$HOME/.clawdex/bin/clawdex"
    ln -sf "$DAEMON_BIN" "$HOME/.clawdex/bin/clawdexd"
    LINKED_DIR="$HOME/.clawdex/bin"
    echo "==> No writable PATH dir found. Linked to $LINKED_DIR."
    echo "    Add this to your shell rc:  export PATH=\"\$HOME/.clawdex/bin:\$PATH\""
  else
    echo "==> Linked clawdex / clawdexd into $LINKED_DIR"
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

# Friendly nudge if the user has no pets yet — they'll otherwise see nothing.
PET_COUNT=0
for root in "$HOME/.codex/pets" "$HOME/.clawdex/pets"; do
  [ -d "$root" ] && PET_COUNT=$((PET_COUNT + $(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')))
done

echo ""
if [ "$PET_COUNT" = "0" ]; then
  echo "  No pets installed yet. Browse the catalog at https://petdex.crafter.run"
  echo "  or grab one now:"
  echo ""
  echo "    npx petdex install noir-webling"
  echo ""
  echo "  Then:"
  echo "    clawdex wake"
else
  echo "  Try:"
  echo "    clawdex list   # $PET_COUNT pet(s) installed"
  echo "    clawdex wake   # show the pet"
  echo "    clawdex tuck   # hide it"
fi
