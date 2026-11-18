#!/bin/bash
set -euo pipefail
BASE=/var/lib/musa-tenants/review
[ "$(id -u)" = 0 ] || exit 1
[ -f "$BASE/security-passed" ] || { echo 'Security verification has not passed.'; exit 1; }
[ "$(head -1 "$BASE/security-passed")" = "$(docker inspect musa-review --format '{{.Id}} {{.Image}}')" ] || exit 1
CF=/etc/caddy/Caddyfile
HOST=review.159-195-109-68.sslip.io
if ! grep -q "^$HOST {" "$CF"; then
  BAK="$BASE/Caddyfile.before-hosted"
  cp "$CF" "$BAK"
  cat >> "$CF" <<CADDY

$HOST {
    import public_tls
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        -Server
    }
    reverse_proxy 127.0.0.1:8172 {
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
  # This VPS's Caddy process panicked during reload. Use a bounded restart
  # with immediate restoration, and retain the existing site's health gate.
  if ! timeout 15 systemctl restart caddy; then cp "$BAK" "$CF"; systemctl restart caddy; exit 1; fi
  if ! curl -fsS --max-time 10 https://musastudios.co.uk/control/api/ping >/dev/null; then
    cp "$BAK" "$CF"; systemctl restart caddy; echo 'Existing site health failed; restored original proxy.'; exit 1
  fi
fi
echo "App Review endpoint configured: https://$HOST (no access code issued)"
