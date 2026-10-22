#!/bin/sh
# Builds the menu bar app, signs it ad hoc and starts it. The app runs the installed suica CLI
# (scripts/install-cli.sh), whose absolute path is baked into its Info.plist: install the CLI
# first, and re-run this if the CLI moves. Set SUICA_CLI to use a CLI that is not on the PATH.
set -eu

BUNDLE_ID=com.madhani.suica
REPO=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE="$REPO/macos/Suica"
APP="$HOME/Applications/Suica.app"

CLI=${SUICA_CLI:-$(command -v suica || echo "$HOME/.local/bin/suica")}
if [ ! -x "$CLI" ]; then
  echo "suica CLI not found ($CLI): run scripts/install-cli.sh first, or set SUICA_CLI" >&2
  exit 1
fi
CLI=$(cd "$(dirname "$CLI")" && pwd)/$(basename "$CLI")
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

# The icon is drawn by macos/make-icon.swift with the app's own AppIconArt.swift, so no image is
# kept in git.
ICONS=$(mktemp -d)
trap 'rm -rf "$ICONS"' EXIT
swiftc -parse-as-library -O "$PACKAGE/Sources/Suica/AppIconArt.swift" "$REPO/macos/make-icon.swift" -o "$ICONS/make-icon"
"$ICONS/make-icon" "$ICONS/icon.png"
mkdir -p "$ICONS/AppIcon.iconset"
for px in 16 32 128 256 512; do
  sips -z "$px" "$px" "$ICONS/icon.png" --out "$ICONS/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
  double=$((px * 2))
  sips -z "$double" "$double" "$ICONS/icon.png" --out "$ICONS/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Suica"
iconutil -c icns "$ICONS/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$REPO/macos/Info.plist.template" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SuicaCLIPath $CLI" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
open "$APP"
echo "installed $APP (cli: $CLI)"
