#!/bin/bash
# Run only when Hafsa is ready to connect; never send the code through logs.
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 1
BASE=/var/lib/musa-tenants/hafsa
[ -f "$BASE/security-passed" ] || { echo 'Security verification is required before issuing access.' >&2; exit 1; }
# Bind approval to the exact container configuration and image checked.
CURRENT=$(docker inspect musa-hafsa --format '{{.Id}} {{.Image}}')
[ "$(head -1 "$BASE/security-passed")" = "$CURRENT" ] || { echo 'Container changed: rerun security verification.' >&2; exit 1; }
umask 077
OUT="$BASE/connection-code.json"
docker exec musa-hafsa node --no-warnings /opt/musa/bin/musa-companion.js pair --json > "$OUT"
chmod 600 "$OUT"
echo "Fresh single-use code saved to $OUT (expires in 10 minutes). Deliver privately; do not paste in build logs."
