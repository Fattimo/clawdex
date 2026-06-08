#!/bin/sh
# clawdex — uninstaller. Reverses install.sh:
#   - stops daemon, unloads launchd agent, removes plist
#   - removes CLI symlinks placed by install.sh
#   - strips clawdex hooks from ~/.claude/settings.json (preserves the rest)
#   - removes ~/.clawdex/ (hooks, logs, trail)
# Does NOT touch:
#   - ~/.codex/pets/ (your pets are yours)

set -e

CLAWDEX_HOME="${CLAWDEX_HOME:-$HOME/.clawdex}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/dev.clawdex.daemon.plist"
SETTINGS="$HOME/.claude/settings.json"

echo "==> Stopping daemon"
launchctl unload -w "$LAUNCH_AGENT" 2>/dev/null || true
pkill -x clawdexd 2>/dev/null || true

echo "==> Removing launchd plist"
rm -f "$LAUNCH_AGENT"

echo "==> Removing CLI symlinks"
for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.clawdex/bin"; do
  for name in clawdex clawdexd; do
    if [ -L "$dir/$name" ]; then
      target="$(readlink "$dir/$name")"
      case "$target" in
        */clawdex/.build/*|*/.clawdex/bin/*)
          rm "$dir/$name"
          echo "    removed $dir/$name"
          ;;
        *)
          echo "    skipped $dir/$name (symlink target $target is not a clawdex .build artifact)"
          ;;
      esac
    fi
  done
done

echo "==> Stripping hooks from $SETTINGS"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp)"
  jq '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(select(.command | test("clawdex-hook") | not))
        )
        | .value |= map(select(.hooks | length > 0))
      )
      | .hooks |= with_entries(select(.value | length > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
    | if (.statusLine.command // "") | test("clawdex-statusline") then del(.statusLine) else . end
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "    cleaned. (preserved any other keys you had)"
else
  echo "    jq not available — edit $SETTINGS by hand to remove the clawdex hook entries."
fi

echo "==> Removing $CLAWDEX_HOME"
rm -rf "$CLAWDEX_HOME"

echo ""
echo "✓ clawdex uninstalled."
echo ""
echo "Left alone (yours, not ours):"
echo "  ~/.codex/pets/                                 — your pet collection"
echo "  ~/.claude/settings.json                         — all other keys preserved"
