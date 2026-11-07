// Live filesystem monitoring for active workspaces.
//
// Watches each non-ignored directory of a project with inotify (fs.watch),
// debounces bursts, and for every real change of a text file stores a
// revision (gzip content + line counts against the previous revision). These
// are genuine snapshots of what landed on disk: an agent that rewrites a file
// in one go produces one revision, never a fake keystroke replay.
// New images inside the project become screenshot events.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import zlib from "node:zlib";
import { sha1, looksText, isImage } from "./files.js";
import { lineDiffCounts } from "./diff.js";

export function createWatcher(cfg, db, projects, events, screenshots) {
  const active = new Map(); // project id → {watchers: Map(dir→FSWatcher), until, timers}
  const ignored = new Set(cfg.ignoreDirs);
  const lastRev = db.raw.prepare("SELECT id, sha, content FROM revisions WHERE project=? AND path=? ORDER BY id DESC LIMIT 1");
  const insertRev = db.raw.prepare("INSERT INTO revisions(project,path,ts,sha,size,content,source,session,added,removed) VALUES(?,?,?,?,?,?,?,?,?,?)");
  // Agents report which session last touched a file; used to attribute revisions.
  const attribution = new Map(); // `${project}:${rel}` → {session, until}

  function attribute(project, rel, session) { attribution.set(`${project}:${rel}`, { session, until: Date.now() + 120_000 }); }

  function watchDir(state, project, dir) {
    if (state.watchers.has(dir) || state.watchers.size >= cfg.watch.maxDirsPerProject) return;
    let w;
    try {
      w = fs.watch(dir, { persistent: false }, (type, name) => {
        if (!name) return;
        const full = path.join(dir, name.toString());
        schedule(state, project, full);
      });
    } catch { return; }
    w.on("error", () => { state.watchers.delete(dir); try { w.close(); } catch {} });
    state.watchers.set(dir, w);
  }

  async function walk(state, project, dir, depth = 0) {
    if (depth > 12) return;
    watchDir(state, project, dir);
    let entries = [];
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.isDirectory() && !ignored.has(e.name) && !e.name.startsWith(".")) await walk(state, project, path.join(dir, e.name), depth + 1);
    }
  }

  function schedule(state, project, full) {
    const t = state.timers.get(full);
    if (t) clearTimeout(t);
    state.timers.set(full, setTimeout(() => { state.timers.delete(full); handle(state, project, full).catch((e) => console.error("watch handle", e.message)); }, 350));
  }

  async function handle(state, project, full) {
    const rel = path.relative(project.path, full);
    if (!rel || rel.startsWith("..") || rel.split("/").some((s) => ignored.has(s)) || projects.isSecret(rel)) return;
    if (/\.mc-\d+-\d+\.tmp$|~$|\.swp$|\.tmp$/.test(rel)) return;
    let st;
    try { st = await fsp.stat(full); } catch {
      const prev = lastRev.get(project.id, rel);
      if (prev) events.emit({ kind: "file.changed", project: project.id, title: `Deleted ${rel}`, detail: { path: rel, change: "delete" } });
      return;
    }
    if (st.isDirectory()) { await walk(state, project, full); return; }
    if (isImage(rel)) { await screenshots.consider(full, { project: project.id, source: "project" }); return; }
    if (st.size > cfg.watch.textLimitBytes) {
      events.emit({ kind: "file.changed", project: project.id, title: `Changed ${rel}`, detail: { path: rel, change: "update", size: st.size, large: true }, persist: false });
      return;
    }
    const buf = await fsp.readFile(full).catch(() => null);
    if (!buf || !looksText(buf, rel)) return;
    const s = sha1(buf);
    const prev = lastRev.get(project.id, rel);
    if (prev && prev.sha === s) return;
    let added = null, removed = null;
    const text = buf.toString("utf8");
    if (prev?.content) {
      const old = zlib.gunzipSync(prev.content).toString("utf8");
      ({ added, removed } = lineDiffCounts(old, text));
    }
    // First sighting of a file: no earlier snapshot, so counts stay unknown
    // (the client compares against git HEAD instead).
    const a = attribution.get(`${project.id}:${rel}`);
    const session = a && a.until > Date.now() ? a.session : null;
    const r = insertRev.run(project.id, rel, Date.now(), s, buf.length, zlib.gzipSync(buf), session ? "agent" : "disk", session, added, removed);
    events.emit({
      kind: "file.changed", project: project.id, session,
      title: `${prev ? "Edited" : "New"} ${rel}${added !== null ? ` (+${added} −${removed})` : ""}`,
      detail: { path: rel, change: prev ? "update" : "add", revision: Number(r.lastInsertRowid), sha: s, added, removed },
    });
  }

  async function activate(id, minutes = cfg.watch.idleMinutes) {
    const project = projects.get(id);
    let state = active.get(id);
    const until = Date.now() + minutes * 60_000;
    if (state) { state.until = Math.max(state.until, until); return { project: id, dirs: state.watchers.size, until: state.until }; }
    if (active.size >= cfg.watch.maxProjects) {
      // Evict the workspace that will expire soonest.
      const [oldest] = [...active.entries()].sort((a, b) => a[1].until - b[1].until);
      deactivate(oldest[0]);
    }
    state = { watchers: new Map(), until, timers: new Map() };
    active.set(id, state);
    await walk(state, project, project.path);
    return { project: id, dirs: state.watchers.size, until };
  }

  function deactivate(id) {
    const s = active.get(id);
    if (!s) return;
    for (const w of s.watchers.values()) { try { w.close(); } catch {} }
    for (const t of s.timers.values()) clearTimeout(t);
    active.delete(id);
  }

  const sweep = setInterval(() => { for (const [id, s] of active) if (s.until < Date.now()) deactivate(id); }, 30_000);
  sweep.unref();

  function revisions(id, rel, limit = 50) {
    return db.raw.prepare("SELECT id, ts, sha, size, source, session, added, removed FROM revisions WHERE project=? AND path=? ORDER BY id DESC LIMIT ?")
      .all(id, rel, Math.min(limit, 500));
  }
  function recentRevisions(id, limit = 100) {
    return db.raw.prepare("SELECT id, path, ts, sha, size, source, session, added, removed FROM revisions WHERE project=? ORDER BY id DESC LIMIT ?")
      .all(id, Math.min(limit, 500));
  }
  function revisionContent(revId) {
    const r = db.raw.prepare("SELECT * FROM revisions WHERE id=?").get(revId);
    if (!r) return null;
    const prev = db.raw.prepare("SELECT id, content FROM revisions WHERE project=? AND path=? AND id<? ORDER BY id DESC LIMIT 1").get(r.project, r.path, revId);
    return {
      id: r.id, project: r.project, path: r.path, ts: r.ts, sha: r.sha, source: r.source, session: r.session,
      text: zlib.gunzipSync(r.content).toString("utf8"),
      previousId: prev?.id ?? null, previousText: prev ? zlib.gunzipSync(prev.content).toString("utf8") : null,
    };
  }

  function status() { return [...active.entries()].map(([id, s]) => ({ project: id, dirs: s.watchers.size, until: s.until })); }
  function close() { clearInterval(sweep); for (const id of [...active.keys()]) deactivate(id); }

  return { activate, deactivate, status, revisions, recentRevisions, revisionContent, attribute, close, _handle: handle };
}
