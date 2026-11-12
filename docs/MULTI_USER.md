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

## What needs you (external setup)

1. **Build**: GitHub refused macOS jobs on MusaInc (billing), run 43304365348. Either fix billing or make the repo
   public (history is scrubbed of client references: see "Publishing the repo" below).
2. **Deploy the cloud** (needs your approval: it's a new public endpoint): a systemd unit for `cloud/src/main.js`
   on 127.0.0.1:8180, a Caddy route (e.g. `/control-cloud/*` → strip prefix → 8180, with WebSocket upgrade), and
   `~/.config/musa-control-cloud/config.json` with `publicUrl`, `companionBundle` (from `tools/pack_companion.sh dist/musa-companion.tgz`).
   The app's default account server is `https://musastudios.co.uk/control-cloud`.
3. **APNs key** for public users' notifications: `~/.config/musa-control-cloud/apns.json` (keyFile/keyId/teamId).
4. **Sign in with Apple**: enable the capability on the App ID (automatic signing should add it on the next signed
   build). Optional `apple.revoke` (a Sign in with Apple key) so deleting an account also revokes Apple's token, which Apple asks for.
5. **Privacy policy and support pages** at `/control/privacy` and `/control/support` (linked from Settings). They're
   needed for external TestFlight and the App Store.
6. **Restart the personal gateway when convenient** (`sudo systemctl restart musa-control`) to get the new
   routes (providers, Gemini, capabilities). Until then the app falls back gracefully. It loads the new code on
   any restart anyway, and its behaviour is covered by the original 24 tests.

## TestFlight: external testers (friends)

1. After a green build: `gh workflow run ios.yml -f testflight=true -f version=0.4.0` (uploads to the existing app).
2. App Store Connect → TestFlight → External Testing → new group "Friends" → add the build → **Test Information**:
   beta description, feedback email, privacy policy URL, and **Beta App Review sign-in**: create a reviewer account
   on the cloud (email + password) with one linked demo machine (a small VPS or container running the companion
   with a sample repo) so the reviewer sees real agents. Without a machine the app shows only onboarding, which review rejects.
3. Review notes to include: what the app does; that it controls the user's own computers; AI providers sign in
   on the user's machine with their own login (no credentials pass through the app); remote commands only run
   in the user's own environment; account deletion is at Settings → Machines & AI → Account → Delete account.
4. Export compliance: the app uses TLS and SSH (standard encryption). `ITSAppUsesNonExemptEncryption=false` is
   the usual answer for standard protocols, but confirm it for an SSH client before public release.

## Known limits (stated plainly)

* No email verification or password reset yet (no mail service). Sign in with Apple is the recommended path.
* The relay sees request contents in transit (TLS on both legs, not end to end). SSH machines are end-to-end encrypted.
* Gemini approval parsing is built from real Gemini CLI 0.68 dialog captures (trust, auth). Tool-approval
  screens weren't captured (that needs a signed-in Gemini account), so check them on first use.
* Native Windows (outside WSL) isn't supported: no tmux. The wizard says so and offers WSL.
* The iOS code for multi-machine has not compiled yet (CI blocked). It parses cleanly with Swift 6.1, but type
  errors are only caught by the macOS build.
