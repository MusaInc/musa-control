// Remote desktop access. Lists the X displays on the VPS (the Live Work
// browser on :99 plus agents' Xvfb displays), starts a localhost-only x11vnc
// on demand for displays that have none, and bridges an authenticated
// WebSocket to it. No VNC port is ever exposed: x11vnc binds 127.0.0.1 and
// the only way in is through this gateway behind Caddy/TLS.
//
// Observe mode uses a view-only x11vnc, so input is refused by the server
// itself, not just hidden in the UI. Control mode is an explicit choice.
import net from "node:net";
import { spawn } from "node:child_process";
import { run } from "./exec.js";

export function createVnc(cfg, events) {
  const spawned = new Map(); // `${display}:${mode}` → {proc, port, clients, idleTimer}
  const starting = new Map();
  const clients = new Map(); // display → Set({mode, device, since})

  async function displays() {
    const r = await run("ps", ["-eo", "pid=,args=", "--cols", "600"]);
    const out = [];
    for (const line of r.stdout.split("\n")) {
      const m = line.match(/^\s*(\d+)\s+(\S*\/)?(Xvfb|Xvnc|Xorg)\s+:(\d+)(.*)$/);
      if (!m) continue;
      const display = m[4], rest = m[5];
      const geo = rest.match(/-screen\s+\d+\s+(\d+)x(\d+)/);
      const auth = rest.match(/-auth\s+(\S+)/)?.[1] || null;
      const known = cfg.vnc.known[display];
      const owner = await describeOwner(+m[1], display);
      out.push({
        display, pid: +m[1], width: geo ? +geo[1] : null, height: geo ? +geo[2] : null, auth,
        label: known?.label || owner.label, purpose: owner.purpose, native: Boolean(known),
        viewers: [...(clients.get(display) || [])].map((c) => ({ mode: c.mode, device: c.device, since: c.since })),
        controlledBy: [...(clients.get(display) || [])].some((c) => c.mode === "control") ? "Musa Control (you)" : known ? "Shared with Live Work agents" : "Agent process",
      });
    }
    return out.sort((a, b) => (a.native === b.native ? +a.display - +b.display : a.native ? -1 : 1));
  }

  // What is drawing on this display: the parent of Xvfb (xvfb-run → its command).
  async function describeOwner(pid, display) {
    if (cfg.vnc.known[display]) return { label: cfg.vnc.known[display].label, purpose: "browser" };
    const r = await run("ps", ["-o", "ppid=", "-p", String(pid)]);
    const ppid = r.stdout.trim();
    if (ppid === "1") return { label: `Idle display :${display}`, purpose: "idle" };
    const kids = await run("ps", ["-eo", "ppid=,args=", "--cols", "300"]);
    const sibling = kids.stdout.split("\n").map((l) => l.trim().match(/^(\d+)\s+(.*)$/)).filter(Boolean)
      .find((m) => m[1] === ppid && !/Xvfb|xvfb-run|xauth/.test(m[2]));
    const cmd = sibling?.[2] || "";
    const label = /godot/i.test(cmd) ? "Godot render" : /chrom|playwright|firefox/i.test(cmd) ? "Browser" : cmd ? cmd.split(/\s+/)[0].split("/").pop() : `Display :${display}`;
    return { label: `${label} (:${display})`, purpose: /godot/i.test(cmd) ? "game" : "app", command: cmd.slice(0, 200) };
  }

  async function ensureServer(display, mode) {
    const known = cfg.vnc.known[display];
    if (known && mode === "control") return known.port;
    const key = `${display}:${mode}`;
    const s = spawned.get(key);
    if (s && s.proc.exitCode === null) { clearTimeout(s.idleTimer); return s.port; }
    if (starting.has(key)) return starting.get(key);
    const pending = startDisplay(display, mode, key);
    starting.set(key, pending);
    try { return await pending; }
    finally { starting.delete(key); }
  }

  async function startDisplay(display, mode, key) {
    const d = (await displays()).find((item) => item.display === display);
    if (!d) throw Object.assign(new Error(`Display :${display} isn't running`), { status: 404 });
    const args = ["-display", `:${display}`, "-autoport", String(cfg.vnc.spawnPortBase), "-localhost",
      "-shared", "-forever", "-nopw", "-quiet", "-noxrecord", "-noxfixes", "-noxdamage", "-nobell"];
    if (d.auth) args.push("-auth", d.auth);
    if (mode !== "control") args.push("-viewonly");
    const proc = spawn("x11vnc", args, { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    proc.stderr.on("data", chunk => { stderr = (stderr + chunk).slice(-2000); });
    const port = await new Promise((resolve, reject) => {
      let stdout = "";
      const finish = (error, value) => {
        clearTimeout(timer);
        proc.stdout.off("data", readPort);
        proc.off("exit", onExit);
        if (error) { proc.kill(); reject(Object.assign(error, { status: 502 })); }
        else resolve(value);
      };
      const readPort = chunk => {
        stdout = (stdout + chunk).slice(-400);
        const match = /^PORT=(\d+)$/m.exec(stdout);
        if (match) finish(null, Number(match[1]));
      };
      const onExit = () => finish(new Error(stderr.trim().split("\n").pop() || "x11vnc exited"));
      const timer = setTimeout(() => finish(new Error("x11vnc did not report a listening port")), 6500);
      proc.stdout.on("data", readPort);
      proc.once("error", finish);
      proc.once("exit", onExit);
    });
    spawned.set(key, { proc, port, idleTimer: null });
    return port;
  }

  function release(display, mode) {
    const key = `${display}:${mode}`, s = spawned.get(key);
    if (!s) return;
    clearTimeout(s.idleTimer);
    s.idleTimer = setTimeout(() => {
      const still = [...(clients.get(display) || [])].some((c) => c.mode === mode);
      if (!still) { s.proc.kill(); spawned.delete(key); }
    }, cfg.vnc.idleStopSeconds * 1000);
  }

  // ws: an accepted WebSocket (binary). Pipes RFB bytes both ways.
  async function bridge(ws, { display, mode, device }) {
    const port = mode === "control" || !cfg.vnc.known[display] ? await ensureServer(display, mode) : await ensureServer(display, "observe");
    if (ws.readyState !== 1) { release(display, mode); return; }
    const sock = net.connect(port, "127.0.0.1");
    const entry = { mode, device: device?.name || "device", since: Date.now() };
    if (!clients.has(display)) clients.set(display, new Set());
    clients.get(display).add(entry);
    events.emit({ kind: "vnc.connected", title: `${entry.device} ${mode === "control" ? "controlling" : "watching"} display :${display}`, detail: { display, mode }, persist: mode === "control" });
    sock.setNoDelay(true);
    sock.on("data", (d) => { if (ws.readyState === 1) ws.send(d); });
    ws.on("message", (d) => sock.write(d));
    let closed = false;
    const close = () => {
      if (closed) return;
      closed = true;
      sock.destroy(); try { ws.close(); } catch {}
      clients.get(display)?.delete(entry);
      if (!clients.get(display)?.size) clients.delete(display);
      release(display, mode);
    };
    sock.on("error", close); sock.on("close", close);
    ws.on("close", close); ws.on("error", close);
  }

  function closeAll() { for (const s of spawned.values()) s.proc.kill(); spawned.clear(); }
  return { displays, bridge, closeAll };
}
