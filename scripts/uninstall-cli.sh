#!/bin/sh
# Stops and removes the background agent and the lessons hook and MCP registrations, then removes
# the installed CLI. The config, the state database and the logs stay.
set -eu

PREFIX=${SUICA_PREFIX:-$HOME/.local}
LIB="$PREFIX/lib/suica"
BIN="$PREFIX/bin/suica"

if [ -x "$BIN" ]; then
  "$BIN" agent uninstall
  # The lessons hook and MCP registrations point into $LIB; remove them while it still exists.
  "$BIN" lessons uninstall || echo "could not remove the lessons hook; run suica lessons uninstall before reinstalling" >&2
fi
rm -rf -- "$LIB"
rm -f -- "$BIN"
echo "removed $BIN and $LIB"
