#!/bin/sh
# Packs a built app and the checkout into the release tarball that applyUpdate (src/update.ts)
# unpacks. Usage: scripts/pack-release.sh APP OUT_TARBALL
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:?usage: pack-release.sh APP OUT_TARBALL}
OUT=${2:?usage: pack-release.sh APP OUT_TARBALL}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Suica.app"
cp -R "$REPO/scripts" "$REPO/src" "$REPO/package.json" "$REPO/package-lock.json" "$STAGE/"
# COPYFILE_DISABLE keeps macOS tar from adding ._ metadata entries.
COPYFILE_DISABLE=1 tar -czf "$OUT" -C "$STAGE" Suica.app scripts src package.json package-lock.json
