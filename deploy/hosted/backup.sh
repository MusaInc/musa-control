#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 1
BASE=/var/lib/musa-tenants/hafsa
mountpoint -q "$BASE/home"
umask 077
# Deliberately excludes authentication and device tokens. A restored workspace
# must pair again and sign into ChatGPT again. Keep only three local snapshots.
OUT="$BASE/backups/projects-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
docker pause musa-hafsa >/dev/null
trap 'docker unpause musa-hafsa >/dev/null' EXIT
nice -n 19 ionice -c 3 tar --one-file-system -czf "$OUT" -C "$BASE/home" projects
# Validate the archive before deleting any older backup.
tar -tzf "$OUT" >/dev/null
docker unpause musa-hafsa >/dev/null
trap - EXIT
python3 - "$BASE/backups" <<'PY'
import pathlib,sys
files=sorted(pathlib.Path(sys.argv[1]).glob('projects-*.tar.gz'))
for old in files[:-3]: old.unlink()
PY
printf 'Project backup verified: %s\n' "$OUT"
