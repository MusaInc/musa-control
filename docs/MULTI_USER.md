# Musa Control for everyone: accounts, any machine, any AI subscription

Status 2026-11-12, branch `multi-user`. Same app, bundle id (`uk.co.musastudios.musacontrol`),
App Store Connect record and TestFlight setup. Nothing has been deployed, uploaded or submitted.

## How it fits together

```
iPad/iPhone ──SSH (pinned host key)──▶ your machine: sshd ─▶ companion on 127.0.0.1 (tunnel inside SSH)
     │
     ├──HTTPS──▶ Musa Control Cloud (accounts, relay, push) ◀──WSS (outbound)── companion on a NAT'd machine
     │
     └──HTTPS──▶ Musa Studios gateway (/control, workspace password)   ← the original personal setup, unchanged
```

* **Companion** = the existing gateway (`server/`) with `MUSA_CONTROL_PROFILE=companion`: generic project
  roots, no workspace password, own config/data dirs (`~/.config/musa-companion`, `~/.local/share/musa-companion`),
  loopback only, refuses to run as root. CLI `musa-companion` (start, install-service, token, pair, link, unlink, doctor).
  Linux and macOS natively. Windows runs it inside WSL2.
* **Cloud** (`cloud/`): accounts (email + password with scrypt, Sign in with Apple verified against Apple's JWKS),
  sessions with revoke, machines linked by one-time code, relay (HTTP, SSE and WebSockets multiplexed over the companion's
  outbound socket), push fan-out with one APNs key, audit log, rate limits, export and full deletion. No admin
  HTTP API (`node src/cli.js` on the server only).
* **Personal setup**: the old pairing is migrated in place to a "Musa Studios VPS" machine (same Keychain item,
  no re-pairing). The cloud has no knowledge of the personal gateway, and public accounts have no route to it. The
  VPS-specific project roots now live in the private `~/.config/musa-control/config.json` (same values as before).

## Isolation and security (where it's enforced)

| Concern | Enforcement |
|---|---|
| One account reaching another's machine | `cloud/src/machines.js` `owned()` on every relayed request and socket; unknown and foreign machines both return 404 |
| Forged relay requests to a companion | in-memory relay secret + owner id check (`server/src/auth.js`); a wrong secret never falls through to token auth |
| Other OS users on a shared VPS | companion per OS user, loopback only, token required; API keys passed via a 0600 env file, never argv |
| Stolen session | revoke in the app (Account → devices), which also closes its relay sockets; sliding 60-day expiry |
| SSH MITM on first connect | the host key is captured and shown before any password is sent; pinned afterwards |
| Provider credentials | never requested. Each CLI signs in with its own login on the machine; only status is read |
| Sensitive actions | `confirm: true` for push/pull/CI/end agent/install; risky approvals are review-only in notifications |

Tests: `cd server && npm test` (32), `cd cloud && npm test` (16: two real accounts, isolation, Apple token forgery,
relay HTTP/SSE/terminal, revocation, push routing, deletion). iOS unit + UI tests in `ios.yml`.

## What needs you (each step is one command, ready to run)

1. **Build**: GitHub refuses macOS jobs on private MusaInc (billing). Either fix billing, or publish the cleaned
   history as a new public repo, which gets free macOS runners:
   `tools/publish_public_repo.sh MusaInc/musa-control /path/to/AuthKey_<AdminKeyId>.p8`.
   It refuses to run if any commit still names client work (the check terms are private, in
   `~/.config/musa-control/private-terms`), creates the repo, pushes `main` + `multi-user`, and sets the 4 secrets
   and `BUILD_BASE`. The existing private repo stays private: its old commits and Actions logs aren't scrubbed.
2. **Account service**: `bash deploy/install-cloud.sh` (hardened systemd unit on 127.0.0.1:8180, Caddy route
   `/control-cloud/*` with backup/validate/rollback, packs the companion for one-line installs, smoke tests).
   It also serves the privacy and support pages linked from the app.
3. **APNs key** for public users' pushes: `~/.config/musa-control-cloud/apns.json` (keyFile/keyId/teamId).
4. **Sign in with Apple** capability: added to the entitlements; automatic signing registers it on the next signed
   build. Optional `apple.revoke` in the cloud config (a Sign in with Apple key) so account deletion also revokes the Apple token.
5. **Reviewer demo**: `bash deploy/review-demo/setup.sh` (Docker, unprivileged user, 1 CPU/1 GB, no host mounts,
   no capabilities). It's verified against a local cloud: it links, comes online through the relay, and shows its sample project.
6. **Personal gateway**: restart it when convenient (`sudo systemctl restart musa-control`) for the new routes.
   Its client-specific roots now live in the private `~/.config/musa-control/config.json` (same values).

## TestFlight: external testers (friends)

See `docs/TESTFLIGHT_EXTERNAL.md` (paste-ready Test Information, review notes, order of steps).

## Known limits (stated plainly)

* No email verification or password reset yet (no mail service). Sign in with Apple is the recommended path.
* The relay sees request contents in transit (TLS on both legs, not end to end). SSH machines are end-to-end encrypted.
* Gemini approval parsing is built from real Gemini CLI 0.68 dialog captures (trust, auth). Tool-approval
  screens weren't captured (that needs a signed-in Gemini account), so check them on first use.
* Native Windows (outside WSL) isn't supported: no tmux. The wizard says so and offers WSL.
* The iOS code for multi-machine has not compiled yet (CI blocked). It parses cleanly with Swift 6.1, but type
  errors are only caught by the macOS build.
