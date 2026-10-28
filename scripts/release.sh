#!/bin/sh
# Builds, packs, signs and publishes a GitHub release of the version in package.json.
# DRY_RUN=1 does everything except `gh release create` and prints that command instead.
# The signing key is read from SUICA_RELEASE_KEY (default ~/.config/suica/release-key.pem).
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

[ "$(uname -m)" = arm64 ] || { echo "release.sh builds arm64 only" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "worktree is not clean" >&2; exit 1; }
VERSION=$(node -p "require('./package.json').version")
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "tag v$VERSION already exists" >&2
  exit 1
fi

WORK=$(mktemp -d)
[ -n "${DRY_RUN:-}" ] || trap 'rm -rf "$WORK"' EXIT
OUT_APP="$WORK/Suica.app" "$REPO/scripts/build-app.sh"
TARBALL="$WORK/suica-$VERSION-arm64.tar.gz"
"$REPO/scripts/pack-release.sh" "$WORK/Suica.app" "$TARBALL"
node "$REPO/scripts/release-sign.ts" "$TARBALL" "$VERSION" arm64

set -- gh release create "v$VERSION" "$TARBALL" "$WORK/latest.json" "$WORK/latest.json.sig" --title "v$VERSION"
if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY_RUN: $*"
else
  "$@"
fi
