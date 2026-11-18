#!/bin/bash
# Run as root, after image build. No access code is created by provisioning.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run with sudo'; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=/var/lib/musa-tenants/hafsa
install -d -m 700 "$BASE" "$BASE/home" "$BASE/backups"
if [ ! -f "$BASE/home.ext4" ]; then
  fallocate -l 10G "$BASE/home.ext4"
  chmod 600 "$BASE/home.ext4"
  mkfs.ext4 -q -m 0 -L musa-hafsa "$BASE/home.ext4"
fi
# A separate, fixed-size filesystem bounds *all* tenant writes, including
# source trees, dependencies, auth, transcripts and the companion database.
MOUNT_UNIT=$(systemd-escape --path --suffix=mount "$BASE/home")
cat > "/etc/systemd/system/$MOUNT_UNIT" <<UNIT
[Unit]
Description=Hafsa bounded 10 GiB workspace
Before=musa-hafsa.service
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
install -m 755 "$HERE/storage-limits.py" /usr/local/sbin/musa-hafsa-storage-limits
install -m 755 "$HERE/firewall.sh" /usr/local/sbin/musa-hafsa-firewall
if ! docker network inspect musa-hafsa >/dev/null 2>&1; then
  docker network create --driver bridge --subnet 172.30.47.0/28 --opt com.docker.network.bridge.name=mc-hafsa --opt com.docker.network.bridge.enable_icc=false musa-hafsa >/dev/null
fi
/usr/local/sbin/musa-hafsa-firewall
if ! docker container inspect musa-hafsa >/dev/null 2>&1; then
  docker create --name musa-hafsa --hostname hafsa --network musa-hafsa --ip 172.30.47.2 \
    --publish 127.0.0.1:8171:8170 --user 11001:11001 --read-only \
    --cap-drop ALL --security-opt no-new-privileges:true --security-opt apparmor=docker-default \
    --memory 1536m --memory-swap 1536m --cpus 1 --cpu-shares 128 --pids-limit 256 \
    --ulimit nofile=4096:4096 --ulimit core=0:0 --shm-size 32m \
    --device-read-bps /dev/vda:20mb --device-write-bps /dev/vda:10mb \
    --tmpfs /tmp:rw,nosuid,nodev,size=192m,mode=1777 --tmpfs /run:rw,nosuid,nodev,noexec,size=16m \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --mount type=bind,src="$BASE/home",dst=/home/hafsa,bind-propagation=rprivate \
    --log-driver local --log-opt max-size=5m --log-opt max-file=2 \
    --restart no musa-hafsa:local >/dev/null
fi
cat > /etc/systemd/system/musa-hafsa.service <<UNIT
[Unit]
Description=Hafsa isolated Musa Control workspace
Requires=docker.service $MOUNT_UNIT
After=docker.service network-online.target $MOUNT_UNIT
[Service]
Type=simple
ExecStartPre=/usr/bin/mountpoint -q $BASE/home
ExecStartPre=/usr/local/sbin/musa-hafsa-firewall
ExecStartPre=/usr/local/sbin/musa-hafsa-storage-limits
ExecStart=/usr/bin/docker start -a musa-hafsa
ExecStop=/usr/bin/docker stop -t 15 musa-hafsa
Restart=always
RestartSec=5
TimeoutStopSec=30
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now musa-hafsa.service
printf 'Hafsa provisioned. No pairing code issued. Run security checks before publishing the route.\n'
