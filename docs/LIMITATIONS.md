# Known limitations (v0.1)

Stated plainly so nothing is mistaken for working when it isn't.

* **No instant push notifications while the app is closed.** Notifications come from the live
  event stream while the app runs, and from iOS background refresh (every ~15 min at best, at
  iOS's discretion) otherwise. Real APNs push needs an *Apple Push Notifications service key*
  (.p8, created at developer.apple.com → Keys) and a small sender in the gateway. App Store Connect
  API keys can't create one.
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
