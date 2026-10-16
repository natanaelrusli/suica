#!/bin/sh
# One-time move from the MR Review Assistant paths to the Suica paths.
# Safe to run twice: a second run prints "already migrated" and changes nothing.
set -eu

OLD_NAME=mr-review-assistant
OLD_LABEL=com.madhani.mr-review-assistant

if [ -n "${MRA_CONFIG:-}" ]; then
  echo "warning: MRA_CONFIG is set; rename it to SUICA_CONFIG"
fi

# 1. Stop the old LaunchAgent and the old menu bar app.
launchctl bootout "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1 || true
osascript -e "tell application id \"$OLD_LABEL.menubar\" to quit" >/dev/null 2>&1 || true

# 2. Wait up to 5 s for them to exit; refuse before moving anything if one remains.
running_pids() {
  pgrep -f "mr-review-assistant|MRAMenuBar" 2>/dev/null | tr '\n' ' ' || true
}
pids=$(running_pids)
waited=0
while [ -n "$pids" ] && [ "$waited" -lt 10 ]; do
  sleep 0.5
  waited=$((waited + 1))
  pids=$(running_pids)
done
if [ -n "$pids" ]; then
  echo "an old process is still running (pid ${pids% }): quit it and run this again" >&2
  exit 1
fi

# 3. Check every pair first, then move.
OLD_CONFIG="$HOME/.config/$OLD_NAME"
NEW_CONFIG="$HOME/.config/suica"
OLD_STATE="$HOME/Library/Application Support/$OLD_NAME"
NEW_STATE="$HOME/Library/Application Support/suica"
OLD_LOGS="$HOME/Library/Logs/$OLD_NAME"
NEW_LOGS="$HOME/Library/Logs/suica"

check_pair() {
  if [ -e "$1" ] && [ -e "$2" ]; then
    echo "both $1 and $2 exist: merge them by hand" >&2
    exit 1
  fi
}
check_pair "$OLD_CONFIG" "$NEW_CONFIG"
check_pair "$OLD_STATE" "$NEW_STATE"
check_pair "$OLD_LOGS" "$NEW_LOGS"

moved=0
move_pair() {
  if [ -e "$1" ]; then
    mkdir -p "$(dirname "$2")"
    mv "$1" "$2"
    moved=1
  fi
}
move_pair "$OLD_CONFIG" "$NEW_CONFIG"
move_pair "$OLD_STATE" "$NEW_STATE"
move_pair "$OLD_LOGS" "$NEW_LOGS"

# 4. Remove the old LaunchAgent plist and the old app bundle.
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
if [ -e "$HOME/Applications/MR Review Assistant.app" ]; then
  rm -r "$HOME/Applications/MR Review Assistant.app"
fi

# 5. Warn about explicit old paths in the moved config; the file is not edited.
CONFIG_FILE="$NEW_CONFIG/config.yaml"
if [ -f "$CONFIG_FILE" ]; then
  grep "$OLD_NAME" "$CONFIG_FILE" | while IFS= read -r line; do
    key=${line%%:*}
    key=${key#"${key%%[![:space:]]*}"}
    echo "warning: $CONFIG_FILE still names $OLD_NAME in: $key"
  done || true
fi

# 6. Report.
if [ "$moved" -eq 0 ]; then
  echo "already migrated"
else
  echo "migrated; now run scripts/install-launchagent.sh and scripts/install-macos-app.sh"
fi
