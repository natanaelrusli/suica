#!/bin/sh
# Renders the LaunchAgent for this checkout and starts it. Re-run after moving the repo or
# switching Node versions: the absolute node path is baked into the plist.
set -eu

LABEL=com.madhani.mr-review-assistant
REPO=$(cd "$(dirname "$0")/.." && pwd)
NODE=$(command -v node)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="${MRA_CONFIG:-$HOME/.config/mr-review-assistant/config.yaml}"

# A daemon that cannot read its config exits on every start; refuse to install it that way.
if [ ! -f "$CONFIG" ]; then
  echo "config not found: $CONFIG (see README, Setup)" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/mr-review-assistant"
sed -e "s|__NODE__|$NODE|g" -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
  "$REPO/launchd/$LABEL.plist.template" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed $PLIST (node: $NODE)"
