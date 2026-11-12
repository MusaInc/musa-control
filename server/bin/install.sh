#!/bin/sh
# Installs (or updates) the Musa Control companion for the current user.
# Run from an unpacked bundle:  sh install.sh [--json]
# The app runs this over SSH during setup. It never needs root.
set -eu
JSON=0; [ "${1:-}" = "--json" ] && JSON=1
say() { [ $JSON = 1 ] || echo "$@"; }
fail() { if [ $JSON = 1 ]; then printf '{"ok":false,"error":"%s"}\n' "$1"; else echo "error: $1" >&2; fi; exit 1; }

[ "$(id -u)" = "0" ] && fail "Run as your normal user, not root."
case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux|Darwin) ;;
  *) fail "Unsupported system. On Windows, install the companion inside WSL2 (Ubuntu)." ;;
esac

# Node.js 22.5+ (node:sqlite). Look in PATH, nvm, Homebrew, ~/.local.
NODE=""
for c in "$(command -v node 2>/dev/null || true)" "$HOME"/.nvm/versions/node/v2*/bin/node /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.local/bin/node"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  if "$c" -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=5)?0:1)' 2>/dev/null; then NODE="$c"; fi
done
[ -n "$NODE" ] || fail "Node.js 22.5 or newer is needed. Install it (https://nodejs.org or nvm), then run setup again."
command -v tmux >/dev/null 2>&1 || say "note: tmux isn't installed; terminals and agent sessions need it (apt install tmux / brew install tmux)."

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.musa-companion/app"
mkdir -p "$HOME/.musa-companion" "$HOME/.local/bin"
chmod 700 "$HOME/.musa-companion"
if [ "$SRC" != "$DEST" ]; then rm -rf "$DEST.new"; cp -R "$SRC" "$DEST.new"; rm -rf "$DEST"; mv "$DEST.new" "$DEST"; fi
cat > "$HOME/.local/bin/musa-companion" <<WRAP
#!/bin/sh
exec "$NODE" --no-warnings "$DEST/bin/musa-companion.js" "\$@"
WRAP
chmod 755 "$HOME/.local/bin/musa-companion"
if [ $JSON = 1 ]; then
  "$NODE" --no-warnings "$DEST/bin/musa-companion.js" install-service --json
else
  "$NODE" --no-warnings "$DEST/bin/musa-companion.js" install-service
  echo "Installed. Command: ~/.local/bin/musa-companion (try: musa-companion info)"
fi
