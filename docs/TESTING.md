# Testing record (2026-11-07)

Kinds of evidence, never mixed up:
**[auto]** automated test, **[server e2e]** run against the live VPS from a real browser engine or CLI,
**[CI sim]** GitHub macOS runner + iPad simulator, **[device]** a physical iPad.
**Nothing has been tested on a physical iPad yet.**

## Gateway: `cd server && npm test` (20/20 pass on the VPS, also green in GitHub Actions on Ubuntu)

| Area | Evidence |
|---|---|
| Auth: no token / bad token / wrong password → 401, pairing with the workspace password, `/control` prefix | [auto] |
| Path escapes (`..`, symlinks out) refused; `.env` hidden and refused | [auto] |
| Save conflict: an agent edits after you open → 409 with their text; resolve → saved | [auto] |
| Delete → trash → restore | [auto] |
| File watcher → revisions with line counts and unified diffs, streamed over SSE | [auto] |
| New project image → screenshot row + ffmpeg thumbnail; app captures stored outside the project | [auto] |
| Git status, stage, commit, branches; push refused without confirmation (428) | [auto] |
| Builds in tmux with logs and exit codes; unknown commands refused | [auto] |
| Claude transcript → session, project, edit/test/failed-command/done events with `follow` hints | [auto] |
| Approval prompt in a tmux pane detected and answered by keystroke; stale answers refused (409) | [auto] (stand-in TUI that draws a real Claude Code capture) |
| Prompt parser on real captures of Claude Code 2.1.319 (command, folder trust) and Codex 0.166 (command); idle screens ignored | [auto] |
| Real approval round-trips: Claude Code and Codex in tmux each asked to run a command; answering by keys ran it | [server e2e] (manual probe while building the parser) |
| SSH: only valid ed25519 keys accepted, tagged per device, host-key fingerprints served | [auto] |
| Preview proxy reaches project dev servers only (gateway port refused) | [auto] |
| VNC WebSocket refuses unauthenticated upgrades | [auto] |
| Web-session cookie unlocks pages only, never the JSON API | [auto] |
| Diff engine vs GNU diff/patch, 300 random cases | [auto] (scratch fuzz) |
| **Remote desktop**: Chromium loads `/control/vnc.html`, connects through the authenticated bridge to the real Live Work display :99 in observe (view-only x11vnc on :5988) and control (:5901) modes; native bridge receives `connected` + `stats` (RTT 5 ms on loopback); page refused without cookie | [server e2e] |
| **Godot web preview**: NeverStop `build/web` served by `/control/static/…` with COOP/COEP; Chromium boots it (`crossOriginIsolated: true`) to the title screen | [server e2e] |
| Discovery on the real VPS: 27 projects, 17 Claude/Codex sessions (live one marked working, project inferred from edits), 4 X displays; `/api/overview` in ~70 ms, ~85 MB RSS | [server e2e] |

## iPad app (GitHub Actions, run 42378092088)

| Area | Evidence |
|---|---|
| Whole app compiles with Xcode 26.3 / iOS 26.2 SDK (SwiftTerm 1.20.0, Citadel 0.12.1) | [CI sim] |
| Unit tests 8/8: every gateway response shape decodes; SSE parser; diff line numbering; highlighter on 9 languages; SSH fingerprint == `ssh-keygen`; OpenSSH key wire format; layout normalise + per-project persistence | [CI sim] |
| UI tests (every section, landscape + portrait screenshots; navigation; launcher; workspace) | **not run yet**: GitHub refused to start the macOS job (account spending limit / failed payment) |
| SSH login, tmux attach/reconnect, terminal rendering on the iPad | **not tested**: needs a device or a simulator run against the VPS |
| VNC/preview inside WKWebView on iPadOS | **not tested on iPad**: the same page and protocol were verified in Chromium |
| Notifications, background refresh, Face ID lock | **not tested** |
| TestFlight upload | **not done**: blocked by the App Store Connect app record and GitHub billing (see the report) |

## Device checklist (for the first TestFlight build)

1. Pair with the workspace password → Home shows real agents, health, screenshots.
2. Settings → SSH → Set up. Then Terminal → New shell → `tmux ls`. Turn on airplane mode for 10 s,
   turn it off → the tab reconnects to the same tmux session.
3. New agent task (Claude Code, a scratch project, "touch a file") → approval card → Yes → file appears in Files.
4. Visuals → Remote Desktop → Observe, then Control (confirm) → click in the Live Work browser.
5. Open a workspace, rearrange panels, switch project and back → layout and terminals intact.
6. Edit a file while an agent edits it → conflict sheet appears.
