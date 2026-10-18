#!/bin/sh
# Stops and removes the background agent, then removes the installed CLI. The config, the state
# database and the logs stay.
set -eu

PREFIX=${SUICA_PREFIX:-$HOME/.local}
LIB="$PREFIX/lib/suica"
BIN="$PREFIX/bin/suica"

if [ -x "$BIN" ]; then
  "$BIN" agent uninstall
fi
rm -rf -- "$LIB"
rm -f -- "$BIN"
echo "removed $BIN and $LIB"
