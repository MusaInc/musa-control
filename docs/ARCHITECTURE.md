# Architecture

## Pieces

| Piece | Where | Role |
|---|---|---|
| **iPad app** | `ios/` (SwiftUI, iOS 17+, iPad only) | The workstation UI. Talks HTTPS to the gateway and SSH to the server. |
| **Gateway** | `server/` (Node 22, `musa-control.service`, 127.0.0.1:8160) | One authenticated API over everything on the VPS. |
| **Caddy route** | `/control/*` on musastudios.co.uk | TLS termination; strips `/control` and proxies to the gateway (installed by `deploy/install-caddy-route.sh`). |
| **sshd + tmux** | the VPS | Real terminals. Every app terminal is a tmux session, so work survives disconnects. |

Nothing important runs on the iPad. Agents, builds, terminals and the desktop live on the server.
The app is a window onto them, so losing the network or iOS suspending the app never stops work.

## Reused infrastructure (not duplicated)

* **Workspace password**: pairing checks the dashboard's existing bcrypt hash
  (its path is set in the private config file) and stores nothing new about it.
* **Agent CLIs**: the installed `claude` (2.1.x) and `codex` (0.166) run as normal interactive TUIs
  in tmux. Their own transcripts (`~/.claude/projects`, `~/.codex/sessions`) are the source of
  structured activity, so sessions started anywhere (VS Code, a terminal, the dashboard) show up too.
* **Live Work desktop**: the existing Xvfb :99 + x11vnc (:5901) used by the dashboard's Live Work agents.
  Agents' other Xvfb displays get an on-demand, localhost-only x11vnc.
* **noVNC 1.6** (`/usr/share/novnc`) for the RFB client inside a WKWebView.
* **GitHub**: the VPS's authenticated `gh` CLI. No GitHub token reaches the app.
* **Signing**: the same Admin App Store Connect key and cloud-signing flow as CitySwing's TestFlight workflow.
* **Public previews**: the existing Caddy routes (`/cityswing/`, `/neverstop/`, `/reso/`, `/portfolio/` …).

## Authentication & security

* **Pairing**: password → random device token (`mc_…`). Only its SHA-256 is stored server-side (SQLite,
  0600). The token lives in the iOS Keychain (this-device-only). Tokens expire after 90 days and
  can be revoked from the app or with `node src/cli.js revoke <id>`. Login attempts are rate-limited
  per client IP (5 per 15 minutes).
* **Every endpoint** except `/api/ping` and `/api/pair` needs the token. Web views get a separate 8-hour,
  HttpOnly, path-scoped cookie that only unlocks pages and media (`/vnc.html`, `/novnc`, `/static`,
  raw files, screenshot images), never the JSON API.
* **SSH**: the iPad makes its own Ed25519 key (Keychain). The gateway adds only the public key to
  `~/.ssh/authorized_keys`, tagged `musa-control:<device>`, and removes it when the device is revoked.
  Host-key fingerprints come from the gateway over TLS and are pinned. A mismatch refuses the connection.
* **Files**: every path is resolved inside its project (`..`, absolute paths and symlinks out are refused).
  `.env*`, keys, keystores, provisioning profiles and `.ssh/` are never served or written. Saves are
  optimistic-concurrency checked (the client sends the SHA it edited). Deletes go to a trash with restore.
* **VNC**: x11vnc only ever listens on 127.0.0.1. The gateway bridges an authenticated WebSocket to it.
  Observe mode connects to a `-viewonly` server, so input is refused by the server, not just hidden.
* **Agents**: approvals are answered by pressing the TUI's own keys for the option you tap, after
  re-checking that the same prompt is still on screen. The gateway never changes an agent's permission mode.
  Only sessions launched from the app can be ended from it.
* **Publishing actions** (git push/pull, CI re-run/cancel/dispatch, ending an agent) need `confirm: true`,
  which the app only sends from a confirmation dialog.
* **Preview proxy**: only ports owned by a process running inside a project directory, so
  CDP (9222), Caddy admin (2019), VNC and databases are unreachable through it.
* Builds can only run commands the project defines (npm scripts, `tools/*.sh`, `scripts/*.sh`, Godot tests).
  Arbitrary shell belongs in the SSH terminal.

## Gateway modules (`server/src`)

`config` · `db` (SQLite: devices, events, revisions, screenshots, managed agents, builds) · `auth` ·
`events` (timeline + SSE with Last-Event-ID replay) · `projects` (discovery + path safety) · `files` ·
`git` · `watcher` (inotify per active workspace → revisions with line counts) · `diff` (Myers, unified) ·
`screenshots` · `transcripts` (Claude/Codex line parsers) · `prompts` (TUI approval detection) ·
`agents` (supervisor) · `tmux` · `vnc` · `builds` · `github` · `system` · `ssh` · `server` (routes).

## App structure (`ios/MusaControl`)

* `App/` – `AppModel` (connection, cached state, live events, Follow Agent focus), app entry, keyboard commands.
* `Core/` – gateway client, SSE stream, models, Keychain, notifications, diff parser, syntax highlighter,
  authenticated image cache, fixture transport (UI tests only).
* `SSH/` – Citadel (swift-nio-ssh) connections, pinned host keys, SwiftTerm terminal sessions on tmux.
* `Views/` – sections (Home, Workspaces, Agents, Terminal, Files, Visuals, Git & Builds, Settings),
  the workspace panel engine, Follow Agent, evidence views and shared components.

## Event model

Every observable change becomes one timeline row and one SSE message:
`agent.prompt|message|command|command_done|command_failed|test|edit|image|tool|plan|approval|approval_answered|done|error|started|stopped|ended`,
`file.changed|saved|deleted|moved`, `screenshot.new`, `build.started|finished|cancelled`, `ci.finished|rerun|cancel|dispatch`,
`git.commit|push|pull`, `server.alert`, `vnc.connected`. Agent events carry a `follow` hint
(`diff`, `file`, `screenshot`, `vnc`, `preview`, `tests`, `approval`, `activity`), derived only from what the
agent actually did. Follow Agent never invents a visual.
