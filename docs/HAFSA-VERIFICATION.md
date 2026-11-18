# Hafsa verification — 2026-11-18

## Operational

- Dedicated `musa-hafsa` container and systemd service, persistent bounded
  filesystem, private companion database, projects and terminal namespace.
- HTTPS endpoint: https://hafsa.159-195-109-68.sslip.io (valid public certificate).
- Personal gateway remains the existing process/service; its ping returns 200.
  Hafsa's protected project API returns 401 without authentication.
- Empty `My project` starter, own Git identity, no Codex login or provider keys.
- Root-only project backups verified byte-for-byte against the starter project.
  Only projects are archived; credentials and device tokens are excluded.
- External TestFlight group `Hafsa` created with zero testers and public link off.
  No invitation/access code issued; every verification device was revoked.

## Executed checks

Gateway suite: **41 passed, 0 failed**. Covers personal behavior, hosted
subscription enforcement, separate device databases, code expiry/reuse,
revocation and existing companion/provider behavior.

Live HTTPS checks (`deploy/hosted/verify.mjs`) passed:

- Non-root UID, read-only root, all capabilities dropped, no-new-privileges,
  isolated PID/network, no Docker socket, one tenant-only mount.
- Kernel cgroups: 1 CPU, 1536 MiB RAM, zero swap, 256 PIDs, disk I/O limits.
- Owner home, SSH material, root writes and privileged mounts unavailable.
- Host public/private IPs, other bridges, LAN and cloud metadata blocked;
  public package-registry HTTPS reachable.
- 11 GiB allocation rejected by the fixed 10 GiB filesystem.
- Unauthenticated/invalid tokens rejected, pairing code consumed once,
  tenant token rejected by the owner's gateway.
- API key save denied; signed-out Codex launch refused before model access;
  host SSH authorization disabled.
- Cross-origin browser terminal rejected.
- Authenticated terminal reconnect preserved a shell variable across clients.
- Service restart preserved project files and the paired device token.
- Administrator revocation disconnected a live terminal and blocked REST.

Resource stress checks:

- Two CPU workers throttled to the one-CPU budget.
- A 2 GiB allocation was OOM-killed inside Hafsa's 1.5 GiB cgroup; the probe
  survived and host swap was unavailable to that workload.
- A 32 MiB direct write took **3.12 seconds**, approximately 10 MiB/s. Initial
  testing caught that host-disk throttles did not cover the loop filesystem;
  the fix targets the actual mounted loop device before each service start.

Official OpenAI login check (`deploy/hosted/login-check.mjs`) produced the
OpenAI URL and device code through the companion. It did not complete sign-in,
print the code or consume the owner's subscription. Hafsa must complete her
own login and first real task to verify her account's entitlement/allowance.

## iPad validation

[Initial onboarding build and tests](https://github.com/MusaInc/musa-control/actions/runs/44389161254)
passed. Hosted URL validation and Keychain separation unit tests passed; hosted
onboarding, existing SSH onboarding and provider UI tests passed. The hosted
onboarding screenshot was visually reviewed on the iPad simulator.

[Release build 0.4.3](https://github.com/MusaInc/musa-control/actions/runs/44390804983)
completed successfully: **0.4.3 (116)** is uploaded and Apple processing is
**VALID**. Internal state is IN_BETA_TESTING; external state is
**WAITING_FOR_BETA_REVIEW** after submission at 21:11 UTC on 2026-11-18.
Apple review state is **WAITING_FOR_REVIEW**. No invitation was sent.

## Remaining release gates

Apple approval and a physical iPad sign-in/task with Hafsa's own subscription
remain required. Apple has a separate, restricted reviewer environment with a
sample project, private review-only credential and instructions. Reviewer
isolation tests passed locally and through HTTPS, including rejection of its
tokens by Hafsa and the owner gateway, network/storage/resource restrictions,
terminal reconnection, restart persistence and revocation. No model account
was shared; live Codex requires the reviewer's own subscription.

The approval watcher is active and its first runs correctly held invitation
for WAITING_FOR_REVIEW / WAITING_FOR_BETA_REVIEW. Policy tests cover pending,
rejected, wrong-version, unready and expired builds and changed groups. It
checks every 15 minutes and only invites after exact-build approval plus
workspace readiness. TestFlight includes iPad setup instructions. No Hafsa
pairing credential has been generated or sent.

## Deployment incident

Adding the hostname triggered a panic in the existing Caddy 2.6.2 reload
path at 20:21 UTC. Existing web endpoints were temporarily unavailable until
the original configuration was restored and Caddy restarted at 20:23 UTC.
The personal Musa gateway and user workloads were not restarted. The hosted
hostname was then activated with a validated bounded restart/rollback path;
both endpoints were rechecked. The reload path is not used by the provisioner.

## Limits of this verification

Docker shares the host kernel; this is not a separate VM. No host reboot or
real user's ChatGPT sign-in was performed. Tests used temporary credentials
and revoked them. Local backups protect against project mistakes, not loss of
the VPS. Public hostname DNS currently depends on sslip.io.
