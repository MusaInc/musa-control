#!/bin/sh
# One-line install for computers the app can't reach over SSH:
#   curl -fsSL <account-service>/companion/install.sh | sh -s -- --link CODE
# Downloads the companion from the same service, checks its SHA-256,
# installs it for the current user (no root) and links it to the account
# that created CODE. Read it before running it: it's short.
set -eu
BASE="${MUSA_CONTROL_RELAY:-__BASE__}"
CODE=""; NAME=""
while [ $# -gt 0 ]; do case "$1" in --link) CODE="$2"; shift 2;; --name) NAME="$2"; shift 2;; *) shift;; esac; done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading the Musa Control companion from $BASE …"
curl -fsSL "$BASE/companion/musa-companion.tgz" -o "$TMP/c.tgz"
WANT="$(curl -fsSL "$BASE/companion/musa-companion.tgz.sha256" | cut -d' ' -f1)"
GOT="$( (sha256sum "$TMP/c.tgz" 2>/dev/null || shasum -a 256 "$TMP/c.tgz") | cut -d' ' -f1)"
[ "$WANT" = "$GOT" ] || { echo "Checksum mismatch — not installing." >&2; exit 1; }
tar xzf "$TMP/c.tgz" -C "$TMP"
sh "$TMP/musa-companion/bin/install.sh"
if [ -n "$CODE" ]; then
  if [ -n "$NAME" ]; then "$HOME/.local/bin/musa-companion" link "$CODE" --relay "$BASE" --name "$NAME"; else "$HOME/.local/bin/musa-companion" link "$CODE" --relay "$BASE"; fi
  "$HOME/.local/bin/musa-companion" install-service
  echo "Linked. It appears in Musa Control within a few seconds."
fi
