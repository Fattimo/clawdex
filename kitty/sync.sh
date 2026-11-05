#!/bin/sh
# Keep ~/.config/kitty in step with the versioned copy in this directory.
#
#   kitty/sync.sh          show differences (repo vs live)
#   kitty/sync.sh push     copy repo files into the live kitty config
#   kitty/sync.sh pull     copy live edits of tracked files back into the repo
#
# Only files already tracked here are touched. Restart kitty after a push that
# changes tab_bar.py; it keeps the tab bar module loaded until then.
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
LIVE="${KITTY_CONFIG_DIRECTORY:-$HOME/.config/kitty}"

tracked() {
  (cd "$REPO" && find . -type f ! -name sync.sh ! -name README.md ! -name '.*' | sed 's|^\./||' | sort)
}

case "${1:-diff}" in
  diff)
    status=0
    for f in $(tracked); do
      if [ ! -e "$LIVE/$f" ]; then echo "only in repo: $f"; status=1
      elif ! cmp -s "$REPO/$f" "$LIVE/$f"; then diff -u "$LIVE/$f" "$REPO/$f" || true; status=1
      fi
    done
    [ "$status" -eq 0 ] && echo "kitty config in sync"
    exit "$status" ;;
  push)
    for f in $(tracked); do
      mkdir -p "$(dirname "$LIVE/$f")"
      cmp -s "$REPO/$f" "$LIVE/$f" 2>/dev/null || { cp "$REPO/$f" "$LIVE/$f"; echo "pushed $f"; }
    done ;;
  pull)
    for f in $(tracked); do
      [ -e "$LIVE/$f" ] || continue
      cmp -s "$REPO/$f" "$LIVE/$f" || { cp "$LIVE/$f" "$REPO/$f"; echo "pulled $f"; }
    done ;;
  *) echo "usage: $0 [diff|push|pull]" >&2; exit 2 ;;
esac
