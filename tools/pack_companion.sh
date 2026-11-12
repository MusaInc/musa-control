#!/bin/sh
# Builds the companion bundle (the gateway in companion mode) that the app
# uploads over SSH and the account service offers for one-line installs.
#   tools/pack_companion.sh [out.tgz]   default: ios/MusaControl/Resources/companion.tgz
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/ios/MusaControl/Resources/companion.tgz}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/musa-companion"
mkdir -p "$D/node_modules"
cp -R "$ROOT/server/src" "$ROOT/server/bin" "$ROOT/server/web" "$ROOT/server/package.json" "$D/"
( cd "$ROOT/server" && [ -d node_modules/ws ] || npm ci --omit=dev --no-audit --no-fund >/dev/null )
for m in ws bcryptjs; do cp -R "$ROOT/server/node_modules/$m" "$D/node_modules/"; done
rm -f "$D/src/cli.js"   # personal-gateway admin; the companion has its own CLI
mkdir -p "$(dirname "$OUT")"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$OUT" musa-companion
if command -v sha256sum >/dev/null; then sha256sum "$OUT"; else shasum -a 256 "$OUT"; fi
