// Terminal over WebSocket, for machines the app reaches through the relay
// (no inbound SSH). Each connection attaches to a named tmux session through
// a small pty helper, so work keeps running when the socket drops, exactly
// like the SSH terminal. Binary frames are terminal bytes; text frames are
// JSON control messages ({"type":"resize","cols":120,"rows":36}).
import { spawn } from "node:child_process";
import path from "node:path";
import fs from "node:fs";

const NAME = /^[A-Za-z0-9_.:@%-]{1,80}$/;
const HELPER = new URL("../bin/pty-helper.py", import.meta.url).pathname;

export function createTerminal(cfg, projects, events) {
  const live = new Set();

  function attach(ws, { session, project, dir, cols = 120, rows = 36, device }) {
    if (!NAME.test(String(session || ""))) { ws.close(1008, "Bad session name"); return; }
    let cwd = cfg.home;
    if (project) { try { cwd = projects.get(project).path; } catch {} }
    // A starting folder the app asks for: only inside the user's home.
    if (dir) { const d = path.resolve(String(dir)); if ((d === cfg.home || d.startsWith(cfg.home + path.sep)) && fs.existsSync(d) && fs.statSync(d).isDirectory()) cwd = d; }
    const py = cfg.python3 || "python3";
    const args = [HELPER, String(clamp(cols, 10, 1000)), String(clamp(rows, 4, 500)), "tmux", "new-session", "-A", "-s", String(session), "-c", cwd];
    const child = spawn(py, args, { cwd, stdio: ["pipe", "pipe", "pipe", "pipe"], env: { ...process.env, TERM: "xterm-256color" } });
    live.add(child);
    events?.emit({ kind: "terminal.attached", title: `Terminal ${session} opened from ${device?.name || "the app"}`, detail: { session }, persist: false });
    child.stdout.on("data", (d) => { if (ws.readyState === 1) ws.send(d, { binary: true }); });
    child.stderr.on("data", (d) => { if (ws.readyState === 1) ws.send(Buffer.from(`\r\n\x1b[2m${String(d).trim()}\x1b[0m\r\n`), { binary: true }); });
    child.on("error", (e) => { try { ws.close(1011, `Terminal helper failed: ${e.message}`.slice(0, 100)); } catch {} });
    child.on("close", () => { live.delete(child); try { ws.close(1000, "Session detached"); } catch {} });
    ws.on("message", (data, isBinary) => {
      if (isBinary) { child.stdin.write(data); return; }
      try {
        const m = JSON.parse(String(data));
        if (m.type === "resize") child.stdio[3].write(`${clamp(m.cols, 10, 1000)} ${clamp(m.rows, 4, 500)}\n`);
        else if (m.type === "input" && typeof m.data === "string") child.stdin.write(m.data);
      } catch {}
    });
    ws.on("close", () => { try { child.kill("SIGTERM"); } catch {} }); // detaches tmux; the session lives on
  }

  function available() { return fs.existsSync(HELPER); }
  function closeAll() { for (const c of live) try { c.kill("SIGTERM"); } catch {} }
  return { attach, available, closeAll };
}

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.round(Number(v) || lo)));
