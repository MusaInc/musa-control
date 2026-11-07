# Push notifications

The gateway sends APNs pushes so approvals and results reach the iPad while Musa Control is
closed, suspended or the device is locked.

## What notifies

| Category | Event | Buttons |
|---|---|---|
| Approval requests | an agent's TUI shows a permission prompt | Approve · Reject · Review (or Review only, see below) |
| Waiting for you | a turn ended with a question | – |
| Finished tasks | Codex task complete / Claude turn ≥ 30 s | – |
| Errors | agent errors (not retries; routine failed commands never notify) | – |
| Builds & CI | project builds, GitHub Actions runs | – |
| Server alerts | services down, disk nearly full | – |

Per-device preferences (categories, sounds, muted projects and agents) live on the gateway
(`push_devices`), set from Settings → Notifications, so filtering works while the app is closed.
Bursts are limited to one push per session and category every 45 s (approvals are never limited).

## Approve from the lock screen: safety rules

* Approve/Reject use `UNNotificationActionOptions.authenticationRequired`: Face ID or the passcode first.
* Every approval push carries a one-time token (stored hashed in `push_actions`) bound to the device,
  the agent session and the prompt's signature. The gateway claims it before pressing any key, so a
  double tap or a replay can't answer twice. It expires after 15 minutes, and is invalidated as soon
  as the prompt is answered elsewhere or disappears.
* At answer time the gateway re-reads the agent's screen and refuses if the prompt changed.
* *Review only* (no buttons): folder-trust prompts, high-risk commands (see `HIGH_RISK` in
  `server/src/push.js`), prompts whose command is folded/hidden on screen, and prompts without a plain
  yes/no pair. "Approve" never picks "don't ask again"/"always" options.
* When an approval is answered (anywhere) a silent push withdraws the stale notification.

## Server setup (one time)

1. developer.apple.com → Certificates, IDs & Profiles → Keys → **+** → enable *Apple Push
   Notifications service (APNs)* → download `AuthKey_<KEYID>.p8` (only downloadable once). An existing
   team APNs key works too: APNs keys aren't tied to one app.
2. Put it outside any repo, e.g. `~/.config/musa-control/AuthKey_<KEYID>.p8` (chmod 600).
3. Create `~/.config/musa-control/apns.json`:
   ```json
   { "keyFile": "~/.config/musa-control/AuthKey_<KEYID>.p8", "keyId": "<KEYID>", "teamId": "<TEAMID>",
     "topic": "uk.co.musastudios.musacontrol" }
   ```
4. `sudo systemctl restart musa-control`. Settings → Notifications on the iPad should then say
   "Instant push"; use *Send a test notification*.

The app reports its APNs environment itself (development-signed builds → sandbox, TestFlight/App
Store → production).

## API

`GET /api/push` · `POST /api/push/register {token, environment, prefs}` · `PUT /api/push/prefs` ·
`POST /api/push/test` · `POST /api/push/action {nonce, action: approve|reject}` (device token auth).
