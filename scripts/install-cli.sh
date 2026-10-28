#!/bin/sh
# Installs the suica CLI (commands and background agent) so it no longer depends on this checkout:
#   $PREFIX/lib/suica   the code and its production dependencies, installed from package-lock.json
#   $PREFIX/bin/suica   the command
# PREFIX is ~/.local unless SUICA_PREFIX is set. Re-run to update, and after switching Node
# versions: the absolute node path is baked into the command and into the LaunchAgent. SUICA_NODE
# picks that node instead of the first one on the PATH.
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${SUICA_PREFIX:-$HOME/.local}
LIB="$PREFIX/lib/suica"
BIN="$PREFIX/bin/suica"

NODE=${SUICA_NODE:-$(command -v node || true)}
if [ -z "$NODE" ]; then
  echo "node not found on PATH" >&2
  exit 1
fi
MAJOR=$("$NODE" -p 'process.versions.node.split(".")[0]')
if [ "$MAJOR" -lt 24 ]; then
  echo "Node 24 or newer is required, found $("$NODE" --version)" >&2
  exit 1
fi
NPM="$(dirname "$NODE")/npm"
[ -x "$NPM" ] || NPM=npm

mkdir -p "$PREFIX/lib" "$PREFIX/bin"
STAGE=$(mktemp -d "$PREFIX/lib/.suica-new.XXXXXX")
OLD="$STAGE.old"
trap 'rm -rf "$STAGE" "$OLD"' EXIT

cp "$REPO/package.json" "$REPO/package-lock.json" "$STAGE/"
cp -R "$REPO/src" "$STAGE/src"
# npm ci installs exactly the lockfile; no install scripts run.
(cd "$STAGE" && "$NPM" ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error)

# The old copy goes only once the new one is complete.
if [ -d "$LIB" ]; then mv "$LIB" "$OLD"; fi
mv "$STAGE" "$LIB"

cat > "$BIN.new" <<EOF
#!/bin/sh
exec "$NODE" "$LIB/src/cli.ts" "\$@"
EOF
chmod 755 "$BIN.new"
mv "$BIN.new" "$BIN"
echo "installed $BIN (node: $NODE)"

# A LaunchAgent from an earlier install (or from a checkout) is moved over to this copy.
if [ -f "$HOME/Library/LaunchAgents/com.madhani.suica.agent.plist" ]; then
  "$BIN" agent install
else
  echo "start the background agent with: suica agent install"
fi

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "note: $PREFIX/bin is not on your PATH; add it to your shell profile" ;;
esac
