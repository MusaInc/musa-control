#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
install -d -m 755 /usr/local/lib/musa-beta-release
install -d -m 700 /var/lib/musa-beta-release
for name in asc-client.mjs beta-release-policy.mjs hafsa-beta-release.mjs; do
  install -m 644 "$ROOT/tools/$name" "/usr/local/lib/musa-beta-release/$name"
done
python3 - <<'PY'
import hashlib,json,pathlib,os
recipient=json.load(open('/home/abdul/.config/musa-hafsa/invitation.json'))['email'].strip().lower()
p=pathlib.Path('/var/lib/musa-beta-release/config.json')
value={'recipientHash':hashlib.sha256(recipient.encode()).hexdigest(),'app':'6831994013','build':'b9d82af1-1de3-4765-8143-a014afadb398','authorizedAction':'Invite Hafsa after approval of 0.4.3 (116); never generate or send pairing credentials.'}
if p.exists() and json.loads(p.read_text())['recipientHash']!=value['recipientHash']:raise SystemExit('Recipient changed; refusing to replace release authorization')
p.write_text(json.dumps(value));os.chmod(p,0o600)
PY
cat > /etc/systemd/system/musa-hafsa-beta-release.service <<'UNIT'
[Unit]
Description=Invite Hafsa only after Apple approves Musa Control build 116
After=network-online.target docker.service
[Service]
Type=oneshot
ExecStart=/home/abdul/.nvm/versions/node/v22.23.2/bin/node /usr/local/lib/musa-beta-release/hafsa-beta-release.mjs
TimeoutStartSec=120
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/musa-beta-release
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
MemoryMax=192M
CPUQuota=10%
UNIT
cat > /etc/systemd/system/musa-hafsa-beta-release.timer <<'UNIT'
[Unit]
Description=Check Apple approval and workspace readiness every 15 minutes
[Timer]
OnBootSec=2min
OnUnitInactiveSec=15min
AccuracySec=30s
Unit=musa-hafsa-beta-release.service
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
# Exercise the actual installed code while it is forbidden to send.
/home/abdul/.nvm/versions/node/v22.23.2/bin/node /usr/local/lib/musa-beta-release/hafsa-beta-release.mjs --dry-run
systemctl enable --now musa-hafsa-beta-release.timer
systemctl start musa-hafsa-beta-release.service
systemctl is-active musa-hafsa-beta-release.timer
