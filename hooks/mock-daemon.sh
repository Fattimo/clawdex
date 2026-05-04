#!/bin/sh
# mock-daemon.sh — drop-in stand-in for the real Swift daemon.
# Listens on the same Unix socket and prints every line it receives.
# Used to test clawdex-hook without needing the macOS overlay built.

SOCK="${CLAWDEX_SOCK:-$HOME/.clawdex/sock}"
mkdir -p "$(dirname "$SOCK")"
rm -f "$SOCK"

echo "[mock-daemon] listening on $SOCK"
echo "[mock-daemon] press Ctrl-C to stop"
echo ""

# nc -lkU keeps the socket open across multiple connections (BSD nc on macOS
# supports -k since 10.13). Each line printed = one event from clawdex-hook.
exec nc -lkU "$SOCK"
