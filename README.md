# Musa Control

Native iPad workstation for the Musa Studios VPS: watch and drive Claude Code / Codex agents,
real SSH terminals (tmux-backed), live file changes and diffs, the agents' screenshots, the
remote desktop, live previews, git, builds and GitHub Actions — from one app.

```
iPad app (SwiftUI)  ──HTTPS (device token)──▶  Caddy /control/*  ──▶  musa-control gateway (Node, 127.0.0.1:8160)
        │                                                                   ├─ agents: Claude/Codex transcripts, tmux, approvals
        │                                                                   ├─ files, live revisions, screenshots, git, gh, builds
        │                                                                   └─ VNC bridge → localhost x11vnc (view-only by default)
        └──────────────SSH (Ed25519 key in Keychain, pinned host key)──────▶  sshd → tmux sessions
```

* `server/` – the gateway (`npm test`; runs as `musa-control.service`).
* `ios/` – the app (XcodeGen `project.yml`; built only on GitHub macOS runners).
* `.github/workflows/ios.yml` – simulator build + unit/UI tests (screenshots artifact);
  dispatch with `testflight: true` to upload a signed build.
* `deploy/` – systemd unit, Caddy route snippet and its installer.
* `docs/` – architecture, testing and limitations.
