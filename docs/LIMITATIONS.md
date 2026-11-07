# Known limitations (v0.2)

Stated plainly so nothing is mistaken for working when it isn't.

* **Push needs an APNs key on the server.** The gateway sends real APNs pushes (approvals with
  Approve/Reject, agents waiting for input, finished turns, errors, builds, server alerts) once
  `~/.config/musa-control/apns.json` points at an *Apple Push Notifications service key* (.p8, from
  developer.apple.com → Keys; one key covers every app in the team). See `docs/PUSH.md`. Until then
  the app falls back to the live stream while open and iOS background refresh (~15 min at best).
  The App ID also needs the Push Notifications capability (Xcode's automatic signing adds it on the
  next signed build). Not yet verified on a physical iPad.
* **Approving from a notification** works only for plain yes/no prompts whose full command is visible.
  Folder-trust prompts, high-risk commands (deletes, force pushes, sudo, deploys/publishing, secrets,
  service restarts…) and commands the agent's screen shows only partly arrive without buttons and
  open the app. Each Approve/Reject needs Face ID/passcode, works once, only while that exact prompt
  is still on screen, and expires after 15 minutes.
* **Approvals depend on the agent running inside tmux.** Sessions launched from Musa Control
  always are. Agents started elsewhere (VS Code, a plain SSH shell, the dashboard's own runners) are
  monitored from their transcripts but can't be typed into or approved from the app. Prompt
  detection reads the TUI screen (Claude Code 2.1, Codex 0.166). A major TUI redesign could need
  a parser update; the gateway's tests hold real captures of both.
* **Agent ↔ project attribution** uses the session's working directory, or, for sessions started
  from `~`, the project its edits and commands touch most (marked `projectInferred`).
* **Dev-server previews** go through the gateway's HTTP proxy under a custom URL scheme. Page loads,
  assets, fetch/XHR and reload work. WebSocket-based hot reload (Vite HMR) doesn't, so use Reload.
  Cookies set by a dev server aren't kept.
* **Native iOS projects** have no live simulator view: the VPS has no Mac. The app never shows a web
  preview in place of a native simulator.
* **Remote desktop** quality depends on the network. noVNC uses Tight/ZRLE. Expect ~100–300 ms over
  mobile data. Text input in control mode goes through noVNC (hardware keyboard) or the keyboard bar.
* **File revisions** are captured only while a workspace is "watched" (opened in the app or touched by
  an agent in the last 30 minutes, at most 6 projects at once). Edits made while nothing watched the
  project show up in git diffs, not in the revision timeline. Files over 600 KB aren't snapshotted.
* **Builds** run only the commands a project defines (npm scripts, `tools/*.sh`, `scripts/*.sh`, Godot tests).
* **SSH file transfer** goes through the gateway's upload/download (not SFTP).
* **Export compliance**: the build declares no non-exempt encryption (it uses standard TLS and SSH only).
  Before any public release, confirm this classification for an SSH client.
* **UI-test screenshots** use sample data (`tools/make_fixtures.py`), because GitHub's simulator can't
  reach the VPS. Real behaviour is verified by the gateway's integration tests on the server, plus your
  own testing on the iPad.
