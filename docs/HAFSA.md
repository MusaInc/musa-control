# Hafsa hosted workspace

Hafsa has a dedicated companion container; there is no shared Linux login,
project registry, tmux socket, authentication cache, or cloud account service.
The owner's personal gateway is not restarted or reconfigured.

## Limits and boundary

- Container `musa-hafsa`, unprivileged UID 11001, all capabilities dropped,
  default Docker seccomp and AppArmor, no-new-privileges, read-only image.
- Sole mount: `/var/lib/musa-tenants/hafsa/home` → `/home/hafsa`.
  It is a fixed 10 GiB ext4 filesystem on a preallocated image. Root controls
  the containing directory and mount lifecycle. No host home, SSH socket,
  credential file, Docker socket, host PID namespace or privileged device.
- 1 CPU maximum, CPU shares 128, 1536 MiB RAM, no swap, 256 processes,
  4096 file descriptors; disk reads 20 MiB/s, writes 10 MiB/s. Temporary
  filesystems are bounded and charged to the container's memory limit.
  Docker logs rotate at 2 × 5 MiB. Disk throttles target the loop device and
  are reapplied from the current mount before every service start.
- Dedicated bridge `mc-hafsa`. Outbound public HTTP/HTTPS and DNS only;
  host addresses, private ranges, other Docker networks, metadata and IPv6
  are blocked. INPUT and DOCKER-USER both have tenant-specific rules.
  Atomic rule replacement prevents a gap during updates. Rules are applied
  before every service start. Docker does not independently auto-start it.
- Only port mapping: host **127.0.0.1:8171** → companion 8170.
- Separate HTTPS origin: `https://hafsa.159-195-109-68.sslip.io`.
  Caddy forwards only the companion's own web cookie and strips relay identity
  headers. The temporary hostname uses sslip.io DNS and can later be replaced
  by a dedicated DNS name; do not move project previews under the owner's origin.
- Docker shares the host kernel. These are tested container controls, not a
  VM-grade boundary or a promise against every kernel vulnerability. Keep
  Docker and the host kernel patched. Host-wide exhaustion or failures can
  still affect both users; limits bound Hafsa's workload rather than reserve
  all resources for either user.

## AI authentication

Only Codex is offered in the hosted provider UI. API-key writes return 403.
A fresh Codex binary and `/home/hafsa/.codex` are used; no owner authentication
is copied or mounted. The launcher refuses to start without ChatGPT login.
The wrapper forces ChatGPT login and file credential storage and unsets API
keys and provider override environment variables. There is no owner fallback
route. An expired login or subscription allowance must be resolved by Hafsa.

Hafsa performs the official device-code sign-in herself. Neither the host
administrator nor this setup should ask for her password. As host administrator,
Abdul can technically inspect container storage; this is not secrecy from the
VPS owner. Project-only backups exclude auth and device tokens.

## iPad onboarding (requires the hosted-workspace build)

1. Accept the external TestFlight invitation and install Musa Control.
2. Tap **Connect your hosted workspace**.
3. Name: **Hafsa**. Paste the HTTPS address above and the fresh connection code.
4. Open **Machines & AI → Codex → Sign in**. Open the OpenAI link, sign into
   Hafsa's own ChatGPT account, and enter the displayed device code on OpenAI's
   page. Enable device-code sign-in in ChatGPT security settings if requested.
5. Open **My project**, choose Codex, and describe what to build.

No SSH setup, studio password, API key, or separate Musa cloud account is needed.
The device token is stored in a separate device-only Keychain entry. Hosted
terminals use authenticated WebSockets and retain their tmux shell when the
app disconnects. A full container restart stops running shells/jobs but retains
files, login state and device tokens.

## Administrator operations

All commands below are on the VPS; never give Hafsa sudo or the Docker socket.

- Inspect: `sudo docker inspect musa-hafsa`; logs: `sudo docker logs --tail 50 musa-hafsa`.
- Maintain: `sudo docker exec -it musa-hafsa bash` (tenant user by default).
- Stop/start: `sudo systemctl stop musa-hafsa` / `sudo systemctl start musa-hafsa`.
- Verify: `sudo /home/abdul/.nvm/versions/node/v22.23.2/bin/node deploy/hosted/verify.mjs`.
  Uses test-only pairing and revokes it, prints no credentials. Run before an
  invitation and after image/network changes. Includes a service restart.
- Pair **when Hafsa is ready**: `sudo bash deploy/hosted/pair.sh`.
  Requires the security-pass marker for the exact current image/container.
  Writes a 0600 file under `/var/lib/musa-tenants/hafsa/connection-code.json`.
  Read privately and deliver directly; code is single-use and expires in 10 minutes.
- List/revoke devices: `sudo docker exec musa-hafsa node --no-warnings /opt/musa/bin/musa-companion.js devices`
  and the same command ending `revoke DEVICE_ID`. Existing terminal sockets close
  within about one second; event streams close within five seconds.
- Backup: `sudo bash deploy/hosted/backup.sh`. Pauses the tenant briefly,
  snapshots only `projects`, verifies the archive and keeps the newest three.
  Backups are root-only, on the same VPS (not disaster recovery).
- Restore: stop the tenant; inspect an administrator-owned archive; extract
  the `projects` directory into the mounted home as root, preserving UID 11001;
  verify ownership and restart. Never restore untrusted archives as host root.
  Authentication is deliberately not restored from project backups.

Provisioning scripts fail if the bounded mount cannot be mounted. Rebuilding
uses `docker build -f deploy/hosted/Dockerfile -t musa-hafsa:local .`, then stop
only Hafsa's service, remove only its container (not storage), and rerun
`sudo bash deploy/hosted/provision.sh`. Reverify before issuing a code.

## TestFlight gate

Use `node tools/testflight-status.mjs` for a read-only Apple status report using
local configured ASC credentials. On 2026-11-18, the existing build 0.4.2 (114)
was valid for internal testing, with external state READY_FOR_BETA_SUBMISSION;
there was only the internal Musa Team group. An empty external Hafsa group
was subsequently created with zero testers and its public link disabled. That is not an external invite.

Build **0.4.3 (116)** passed macOS build/unit/onboarding UI tests, was uploaded
with `internal_testers=false`, and has Apple processing state VALID. Its external
state is READY_FOR_BETA_SUBMISSION. It must still be submitted for and pass
Apple's Beta App Review before Hafsa can install it as an external tester. Create an
external Hafsa group, attach the reviewed build, then invite by her email or
an explicitly enabled public link. Do not add her as an App Store Connect team
member. No invitation is sent by this implementation.
