#!/bin/bash
set -euo pipefail
BASE=/var/lib/musa-tenants/hafsa
[ "$(id -u)" = 0 ] || exit 1
[ -f "$BASE/security-passed" ] || { echo 'Security verification has not passed.'; exit 1; }
[ "$(head -1 "$BASE/security-passed")" = "$(docker inspect musa-hafsa --format '{{.Id}} {{.Image}}')" ] || exit 1
CF=/etc/caddy/Caddyfile
HOST=hafsa.159-195-109-68.sslip.io
if ! grep -q "^$HOST {" "$CF"; then
  BAK="$BASE/Caddyfile.before-hosted"
  cp "$CF" "$BAK"
  cat >> "$CF" <<CADDY

$HOST {
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        -Server
    }
    reverse_proxy 127.0.0.1:8171 {
        # Forward only this gateway's web-session cookie, never other cookies.
        header_up Cookie "mc_web={http.request.cookie.mc_web}"
        header_up -X-Mc-Relay
        header_up -X-Mc-User
        header_up -X-Mc-Session
        header_up -X-Mc-Base
    }
}
CADDY
  if ! caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then cp "$BAK" "$CF"; echo 'Validation failed; original config restored.'; exit 1; fi
  if ! systemctl reload caddy; then cp "$BAK" "$CF"; systemctl reload caddy; exit 1; fi
fi
echo "Hafsa endpoint configured: https://$HOST (no access code issued)"
