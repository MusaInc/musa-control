# The workspace (0.5)

Musa Control on iPad is one workspace, not a set of screens.

```
┌ top bar ─ project ▾ · layouts · live agents · approvals · + Agent · Desktop · computer ▾ ┐
│ activity │ navigator      │ panels (split, resizable, rearrangeable)  │ Remote Desktop  │
│  Files   │ Files / Agents │  editor · terminal · agent · visualiser   │ (split, or      │
│  Agents  │ / Source       │  web preview · builds                     │  floating, full │
│  Git     │ Control        │                                           │  screen, mini)  │
└ status bar ─ connection · agents · desktop · minimised panels · keyboard focus ────────┘
```

- **Panels**: drag the divider to resize; drag a panel's header onto another
  panel to move it (top/bottom half: same column, left/right edge: new
  column); minimise to the status bar; maximise; close. Layouts are saved per
  project and per orientation. Presets: Code, Agent, Visualise, Review.
- **Navigator**: Files (browse + find file / search contents / symbols),
  Agents (needs you, working, paused, idle, recent; this project or all) and
  Source Control.
- **Sheets**: Machines & AI (computers, AI accounts, sign-in) and Settings
  open over the workspace, so running work and the desktop stay put.
- **iPhone**: the same workspace one panel at a time, plus Agents, Desktop
  and More tabs. The desktop stays connected as a thumbnail on other tabs.

## Remote Desktop

`DesktopStore` owns one WKWebView (and its VNC WebSocket) for the whole app.
Changing layout re-parents that view; nothing reconnects. The open display and
layout are restored on launch, and it reconnects when the app returns to the
foreground. Controls: display, Watch/Control, zoom (fit, 1:1, 150 %, 200 %;
drag pans when zoomed), quality, right/middle click, scroll, Ctrl+Alt+Del,
a keys bar (Esc, Tab, arrows, Home/End, PgUp/PgDn, F1–F12, sticky
Ctrl/Alt/Super, typing) and clipboard both ways (remote copies land on the
iPad clipboard; ⌘V pastes the iPad clipboard into the remote).

When an agent drives the browser, the desktop opens floating (or grows from
the mini thumbnail) unless you turned that off in its menu.

## Keyboard

Musa Control's own shortcuts use ⌘ with digits/symbols, ⇧⌘ or ⌃⌘. Everything
else goes to whatever has the keyboard (shown at the right of the status bar).

| Keys | Action |
|---|---|
| ⌘P / ⌘K | Quick Open file / go to project, agent or panel |
| ⇧⌘F, ⇧⌘E, ⇧⌘A, ⇧⌘G, ⌘0 | Find in project, Files, Agents, Source Control, toggle navigator |
| ⌘1…⌘9, ⌥⌘← / ⌥⌘→ | Focus panel N, previous / next panel |
| ⌃⌘1…⌃⌘4 | Code, Agent, Visualise, Review layouts |
| ⌃⌘E/T/A/V/W/B | Show editor, terminal, agent, visualiser, web preview, builds |
| ⌘T, ⌘D, ⌃⌘M, ⌃⌘W | New terminal, split (terminal below), maximise, close panel |
| ⇧⌘N, ⇧⌘L, ⌘. | New agent task, show agent activity, interrupt agent |
| ⌃⌘D, ⌃⌘\\, ⌃⌘P, ⌃⌘F, ⌃⌘J | Desktop on/off, beside, floating, full screen, mini |
| ⌃⌘C, ⌃⌘K, ⌃⌘V, ⌃⌘R | Desktop: control/watch, take keyboard, paste iPad clipboard, reconnect |

- **Terminal**: Ctrl+C/D/Z/R…, Esc, Tab, arrows (shell history), F-keys,
  PgUp/PgDn go to the shell; ⌘C/⌘V copy and paste; ⌘A selects all.
- **Editor**: ⌘S save, ⌘F find (and replace), ⌘Z/⇧⌘Z, ⌘L jump to line.
- **Remote Desktop in Control mode**: ⌘ letter shortcuts are sent as Ctrl
  (⌘C → Ctrl+C, ⌘V → paste iPad clipboard + Ctrl+V, ⇧⌘Z → Ctrl+Shift+Z,
  ⌘←/→ → Home/End). Turn this off in the desktop's mouse menu to send ⌘ as
  Super instead. ⌃⌘ and ⌘-digit shortcuts stay with Musa Control.

## Agent panel

Only real activity, as it happens: the file an agent opened (read from disk),
each edit (the agent's own diff, or the file watcher's revision diff, with
"Whole file" highlighting the changed lines), its live tmux screen while a
command runs and the output when it finishes, tests, captures, plan updates,
messages and what it published to the Visualiser. Following switches views as
events arrive; tapping a view or a step pauses following without touching the
agent. Pause freezes the agent's process tree (SIGSTOP) and Resume continues
it; sending an instruction or interrupting also resumes.

## Visualiser

Per-project folder `<dataDir>/visuals/<project>/`. Agents started from Musa get
`$MUSA_PREVIEW_DIR` and `musa-preview` on their PATH (and, if the launcher
option is on, one line in the first prompt saying so):

```
musa-preview chart.png scene.glb page.html   # copy in
musa-preview --link out/render.png           # link: every rewrite refreshes
musa-preview --dir                           # print the folder
```

Anything written there shows immediately and refreshes on change: images,
SVG, GIF, video, HTML apps (with relative assets), PDF, text, and 3D models
(glb/gltf/obj/stl/ply/dae in a three.js viewer; USDZ in Quick Look).
Captures (screenshots agents took or looked at) are a second tab.

Pages render through the app's `mcvisual://` scheme: a separate, cookie-less
origin that can only read this project's preview folder and the viewer, never
the gateway API.

**Python runs** (`POST /api/visuals/:project/run`, the ▶ button) execute in
bubblewrap with no network, a read-only root and project, writable only in
their own `runs/<id>/` folder, with a time limit. `plt.show()` saves figures
(animations as GIF), `Image.show()` and plotly `fig.show()` save files, and
anything else the script writes appears too. The machine's private Python
(`<dataDir>/python`, matplotlib + numpy + Pillow) is set up from the runner
sheet or `POST /api/visuals/setup`. Without a sandbox (no bwrap on Linux,
no sandbox-exec on macOS) runs are refused.
