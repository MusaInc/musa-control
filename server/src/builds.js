// Project builds/tests: the commands a project already defines (npm scripts,
// tools/*.sh, Godot test runner), run inside tmux so they survive
// disconnects, with output captured to a log and the exit code recorded.
// Only discovered commands can be started: arbitrary shell stays in the
// SSH terminal.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import * as tmux from "./tmux.js";
import { shq } from "./agents.js";

export function createBuilds(cfg, db, projects, events) {
  const dir = path.join(cfg.dataDir, "builds");
  fs.mkdirSync(dir, { recursive: true });
  const insert = db.raw.prepare("INSERT INTO builds(id,project,command,label,tmux,log,started_at) VALUES(?,?,?,?,?,?,?)");
  const finish = db.raw.prepare("UPDATE builds SET ended_at=?, exit_code=? WHERE id=?");

  async function start(projectId, commandId) {
    const p = projects.details(projectId);
    const c = p.commands.find((x) => x.id === commandId);
    if (!c) throw Object.assign(new Error("Unknown command for this project"), { status: 400 });
    const running = list(projectId).find((b) => b.status === "running" && b.command === c.command);
    if (running) throw Object.assign(new Error(`${c.label} is already running`), { status: 409, body: { build: running.id } });
    const id = crypto.randomUUID().slice(0, 12);
    const log = path.join(dir, `${id}.log`), code = path.join(dir, `${id}.exit`);
    const name = `mcb-${p.id.slice(0, 24)}-${id.slice(0, 6)}`;
    const script = `cd ${shq(p.path)} && { ${c.command} ; } 2>&1 | tee ${shq(log)}; echo \${PIPESTATUS[0]} > ${shq(code)}`;
    await tmux.newSession(name, p.path, `bash -lc ${shq(script)}`, { width: 200, height: 50 });
    insert.run(id, p.id, c.command, c.label, name, log, Date.now());
    events.emit({ kind: "build.started", project: p.id, title: `Started ${c.label}`, detail: { build: id, command: c.command, follow: { view: "build", build: id } } });
    return get(id);
  }

  function statusOf(row) {
    if (row.ended_at) return row.exit_code === 0 ? "succeeded" : "failed";
    const codeFile = row.log.replace(/\.log$/, ".exit");
    if (fs.existsSync(codeFile)) {
      const code = Number(fs.readFileSync(codeFile, "utf8").trim());
      finish.run(Date.now(), code, row.id);
      row.ended_at = Date.now(); row.exit_code = code;
      events.emit({ kind: "build.finished", project: row.project, title: `${row.label} ${code === 0 ? "succeeded" : `failed (exit ${code})`}`,
        detail: { build: row.id, exitCode: code, follow: { view: "build", build: row.id } }, notify: true });
      return code === 0 ? "succeeded" : "failed";
    }
    return "running";
  }

  function view(row) { return { id: row.id, project: row.project, label: row.label, command: row.command, tmux: row.tmux, startedAt: row.started_at, endedAt: row.ended_at, exitCode: row.exit_code, status: statusOf(row) }; }
  function list(projectId, limit = 30) {
    const rows = projectId ? db.raw.prepare("SELECT * FROM builds WHERE project=? ORDER BY started_at DESC LIMIT ?").all(projectId, limit)
      : db.raw.prepare("SELECT * FROM builds ORDER BY started_at DESC LIMIT ?").all(limit);
    return rows.map(view);
  }
  function row(id) { const r = db.raw.prepare("SELECT * FROM builds WHERE id=?").get(id); if (!r) throw Object.assign(new Error("Unknown build"), { status: 404 }); return r; }
  function get(id) { return view(row(id)); }

  async function log(id, { tail = 64 * 1024 } = {}) {
    const r = row(id);
    try {
      const st = await fsp.stat(r.log);
      const fh = await fsp.open(r.log, "r");
      const len = Math.min(st.size, tail), buf = Buffer.alloc(len);
      await fh.read(buf, 0, len, st.size - len); await fh.close();
      return { ...view(r), size: st.size, text: buf.toString("utf8") };
    } catch { return { ...view(r), size: 0, text: "" }; }
  }

  async function cancel(id) {
    const r = row(id);
    if (statusOf(r) !== "running") return get(id);
    await tmux.sendKeys(r.tmux, ["C-c"]).catch(() => {});
    setTimeout(() => { if (!fs.existsSync(r.log.replace(/\.log$/, ".exit"))) { finish.run(Date.now(), 130, r.id); tmux.kill(r.tmux).catch(() => {}); } }, 4000);
    events.emit({ kind: "build.cancelled", project: r.project, title: `Cancelled ${r.label}`, detail: { build: r.id } });
    return get(id);
  }

  // Poll running builds so completion events (and notifications) fire even
  // when nobody is looking at the build.
  const t = setInterval(() => { for (const r of db.raw.prepare("SELECT * FROM builds WHERE ended_at IS NULL").all()) statusOf(r); }, 3000);
  t.unref();
  return { start, list, get, log, cancel, close: () => clearInterval(t) };
}
