#!/bin/bash
# Run as root, after image build. No access code is created by provisioning.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run with sudo'; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=/var/lib/musa-tenants/review
install -d -m 700 "$BASE" "$BASE/home" "$BASE/backups"
if [ ! -f "$BASE/home.ext4" ]; then
  fallocate -l 2G "$BASE/home.ext4"
  chmod 600 "$BASE/home.ext4"
  mkfs.ext4 -q -m 0 -L musa-review "$BASE/home.ext4"
fi
# A separate, fixed-size filesystem bounds *all* tenant writes, including
# source trees, dependencies, auth, transcripts and the companion database.
MOUNT_UNIT=$(systemd-escape --path --suffix=mount "$BASE/home")
cat > "/etc/systemd/system/$MOUNT_UNIT" <<UNIT
[Unit]
Description=App Review bounded 10 GiB workspace
Before=musa-review.service
[Mount]
What=$BASE/home.ext4
Where=$BASE/home
Type=ext4
Options=loop,nosuid,nodev
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl start "$MOUNT_UNIT"
mountpoint -q "$BASE/home"
chown 11001:11001 "$BASE/home"
chmod 700 "$BASE/home"
install -m 755 "$HERE/storage-limits.py" /usr/local/sbin/musa-review-storage-limits
install -m 755 "$HERE/firewall.sh" /usr/local/sbin/musa-review-firewall
if ! docker network inspect musa-review >/dev/null 2>&1; then
  docker network create --driver bridge --subnet 172.30.48.0/28 --opt com.docker.network.bridge.name=mc-review --opt com.docker.network.bridge.enable_icc=false musa-review >/dev/null
fi
/usr/local/sbin/musa-review-firewall
if ! docker container inspect musa-review >/dev/null 2>&1; then
  docker create --name musa-review --hostname review --network musa-review --ip 172.30.48.2 \
    --publish 127.0.0.1:8172:8170 --user 11001:11001 --read-only \
    --cap-drop ALL --security-opt no-new-privileges:true --security-opt apparmor=docker-default \
    --memory 512m --memory-swap 512m --cpus 0.5 --cpu-shares 64 --pids-limit 128 \
    --ulimit nofile=4096:4096 --ulimit core=0:0 --shm-size 32m \
    --device-read-bps /dev/vda:20mb --device-write-bps /dev/vda:10mb \
    --tmpfs /tmp:rw,nosuid,nodev,size=192m,mode=1777 --tmpfs /run:rw,nosuid,nodev,noexec,size=16m \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --mount type=bind,src="$BASE/home",dst=/home/hafsa,bind-propagation=rprivate \
    --log-driver local --log-opt max-size=5m --log-opt max-file=2 \
    --mount type=bind,src="$BASE/config.json",dst=/etc/musa-hosted.json,readonly \
    --mount type=bind,src="$BASE/review-access.hash",dst=/etc/review-access.hash,readonly \
    --restart no musa-review:local >/dev/null
fi
cat > /etc/systemd/system/musa-review.service <<UNIT
[Unit]
Description=App Review isolated Musa Control workspace
Requires=docker.service $MOUNT_UNIT
After=docker.service network-online.target $MOUNT_UNIT
[Service]
Type=simple
ExecStartPre=/usr/bin/mountpoint -q $BASE/home
ExecStartPre=/usr/local/sbin/musa-review-firewall
ExecStartPre=/usr/local/sbin/musa-review-storage-limits
ExecStart=/usr/bin/docker start -a musa-review
ExecStop=/usr/bin/docker stop -t 15 musa-review
Restart=always
RestartSec=5
TimeoutStopSec=30
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now musa-review.service
printf 'App Review provisioned. No pairing code issued. Run security checks before publishing the route.\n'
