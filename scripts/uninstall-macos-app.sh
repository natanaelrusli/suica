#!/bin/sh
# Quits the menu bar app and removes its bundle.
set -eu

BUNDLE_ID=com.madhani.suica
APP="$HOME/Applications/Suica.app"

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
if [ -d "$APP" ]; then
  rm -r -- "$APP"
  echo "removed $APP"
else
  echo "not installed: $APP"
fi
