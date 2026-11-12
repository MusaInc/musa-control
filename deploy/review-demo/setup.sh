#!/bin/bash
# Creates the App Review demo: a reviewer account on Musa Control Cloud and a
# sandboxed demo computer (Docker, 1 CPU / 1 GB, no host mounts, unprivileged
# user) linked to it. Run after deploy/install-cloud.sh. Prints the sign-in to
# paste into App Store Connect → TestFlight → Test Information.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CLOUD="${PUBLIC_URL:-https://musastudios.co.uk/control-cloud}"
EMAIL="${REVIEW_EMAIL:-appreview@musastudios.co.uk}"
OUT="$HOME/.config/musa-control-cloud/review-account.txt"
export PATH=/home/dev/.nvm/versions/node/v22.23.2/bin:$PATH
sh "$ROOT/tools/pack_companion.sh" "$HERE/musa-companion.tgz" >/dev/null
docker build -q -t musa-review-demo "$HERE" >/dev/null
PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
TOKEN="$(curl -fsS -X POST "$CLOUD/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"name\":\"App Review\",\"deviceName\":\"setup\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
CODE="$(curl -fsS -X POST "$CLOUD/v1/machines/link-code" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"Demo computer"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["code"])')"
docker rm -f musa-review-demo >/dev/null 2>&1 || true
docker volume create musa-review-demo >/dev/null
docker run --rm -v musa-review-demo:/home/reviewer/.config musa-review-demo sh -c "musa-companion link $CODE --relay $CLOUD --name 'Demo computer'"
docker run -d --name musa-review-demo --restart unless-stopped --memory 1g --cpus 1 --pids-limit 512 \
  --cap-drop ALL --security-opt no-new-privileges -v musa-review-demo:/home/reviewer/.config musa-review-demo >/dev/null
curl -fsS -X POST "$CLOUD/v1/auth/logout" -H "Authorization: Bearer $TOKEN" >/dev/null || true
umask 077; printf 'App Review sign-in (Musa Control → Continue with email)\nemail: %s\npassword: %s\n' "$EMAIL" "$PASS" > "$OUT"
echo "Demo computer running (docker: musa-review-demo). Sign-in saved to $OUT"
echo "The reviewer can sign Claude Code / Codex / Gemini in with their own account, or you can add a key in the app."
