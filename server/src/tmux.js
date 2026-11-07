// tmux control: the persistence layer for agents, builds and terminals.
// Sessions live on the server independent of the iPad, so a dropped
// connection never kills work.
import { run, must } from "./exec.js";

const NAME = /^[A-Za-z0-9_.:@%-]{1,80}$/;
const check = (t) => { if (!NAME.test(String(t))) throw Object.assign(new Error("Bad tmux target"), { status: 400 }); return String(t); };

export async function listSessions() {
  const r = await run("tmux", ["list-sessions", "-F", "#{session_name}\t#{session_created}\t#{session_attached}\t#{session_windows}\t#{session_activity}"]);
  if (r.code !== 0) return [];
  return r.stdout.split("\n").filter(Boolean).map((l) => {
    const [name, created, attached, windows, activity] = l.split("\t");
    return { name, created: +created * 1000, attached: +attached, windows: +windows, activity: +activity * 1000 };
  });
}

export async function listPanes() {
  const r = await run("tmux", ["list-panes", "-a", "-F", "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_dead}\t#{pane_width}x#{pane_height}"]);
  if (r.code !== 0) return [];
  return r.stdout.split("\n").filter(Boolean).map((l) => {
    const [session, win, pane, id, pid, cmd, cwd, dead, size] = l.split("\t");
    return { session, window: +win, pane: +pane, id, pid: +pid, command: cmd, cwd, dead: dead === "1", size };
  });
}

export async function newSession(name, cwd, command, { width = 200, height = 50, env = {} } = {}) {
  check(name);
  const args = ["new-session", "-d", "-s", name, "-x", String(width), "-y", String(height), "-c", cwd];
  for (const [k, v] of Object.entries(env)) args.push("-e", `${k}=${v}`);
  args.push(command);
  // remain-on-exit is set in the same tmux invocation, before the server
  // handles the child's exit, so a program that fails instantly (bad PATH,
  // bad flag) leaves its error on screen instead of taking the session with it.
  args.push(";", "set-option", "-t", name, "remain-on-exit", "on", ";", "set-option", "-t", name, "history-limit", "50000");
  await must("tmux", args);
}

export async function sessionInfo(name) {
  const r = await run("tmux", ["display-message", "-p", "-t", check(name), "#{session_attached}\t#{window_width}\t#{window_height}\t#{pane_dead}\t#{pane_dead_status}"]);
  if (r.code !== 0) return null;
  const [attached, w, h, dead, status] = r.stdout.trim().split("\t");
  return { attached: +attached, width: +w, height: +h, dead: dead === "1", status: status === "" ? null : Number(status) };
}

// Gives a detached session's window a fixed size again. A narrow client (an
// iPad terminal in a side panel) that attached and left behind a 40-column
// window makes TUIs collapse their output, which also hides approval details.
export async function restoreSize(name, width, height) {
  await run("tmux", ["resize-window", "-t", check(name), "-x", String(width), "-y", String(height)]);
  // resize-window pins the size; hand sizing back to clients for next attach.
  await run("tmux", ["set-option", "-w", "-u", "-t", name, "window-size"]);
}

export async function hasSession(name) { return (await run("tmux", ["has-session", "-t", check(name)])).code === 0; }

export async function capture(target, { lines = 60, ansi = false } = {}) {
  const args = ["capture-pane", "-p", "-J", "-t", check(target), "-S", `-${Math.min(Math.max(+lines || 60, 1), 5000)}`];
  if (ansi) args.splice(2, 0, "-e");
  const r = await run("tmux", args);
  return r.code === 0 ? r.stdout : null;
}

export async function paneDead(target) {
  const r = await run("tmux", ["display-message", "-p", "-t", check(target), "#{pane_dead}\t#{pane_dead_status}"]);
  if (r.code !== 0) return { exists: false };
  const [dead, status] = r.stdout.trim().split("\t");
  return { exists: true, dead: dead === "1", status: status === "" ? null : Number(status) };
}

// Literal text, then Enter as a separate key so TUIs treat it as submit.
export async function sendText(target, text, { enter = true } = {}) {
  check(target);
  const body = String(text).replace(/\r\n?/g, "\n");
  if (body) {
    // Paste via a tmux buffer: multi-line prompts arrive as one bracketed paste.
    await must("tmux", ["set-buffer", "-b", "mc-input", body]);
    await must("tmux", ["paste-buffer", "-p", "-d", "-b", "mc-input", "-t", target]);
  }
  if (enter) { await new Promise((r) => setTimeout(r, 120)); await must("tmux", ["send-keys", "-t", target, "Enter"]); }
}

const KEYS = new Set(["Enter", "Escape", "Up", "Down", "Left", "Right", "Tab", "BTab", "C-c", "C-d", "C-z", "C-l", "Space", "BSpace", "y", "n", "1", "2", "3", "4"]);
export async function sendKeys(target, keys) {
  check(target);
  for (const k of keys) {
    if (!KEYS.has(k)) throw Object.assign(new Error(`Key ${k} not allowed`), { status: 400 });
    await must("tmux", ["send-keys", "-t", target, k]);
    await new Promise((r) => setTimeout(r, 60));
  }
}

export async function kill(name) { await run("tmux", ["kill-session", "-t", check(name)]); }
