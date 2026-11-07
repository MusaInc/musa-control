// Agent supervisor: every Claude Code and Codex session on the machine.
//
// * Sessions are discovered from the agents' own transcripts (Claude Code
//   ~/.claude/projects/<cwd>/<id>.jsonl, Codex ~/.codex/sessions/**), tailed
//   incrementally, and turned into timeline events. Existing sessions and
//   their history are only read, never modified.
// * Live processes are matched to sessions; when a process runs inside a
//   tmux pane, Musa Control can type into it, interrupt it, and answer its
//   on-screen approval prompts (only when the user taps an option).
// * Sessions launched from the app run as interactive TUIs in their own tmux
//   session (`mc-…`), so they survive app disconnects, and the agent's normal
//   permission prompts stay in force.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { run } from "./exec.js";
import * as tmux from "./tmux.js";
import { parsePrompt, keysFor } from "./prompts.js";
import { parseClaudeLine, parseCodexLine } from "./transcripts.js";
import { expand } from "./config.js";

export const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
const DAY = 86400_000;

export function createAgents(cfg, db, projects, events, { watcher, screenshots } = {}) {
  const sessions = new Map(); // key → session
  const files = new Map();    // transcript path → {key, offset, state, agent}
  const offsets = db.get("transcript-offsets", {});
  const managedRows = () => db.raw.prepare("SELECT * FROM managed_agents WHERE ended_at IS NULL").all();
  const claudeDir = expand(cfg.claudeProjectsDir), codexDir = expand(cfg.codexSessionsDir);
  let procs = [];   // live agent processes
  let panes = [];
  let timer = null, procTimer = null, promptTimer = null, saving = 0;

  // ---------- transcript discovery ----------
  async function listTranscripts() {
    const out = [];
    const since = Date.now() - 2 * DAY;
    try {
      for (const d of await fsp.readdir(claudeDir)) {
        const dir = path.join(claudeDir, d);
        let names = [];
        try { names = await fsp.readdir(dir); } catch { continue; }
        for (const n of names) {
          if (!n.endsWith(".jsonl")) continue;
          const f = path.join(dir, n);
          const st = await fsp.stat(f).catch(() => null);
          if (st && st.mtimeMs > since) out.push({ file: f, agent: "claude", mtime: st.mtimeMs, size: st.size });
        }
      }
    } catch {}
    for (let i = 0; i < 3; i++) {
      const d = new Date(Date.now() - i * DAY);
      const dir = path.join(codexDir, String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, "0"), String(d.getDate()).padStart(2, "0"));
      let names = [];
      try { names = await fsp.readdir(dir); } catch { continue; }
      for (const n of names) {
        if (!n.endsWith(".jsonl")) continue;
        const f = path.join(dir, n);
        const st = await fsp.stat(f).catch(() => null);
        if (st && st.mtimeMs > since) out.push({ file: f, agent: "codex", mtime: st.mtimeMs, size: st.size });
      }
    }
    return out;
  }

  function sessionFor(f, agent, state) {
    const id = state.sessionId || path.basename(f.file, ".jsonl");
    const key = `${agent}:${id}`;
    let s = sessions.get(key);
    if (!s) {
      s = { key, agent, sessionId: id, transcript: f.file, cwd: state.cwd || null, project: null, title: null, lastPrompt: null, lastMessage: null,
        lastActivity: f.mtime, startedAt: null, model: null, turn: "idle", counts: { edits: 0, commands: 0, images: 0, errors: 0 }, lastEvent: null, managed: null };
      sessions.set(key, s);
    }
    return s;
  }

  async function tail(f) {
    let rec = files.get(f.file);
    if (!rec) {
      // Start near the end for transcripts we've never read: history before the
      // gateway existed stays in the agent's own files.
      const known = offsets[f.file];
      const start = known !== undefined && known <= f.size ? known : Math.max(0, f.size - 384 * 1024);
      rec = { offset: start, state: {}, agent: f.agent, primed: known !== undefined, aligned: start === 0 || known !== undefined };
      files.set(f.file, rec);
      // Read the first line(s) for session metadata (cwd, id) when skipping ahead.
      if (start > 0) {
        const fh = await fsp.open(f.file, "r");
        try {
          const buf = Buffer.alloc(Math.min(64 * 1024, f.size));
          await fh.read(buf, 0, buf.length, 0);
          for (const line of buf.toString("utf8").split("\n").slice(0, 40)) {
            const parse = f.agent === "claude" ? parseClaudeLine : parseCodexLine;
            if (line.startsWith("{")) parse(line, rec.state);
            if (rec.state.cwd && rec.state.sessionId) break;
          }
        } finally { await fh.close(); }
      }
    }
    if (f.size < rec.offset) rec.offset = 0;
    if (f.size === rec.offset) { const s = rec.key && sessions.get(rec.key); if (s) s.lastActivity = Math.max(s.lastActivity, f.mtime); return; }
    const fh = await fsp.open(f.file, "r");
    let chunk;
    try {
      const len = Math.min(f.size - rec.offset, 8 * 1024 * 1024);
      chunk = Buffer.alloc(len);
      await fh.read(chunk, 0, len, rec.offset);
    } finally { await fh.close(); }
    let text = chunk.toString("utf8");
    const lastNl = text.lastIndexOf("\n");
    if (lastNl < 0) return;
    const consumed = Buffer.byteLength(text.slice(0, lastNl + 1));
    let lines = text.slice(0, lastNl + 1).split("\n");
    if (rec.offset > 0 && !rec.aligned) { lines = lines.slice(1); rec.aligned = true; } // drop the partial first line
    rec.offset += consumed;
    rec.aligned = true;
    const parse = f.agent === "claude" ? parseClaudeLine : parseCodexLine;
    const firstRead = !rec.primed;
    rec.primed = true;
    for (const line of lines) {
      if (!line.startsWith("{")) continue;
      const evs = parse(line, rec.state);
      const s = sessionFor(f, f.agent, rec.state);
      rec.key = s.key;
      absorb(s, rec.state, f);
      for (const ev of evs) record(s, ev, { quiet: firstRead });
    }
    offsets[f.file] = rec.offset;
    if (Date.now() - saving > 5000) { saving = Date.now(); db.set("transcript-offsets", offsets); }
  }

  function absorb(s, st, f) {
    s.cwd = st.cwd || s.cwd;
    if (s.cwd && !s.project) s.project = projects.forPath(s.cwd)?.id || null;
    s.title = st.title || s.title;
    s.lastPrompt = st.lastPrompt || s.lastPrompt;
    s.lastMessage = st.lastMessage || s.lastMessage;
    s.model = st.model || s.model;
    s.turn = st.turn || s.turn;
    s.lastActivity = Math.max(s.lastActivity || 0, f.mtime);
  }

  function record(s, ev, { quiet }) {
    // Resolve the project of the thing touched (edits outside the session cwd).
    const p = ev.detail?.path ? projects.forPath(ev.detail.path) : null;
    const project = p?.id || s.project;
    if (ev.kind === "agent.edit") {
      s.counts.edits++;
      if (p && watcher) { watcher.attribute(p.id, path.relative(p.path, ev.detail.path), s.key); if (!quiet) watcher.activate(p.id).catch(() => {}); }
    }
    if (ev.kind.startsWith("agent.command") || ev.kind === "agent.test") s.counts.commands++;
    if (ev.kind === "agent.error" || ev.kind === "agent.command_failed") s.counts.errors++;
    if (ev.kind === "agent.image") { s.counts.images++; screenshots?.consider(ev.detail.path, { project, session: s.key, source: "agent" }).catch(() => {}); }
    s.lastEvent = { kind: ev.kind, title: ev.title, ts: ev.ts, follow: ev.follow || null };
    const long = ev.kind === "agent.done" && (ev.detail?.durationMs ?? 60_000) >= 30_000;
    events.emit({
      kind: ev.kind, project, session: s.key, ts: ev.ts, title: ev.title,
      detail: { ...ev.detail, agent: s.agent, follow: ev.follow || null, sessionTitle: s.title },
      persist: ev.persist !== false, dedupe: `${s.key}:${ev.key}`,
      notify: !quiet && (ev.kind === "agent.error" || long),
    });
  }

  async function pollTranscripts() {
    try {
      const list = await listTranscripts();
      for (const f of list) await tail(f).catch((e) => console.error("tail", f.file, e.message));
    } catch (e) { console.error("transcripts", e); }
  }

  // ---------- processes + tmux ----------
  async function pollProcesses() {
    const r = await run("ps", ["-eo", "pid=,ppid=,lstart=,args=", "--cols", "800"]);
    const table = new Map();
    for (const line of r.stdout.split("\n")) {
      const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\w+\s+\w+\s+\d+\s+[\d:]+\s+\d+)\s+(.*)$/);
      if (m) table.set(+m[1], { pid: +m[1], ppid: +m[2], started: Date.parse(m[3]), args: m[4] });
    }
    const which = (args) => {
      const t = args.split(/\s+/);
      const first = path.basename(t[0] || "");
      if (/^(claude|codex)$/.test(first)) return first;
      if (/^(node|bun|bash|sh)$/.test(first) && t[1] && /\/(claude|codex)(\.js)?$|^(claude|codex)$/.test(t[1])) return t[1].match(/(claude|codex)/)[1];
      if (/\/codex\/codex$|codex-linux|codex-x86_64/.test(t[0])) return "codex";
      return null;
    };
    const agents = [];
    for (const p of table.values()) {
      const kind = which(p.args);
      if (!kind) continue;
      if (/\b(app-server|mcp-server|exec-server|mcp serve)\b/.test(p.args)) continue;
      const parent = table.get(p.ppid);
      if (parent && which(parent.args) === kind) continue; // native binary under its launcher
      let cwd = null;
      try { cwd = fs.readlinkSync(`/proc/${p.pid}/cwd`); } catch {}
      const ancestors = [];
      for (let a = table.get(p.ppid), n = 0; a && n < 15; a = table.get(a.ppid), n++) ancestors.push(a.pid);
      const explicit = p.args.match(/--(?:resume|session-id)[ =]([0-9a-f-]{36})/) || p.args.match(/\bresume\s+([0-9a-f-]{36})/);
      agents.push({ pid: p.pid, agent: kind, args: p.args, cwd, started: p.started, ancestors, sessionId: explicit?.[1] || null,
        print: / (-p|--print|exec)( |$)/.test(p.args) });
    }
    procs = agents;
    panes = await tmux.listPanes();
    link();
  }

  function link() {
    for (const s of sessions.values()) { s.pid = null; s.tmux = null; }
    const claimed = new Set();
    const ordered = [...procs].sort((a, b) => (b.sessionId ? 1 : 0) - (a.sessionId ? 1 : 0));
    for (const p of ordered) {
      let s = p.sessionId ? sessions.get(`${p.agent}:${p.sessionId}`) : null;
      if (!s) {
        // Most recently active unclaimed transcript of this agent in the same cwd.
        s = [...sessions.values()].filter((x) => x.agent === p.agent && x.cwd === p.cwd && !claimed.has(x.key) && x.lastActivity >= p.started - 60_000)
          .sort((a, b) => b.lastActivity - a.lastActivity)[0] || null;
      }
      const pane = panes.find((x) => x.pid === p.pid || p.ancestors.includes(x.pid));
      if (!s) {
        // A live agent that hasn't written a transcript yet (just launched).
        const key = `${p.agent}:pid-${p.pid}`;
        s = sessions.get(key) || { key, agent: p.agent, sessionId: null, transcript: null, cwd: p.cwd, project: projects.forPath(p.cwd)?.id || null, title: null,
          lastActivity: p.started, startedAt: p.started, counts: { edits: 0, commands: 0, images: 0, errors: 0 }, turn: "idle", pending: true };
        sessions.set(key, s);
      }
      claimed.add(s.key);
      s.pid = p.pid; s.mode = p.print ? "headless" : "interactive"; s.startedAt = s.startedAt || p.started;
      if (pane) s.tmux = { session: pane.session, pane: pane.id, target: pane.id };
    }
    // Drop placeholder records once their process is gone.
    for (const [k, s] of sessions) if (s.pending && !s.pid) sessions.delete(k);
    for (const row of managedRows()) {
      const s = [...sessions.values()].find((x) => x.tmux?.session === row.tmux) || (row.session_id && sessions.get(`${row.agent}:${row.session_id}`));
      if (s) { s.managed = { id: row.id, tmux: row.tmux }; s.tmux = s.tmux || { session: row.tmux, target: row.tmux }; if (!row.session_id && s.sessionId) db.raw.prepare("UPDATE managed_agents SET session_id=? WHERE id=?").run(s.sessionId, row.id); }
    }
  }

  // ---------- approvals ----------
  const prompts = new Map(); // session key → prompt
  async function pollPrompts() {
    for (const s of sessions.values()) {
      if (!s.tmux) { prompts.delete(s.key); continue; }
      const screen = await tmux.capture(s.tmux.target, { lines: 70 });
      const p = parsePrompt(screen);
      const prev = prompts.get(s.key);
      if (p) {
        prompts.set(s.key, { ...p, seenAt: prev?.signature === p.signature ? prev.seenAt : Date.now() });
        if (prev?.signature !== p.signature) {
          events.emit({ kind: "agent.approval", project: s.project, session: s.key, title: `${agentName(s.agent)} needs approval: ${p.question}`,
            detail: { ...p, agent: s.agent, follow: { view: "approval" }, sessionTitle: s.title }, notify: true, dedupe: `${s.key}:prompt:${p.signature}:${Math.floor(Date.now() / 600_000)}` });
          s.lastEvent = { kind: "agent.approval", title: p.question, ts: Date.now(), follow: { view: "approval" } };
        }
      } else if (prev) {
        prompts.delete(s.key);
        events.emit({ kind: "agent.approval_cleared", project: s.project, session: s.key, title: "Approval prompt closed", detail: { signature: prev.signature }, persist: false });
      }
    }
  }

  const agentName = (a) => (a === "claude" ? "Claude Code" : "Codex");

  function statusOf(s) {
    const p = prompts.get(s.key);
    if (p) return { status: "approval", text: p.question };
    const recent = Date.now() - (s.lastActivity || 0) < 10 * 60_000;
    if (s.pid) {
      if (s.turn === "working" && recent) return { status: "working", text: s.lastEvent?.title || "Working" };
      return { status: "idle", text: "Waiting for instructions" };
    }
    if (s.managed && s.tmux) return { status: "exited", text: "Agent exited; tmux session kept" };
    if (s.lastEvent?.kind === "agent.error") return { status: "failed", text: s.lastEvent.title };
    if (s.turn === "working" && Date.now() - (s.lastActivity || 0) < 90_000) return { status: "working", text: "Active (no local process; remote or headless)" };
    return { status: "ended", text: "Not running" };
  }

  function view(s) {
    const st = statusOf(s);
    return {
      id: s.key, agent: s.agent, agentName: agentName(s.agent), sessionId: s.sessionId, project: s.project, cwd: s.cwd, title: s.title || (s.cwd ? path.basename(s.cwd) : "Session"),
      lastPrompt: s.lastPrompt?.slice(0, 600) || null, lastMessage: s.lastMessage?.slice(0, 600) || null, status: st.status, statusText: st.text,
      lastActivity: s.lastActivity, startedAt: s.startedAt || null, model: s.model || null, pid: s.pid || null, mode: s.mode || null,
      tmux: s.tmux ? { session: s.tmux.session, target: s.tmux.target } : null, managed: s.managed || null, controllable: Boolean(s.tmux),
      approval: prompts.get(s.key) || null, counts: s.counts, lastEvent: s.lastEvent || null,
    };
  }

  function list({ includeEnded = true } = {}) {
    return [...sessions.values()].map(view)
      .filter((v) => includeEnded || v.status !== "ended")
      .sort((a, b) => rank(a) - rank(b) || b.lastActivity - a.lastActivity);
  }
  const rank = (v) => ({ approval: 0, working: 1, idle: 2, exited: 3, failed: 4, ended: 5 })[v.status] ?? 6;

  function get(id) {
    const s = sessions.get(id);
    if (!s) throw Object.assign(new Error("Unknown agent session"), { status: 404 });
    return s;
  }

  // ---------- control ----------
  async function launch({ agent, project, prompt = "", mode = "default", resume = null, allowDuplicate = false, model = null }) {
    if (!["claude", "codex"].includes(agent)) throw Object.assign(new Error("agent must be claude or codex"), { status: 400 });
    const p = projects.get(project);
    const live = list({ includeEnded: false }).filter((v) => v.managed && v.status !== "exited");
    if (live.length >= cfg.maxManagedAgents) throw Object.assign(new Error(`Already running ${live.length} agents from Musa Control (limit ${cfg.maxManagedAgents}). Stop one first.`), { status: 429 });
    const dup = list({ includeEnded: false }).find((v) => v.project === p.id && v.agent === agent && ["working", "approval", "idle"].includes(v.status) && v.pid);
    if (dup && !allowDuplicate && !resume) throw Object.assign(new Error(`${agentName(agent)} is already running in ${p.name}. Open it, or confirm a second session.`), { status: 409, body: { duplicate: dup.id } });
    if (resume && list().some((v) => v.sessionId === resume && v.pid)) throw Object.assign(new Error("That session is already open in a running process."), { status: 409 });
    const id = crypto.randomUUID();
    const name = `mc-${agent}-${p.id.slice(0, 24)}-${id.slice(0, 4)}`;
    let cmd;
    if (agent === "claude") {
      const args = [cfg.claudeBinary];
      if (resume) args.push("--resume", resume); else args.push("--session-id", id);
      if (["acceptEdits", "plan", "default"].includes(mode)) args.push("--permission-mode", mode);
      if (model) args.push("--model", model);
      if (prompt && !resume) args.push("--", prompt);
      cmd = args.map((a, i) => (i === 0 ? a : shq(a))).join(" ");
    } else {
      const args = [cfg.codexBinary];
      if (resume) args.push("resume", resume);
      args.push("-a", "on-request", "-s", mode === "read-only" ? "read-only" : "workspace-write");
      if (model) args.push("-m", model);
      if (prompt && !resume) args.push(prompt);
      cmd = args.map((a, i) => (i === 0 ? a : shq(a))).join(" ");
    }
    // A login shell so PATH (nvm) matches the user's terminal.
    await tmux.newSession(name, p.path, `bash -lc ${shq(cmd)}`, { width: 180, height: 50 });
    db.raw.prepare("INSERT INTO managed_agents(id,agent,project,cwd,tmux,session_id,created_at,title) VALUES(?,?,?,?,?,?,?,?)")
      .run(id, agent, p.id, p.path, name, agent === "claude" ? (resume || id) : resume, Date.now(), prompt.slice(0, 200) || null);
    events.emit({ kind: "agent.started", project: p.id, session: agent === "claude" ? `claude:${resume || id}` : null, title: `Started ${agentName(agent)} in ${p.name}${resume ? " (resumed)" : ""}`, detail: { tmux: name, prompt: prompt.slice(0, 2000), mode } });
    watcher?.activate(p.id).catch(() => {});
    setTimeout(() => pollProcesses().catch(() => {}), 1500);
    return { id, tmux: name, sessionKey: agent === "claude" ? `claude:${resume || id}` : null };
  }

  async function send(id, text) {
    const s = get(id);
    if (!s.tmux) throw Object.assign(new Error("This session isn't running in tmux, so Musa Control can only watch it."), { status: 409 });
    if (prompts.get(id)) throw Object.assign(new Error("The agent is waiting for an approval answer first."), { status: 409 });
    await tmux.sendText(s.tmux.target, text);
    events.emit({ kind: "agent.instruction", project: s.project, session: s.key, title: `You: ${String(text).slice(0, 160)}`, detail: { text: String(text).slice(0, 20000) } });
    return { ok: true };
  }

  async function answer(id, { signature, option }) {
    const s = get(id);
    if (!s.tmux) throw Object.assign(new Error("Not controllable"), { status: 409 });
    const screen = await tmux.capture(s.tmux.target, { lines: 70 });
    const p = parsePrompt(screen);
    if (!p || p.signature !== signature) throw Object.assign(new Error("That prompt is no longer on screen. Refresh and check again."), { status: 409 });
    await tmux.sendKeys(s.tmux.target, keysFor(p, Number(option)));
    prompts.delete(id);
    const label = p.options[Number(option)]?.label;
    events.emit({ kind: "agent.approval_answered", project: s.project, session: s.key, title: `Answered "${label}" to: ${p.question}`, detail: { question: p.question, option: label, context: p.context.slice(0, 2000) } });
    setTimeout(() => pollPrompts().catch(() => {}), 700);
    return { ok: true, answered: label };
  }

  async function interrupt(id) {
    const s = get(id);
    if (!s.tmux) throw Object.assign(new Error("Not controllable"), { status: 409 });
    await tmux.sendKeys(s.tmux.target, ["Escape"]);
    events.emit({ kind: "agent.stopped", project: s.project, session: s.key, title: "Interrupted from Musa Control", detail: {} });
    return { ok: true };
  }

  // Ends a session Musa Control launched. Sessions started elsewhere are
  // never killed from here.
  async function end(id) {
    const s = get(id);
    if (!s.managed) throw Object.assign(new Error("Only sessions launched from Musa Control can be ended here."), { status: 403 });
    try { await tmux.sendKeys(s.managed.tmux, ["C-c"]); await new Promise((r) => setTimeout(r, 400)); await tmux.sendKeys(s.managed.tmux, ["C-c"]); } catch {}
    await new Promise((r) => setTimeout(r, 1500));
    await tmux.kill(s.managed.tmux);
    db.raw.prepare("UPDATE managed_agents SET ended_at=? WHERE id=?").run(Date.now(), s.managed.id);
    events.emit({ kind: "agent.ended", project: s.project, session: s.key, title: `Ended ${agentName(s.agent)} session`, detail: { tmux: s.managed.tmux } });
    s.managed = null; s.tmux = null;
    return { ok: true };
  }

  async function screen(id, { ansi = true, lines = 200 } = {}) {
    const s = get(id);
    if (!s.tmux) return { text: null, controllable: false };
    return { text: await tmux.capture(s.tmux.target, { ansi, lines }), controllable: true, tmux: s.tmux.session };
  }

  async function attachFile(project, name, buffer) {
    const p = projects.get(project);
    const dir = path.join(cfg.dataDir, "attachments", p.id);
    await fsp.mkdir(dir, { recursive: true });
    const safe = String(name || "attachment").replace(/[^\w.-]+/g, "_").slice(-80);
    const full = path.join(dir, `${Date.now()}-${safe}`);
    await fsp.writeFile(full, buffer);
    return { path: full };
  }

  async function start() {
    await pollTranscripts();
    await pollProcesses();
    await pollPrompts();
    timer = setInterval(() => pollTranscripts().catch(() => {}), 1500);
    procTimer = setInterval(() => pollProcesses().catch(() => {}), 4000);
    promptTimer = setInterval(() => pollPrompts().catch(() => {}), 1500);
  }
  function stop() { clearInterval(timer); clearInterval(procTimer); clearInterval(promptTimer); db.set("transcript-offsets", offsets); }

  return { start, stop, list, get: (id) => view(get(id)), launch, send, answer, interrupt, end, screen, attachFile, pollTranscripts, pollProcesses, pollPrompts, _sessions: sessions };
}
