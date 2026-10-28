#!/bin/sh
# Replaces TARGET with STAGED once PID has exited, then opens it. Usage: swap-app.sh PID STAGED TARGET
# Without STAGED (already swapped, or never staged) it only opens TARGET.
set -eu
PID=$1
STAGED=$2
TARGET=$3
i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 60 ]; do
  sleep 0.5
  i=$((i + 1))
done
if [ -d "$STAGED" ]; then
  rm -rf "$TARGET"
  mv "$STAGED" "$TARGET"
fi
open "$TARGET"
