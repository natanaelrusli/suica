#!/bin/sh
# One-time move from the MR Review Assistant paths to the Suica paths.
# Safe to run twice: a second run prints "already migrated" and changes nothing.
set -eu

OLD_NAME=mr-review-assistant
OLD_LABEL=com.madhani.mr-review-assistant

# lsof lives in /usr/sbin on macOS; appended so anything earlier on PATH still wins.
PATH="$PATH:/usr/sbin"

OLD_CONFIG="$HOME/.config/$OLD_NAME"
NEW_CONFIG="$HOME/.config/suica"
OLD_STATE="$HOME/Library/Application Support/$OLD_NAME"
NEW_STATE="$HOME/Library/Application Support/suica"
OLD_LOGS="$HOME/Library/Logs/$OLD_NAME"
NEW_LOGS="$HOME/Library/Logs/suica"

if [ -n "${MRA_CONFIG:-}" ]; then
  echo "warning: MRA_CONFIG is set; rename it to SUICA_CONFIG"
fi

# 1. Stop the old LaunchAgent and the old menu bar app.
launchctl bootout "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1 || true
osascript -e "tell application id \"$OLD_LABEL.menubar\" to quit" >/dev/null 2>&1 || true

# 2. Wait up to 5 s for them to exit; refuse before moving anything if one remains.
# A daemon started from a checkout that no longer carries the old name (npm start, node
# src/main.ts) is invisible to pgrep -f and to launchd, so also ask lsof who holds the OLD
# state folder open (the SQLite database and WAL live there). Only the old folder is checked:
# a process on the new folder is the new agent.
if [ -e "$OLD_STATE" ] && ! command -v lsof >/dev/null 2>&1; then
  echo "lsof not found: cannot tell whether a process has $OLD_STATE open; nothing was moved" >&2
  exit 1
fi
running_pids() {
  {
    pgrep -f "mr-review-assistant|MRAMenuBar" 2>/dev/null || true
    pgrep -x MRAMenuBar 2>/dev/null || true
  } | sort -u | tr '\n' ' '
}
state_holders() {
  if [ -e "$OLD_STATE" ]; then
    lsof -t +D "$OLD_STATE" 2>/dev/null | sort -u | tr '\n' ' ' || true
  fi
}
agent_loaded() {
  launchctl print "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1
}
pids=$(running_pids)
holders=$(state_holders)
waited=0
while { [ -n "$pids" ] || [ -n "$holders" ] || agent_loaded; } && [ "$waited" -lt 10 ]; do
  sleep 0.5
  waited=$((waited + 1))
  pids=$(running_pids)
  holders=$(state_holders)
done
if [ -n "$pids" ]; then
  echo "an old process is still running (pid ${pids% }): quit it and run this again" >&2
  exit 1
fi
if [ -n "$holders" ]; then
  echo "an old process is still running (pid ${holders% }) and holds the old state folder open ($OLD_STATE): quit it and run this again" >&2
  exit 1
fi
if agent_loaded; then
  echo "the old LaunchAgent is still loaded: $OLD_LABEL; run 'launchctl bootout gui/$(id -u)/$OLD_LABEL' and run this again" >&2
  exit 1
fi

# 3. Check every pair first, then move.
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
removed=""
if [ -e "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" ]; then
  rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
  removed="$removed the old LaunchAgent plist"
fi
if [ -e "$HOME/Applications/MR Review Assistant.app" ]; then
  rm -r "$HOME/Applications/MR Review Assistant.app"
  removed="${removed:+$removed and }the old app bundle"
fi

# 5. Warn about explicit old paths in the moved config; the file is not edited.
CONFIG_FILE="$NEW_CONFIG/config.yaml"
warned=0
if [ -f "$CONFIG_FILE" ]; then
  warned=$(grep -c "$OLD_NAME" "$CONFIG_FILE" || true)
  grep "$OLD_NAME" "$CONFIG_FILE" | while IFS= read -r line; do
    key=${line%%:*}
    key=${key#"${key%%[![:space:]]*}"}
    echo "warning: $CONFIG_FILE still names $OLD_NAME in: $key"
  done || true
fi

# 6. Report. The last line is the next step; with warnings it says to fix the keys first.
if [ "$moved" -eq 0 ] && [ -z "$removed" ]; then
  echo "already migrated"
elif [ "$moved" -eq 0 ]; then
  echo "nothing to move; removed$removed"
fi
if [ "$warned" -gt 0 ]; then
  echo "fix the keys above first, then run scripts/install-cli.sh, suica agent install and scripts/install-macos-app.sh"
elif [ "$moved" -ne 0 ]; then
  echo "migrated; now run scripts/install-cli.sh, suica agent install and scripts/install-macos-app.sh"
fi
