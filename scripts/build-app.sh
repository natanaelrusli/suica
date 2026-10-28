#!/bin/sh
# Builds the menu bar app into OUT_APP (unsigned, SuicaCLIPath left as __CLI__): scripts/finish-app.sh
# points it at a CLI and signs it. Usage: OUT_APP=/path/Suica.app scripts/build-app.sh
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE="$REPO/macos/Suica"
APP=${OUT_APP:?set OUT_APP to the .app to build}

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found: install Xcode or the Command Line Tools" >&2
  exit 1
fi

(cd "$PACKAGE" && swift build -c release)
BIN="$(cd "$PACKAGE" && swift build -c release --show-bin-path)/Suica"

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
/usr/libexec/PlistBuddy -c "Set :SuicaCLIPath __CLI__" "$APP/Contents/Info.plist"
V=$(node -p "require('$REPO/package.json').version")
for KEY in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$KEY $V" "$APP/Contents/Info.plist"
done
