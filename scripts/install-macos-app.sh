#!/bin/sh
# Builds the menu bar app, signs it ad hoc and starts it. The app runs the installed suica CLI
# (scripts/install-cli.sh), whose absolute path is baked into its Info.plist: install the CLI
# first, and re-run this if the CLI moves. Set SUICA_CLI to use a CLI that is not on the PATH.
set -eu

BUNDLE_ID=com.madhani.suica
REPO=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/Suica.app"

CLI=${SUICA_CLI:-$(command -v suica || echo "$HOME/.local/bin/suica")}
if [ ! -x "$CLI" ]; then
  echo "suica CLI not found ($CLI): run scripts/install-cli.sh first, or set SUICA_CLI" >&2
  exit 1
fi
CLI=$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")

BUILT=$(mktemp -d)
trap 'rm -rf "$BUILT"' EXIT
OUT_APP="$BUILT/Suica.app" "$REPO/scripts/build-app.sh"

# Quit a running copy so its binary can be replaced.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x Suica >/dev/null 2>&1 || break
  sleep 0.5
done

rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
cp -R "$BUILT/Suica.app" "$APP"
"$REPO/scripts/finish-app.sh" "$APP" "$CLI"

# macOS shows a notification with the icon of the app that sent it, so the agent sends its
# notifications through a copy of terminal-notifier that carries the Suica icon. It is a separate
# app: the first notification asks for permission once, under the name Suica.
NOTIFIER="$HOME/Applications/Suica Notifier.app"
SOURCE=$(brew --prefix terminal-notifier 2>/dev/null || true)/terminal-notifier.app
if [ -d "$SOURCE" ]; then
  rm -rf "$NOTIFIER"
  cp -R "$SOURCE" "$NOTIFIER"
  rm -f "$NOTIFIER"/Contents/Resources/*.icns
  cp "$APP/Contents/Resources/AppIcon.icns" "$NOTIFIER/Contents/Resources/AppIcon.icns"
  PLIST="$NOTIFIER/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.madhani.suica.notifier" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Suica" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Suica" "$PLIST" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Suica" "$PLIST"
  codesign --force --deep --sign - "$NOTIFIER"
  echo "installed $NOTIFIER"
else
  echo "terminal-notifier not installed (brew install terminal-notifier): notifications keep its icon and have no buttons"
fi
open "$APP"
echo "installed $APP (cli: $CLI)"
