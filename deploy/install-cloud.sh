#!/bin/bash
# Deploys Musa Control Cloud on this VPS (run it yourself; it uses sudo):
#   1. writes ~/.config/musa-control-cloud/config.json (once) and packs the companion bundle
#   2. installs + starts musa-control-cloud.service (127.0.0.1:8180, hardened)
#   3. adds the /control-cloud/* Caddy route (backup, validate, graceful reload; restores on failure)
#   4. smoke-tests the public URL
# Re-running is safe: each step skips what's already done.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PUBLIC="${PUBLIC_URL:-https://musastudios.co.uk/control-cloud}"
DATA="$HOME/.local/share/musa-control-cloud"; CONF="$HOME/.config/musa-control-cloud"
NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/v22*/bin 2>/dev/null | sort -V | tail -1)"; NODE_BIN="${NODE_BIN:-$(dirname "$(command -v node)")}"
export PATH="$NODE_BIN:$PATH"

mkdir -p "$DATA" "$CONF"; chmod 700 "$DATA" "$CONF"
if [ ! -f "$CONF/config.json" ]; then
  cat > "$CONF/config.json" <<JSON
{ "publicUrl": "$PUBLIC", "companionBundle": "$DATA/musa-companion.tgz", "registration": "open" }
JSON
  chmod 600 "$CONF/config.json"; echo "wrote $CONF/config.json"
fi
(cd "$ROOT/cloud" && npm ci --omit=dev --no-audit --no-fund >/dev/null)
sh "$ROOT/tools/pack_companion.sh" "$DATA/musa-companion.tgz"
[ -f "$CONF/apns.json" ] || echo "note: no $CONF/apns.json yet — push for public users stays off until you add an APNs key (see docs/MULTI_USER.md)"

sed -e "s#__USER__#$(id -un)#g" -e "s#__HOME__#$HOME#g" -e "s#__NODE__#$NODE_BIN/node#g" "$HERE/musa-control-cloud.service" | sudo tee /etc/systemd/system/musa-control-cloud.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now musa-control-cloud
sudo systemctl restart musa-control-cloud
sleep 2
curl -fsS --noproxy '*' http://127.0.0.1:8180/v1/ping >/dev/null && echo "service: up on 127.0.0.1:8180"

CF=/etc/caddy/Caddyfile
if ! sudo grep -q 'handle_path /control-cloud/\*' "$CF"; then
  BAK="$CF.bak-before-musa-control-cloud-$(date +%Y%m%dT%H%M%S)"
  sudo cp "$CF" "$BAK"
  sudo python3 - "$CF" "$HERE/Caddyfile.cloud.snippet" <<'PY'
import sys
p, snip = sys.argv[1], open(sys.argv[2]).read().rstrip("\n")
s = open(p).read()
anchor = "\t\t# Musa Control gateway" if "\t\t# Musa Control gateway" in s else "\t\t# FireDev (firedev.service"
assert anchor in s, "anchor not found"
open(p, "w").write(s.replace(anchor, snip + "\n\n" + anchor, 1))
PY
  if ! sudo caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then sudo cp "$BAK" "$CF"; echo "Caddy validation failed; restored $BAK"; exit 1; fi
  sudo systemctl reload caddy; sleep 2; echo "caddy: route added (backup $BAK)"
fi
echo "ping:      $(curl -s "$PUBLIC/v1/ping")"
echo "no token:  HTTP $(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC/v1/me") (expect 401)"
echo "installer: HTTP $(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC/companion/install.sh") (expect 200)"
echo "privacy:   HTTP $(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC/privacy") (expect 200)"
echo "personal:  HTTP $(curl -s -o /dev/null -w '%{http_code}' https://musastudios.co.uk/control/api/projects) (expect 401, untouched)"
