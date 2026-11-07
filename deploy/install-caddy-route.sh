#!/bin/bash
# Adds the /control/* route for the Musa Control gateway to the main Caddy site,
# validates the config and reloads Caddy gracefully (no dropped connections).
# A timestamped backup of the Caddyfile is kept next to it.
set -euo pipefail
CF=/etc/caddy/Caddyfile
SNIP="$(dirname "$0")/Caddyfile.snippet"
if sudo grep -q 'handle_path /control/\*' "$CF"; then echo "Route already present."; exit 0; fi
BAK="$CF.bak-before-musa-control-$(date +%Y%m%dT%H%M%S)"
sudo cp "$CF" "$BAK"
sudo python3 - "$CF" "$SNIP" <<'PY'
import sys
p, snip = sys.argv[1], open(sys.argv[2]).read().rstrip("\n")
s = open(p).read()
anchor = "\t\t# FireDev (firedev.service"
assert anchor in s, "anchor not found"
open(p, "w").write(s.replace(anchor, snip + "\n\n" + anchor, 1))
PY
if ! sudo caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then
  sudo cp "$BAK" "$CF"; echo "Validation failed; Caddyfile restored from $BAK"; exit 1
fi
sudo systemctl reload caddy
sleep 2
echo "ping:      $(curl -s https://musastudios.co.uk/control/api/ping)"
echo "no token:  HTTP $(curl -s -o /dev/null -w '%{http_code}' https://musastudios.co.uk/control/api/projects) (expect 401)"
echo "dashboard: HTTP $(curl -s -o /dev/null -w '%{http_code}' https://musastudios.co.uk/) (expect 302 to sign-in)"
echo "Backup: $BAK"
