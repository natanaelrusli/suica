#!/bin/sh
# Points a built Suica.app at a CLI and signs it ad hoc. Usage: finish-app.sh APP CLI
set -eu
APP=$1
CLI=$2
/usr/libexec/PlistBuddy -c "Set :SuicaCLIPath $CLI" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
