#!/bin/sh
# Builds the menu bar app, bundles it with this checkout's paths, signs it ad hoc and starts it.
# Re-run after moving the repo or switching Node versions: both absolute paths are baked into
# the app's Info.plist, like the LaunchAgent does.
set -eu

BUNDLE_ID=com.madhani.suica
REPO=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE="$REPO/macos/Suica"
APP="$HOME/Applications/Suica.app"

NODE=$(command -v node || true)
if [ -z "$NODE" ]; then
  echo "node not found on PATH" >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found: install Xcode or the Command Line Tools" >&2
  exit 1
fi

(cd "$PACKAGE" && swift build -c release)
BIN="$(cd "$PACKAGE" && swift build -c release --show-bin-path)/Suica"

# Quit a running copy so its binary can be replaced.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x Suica >/dev/null 2>&1 || break
  sleep 0.5
done

mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Suica"
cp "$REPO/macos/Info.plist.template" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SuicaNodePath $NODE" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SuicaRepoPath $REPO" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
open "$APP"
echo "installed $APP (node: $NODE)"
