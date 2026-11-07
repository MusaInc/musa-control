// Screenshot stream. Images are recorded only when they come from an
// authorised source: a watched project directory, or a path a coding agent
// itself captured/viewed in its transcript (Codex ImageView, Claude Read of
// an image, a screenshot command's output file). Nothing else on disk is
// collected, so unrelated private images never reach the app.
import fsp from "node:fs/promises";
import path from "node:path";
import { isImage } from "./files.js";
import { run } from "./exec.js";

export function createScreenshots(cfg, db, projects, events) {
  const insert = db.raw.prepare("INSERT OR IGNORE INTO screenshots(ts,project,session,path,width,height,bytes,source) VALUES(?,?,?,?,?,?,?,?)");
  const update = db.raw.prepare("UPDATE screenshots SET ts=?, bytes=?, width=?, height=? WHERE path=?");
  const byPath = db.raw.prepare("SELECT * FROM screenshots WHERE path=?");
  const allowedRoots = [cfg.home, "/tmp", "/srv"];

  async function dims(full) {
    const r = await run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", full], { timeout: 8000 });
    const [w, h] = r.stdout.trim().split(",").map(Number);
    return { width: w || null, height: h || null };
  }

  async function consider(full, { project = null, session = null, source = "project" } = {}) {
    if (!full || !isImage(full)) return null;
    const real = await fsp.realpath(full).catch(() => null);
    if (!real || !allowedRoots.some((r) => real.startsWith(r + "/"))) return null;
    const capture = real.startsWith(path.join(cfg.dataDir, "captures") + "/");
    if (projects.isSecret(real) || /\/(\.cache|thumbs|node_modules|\.git)\//.test(real) || (real.startsWith(cfg.dataDir) && !capture)) return null;
    const st = await fsp.stat(real).catch(() => null);
    if (!st || !st.isFile() || st.size < 2000 || st.size > 60 * 1024 * 1024) return null;
    const proj = project || projects.forPath(real)?.id || null;
    const prev = byPath.get(real);
    const d = await dims(real);
    if (d.width && d.width < 64) return null; // icons, favicons, sprites
    if (prev) {
      if (Math.abs(prev.ts - st.mtimeMs) < 1000 && prev.bytes === st.size) return prev;
      update.run(Date.now(), st.size, d.width, d.height, real);
    } else {
      insert.run(Date.now(), proj, session, real, d.width, d.height, st.size, source);
    }
    const row = byPath.get(real);
    events.emit({
      kind: "screenshot.new", project: proj, session, title: `${prev ? "Updated" : "New"} image ${path.basename(real)}`,
      detail: { id: row.id, path: real, width: d.width, height: d.height, source, rel: proj ? path.relative(projects.get(proj).path, real) : null },
      dedupe: `shot:${row.id}:${Math.round(st.mtimeMs)}`,
    });
    return row;
  }

  function list({ project, session, limit = 200, before } = {}) {
    const where = [], args = [];
    if (project) { where.push("project=?"); args.push(project); }
    if (session) { where.push("session=?"); args.push(session); }
    if (before) { where.push("id<?"); args.push(Number(before)); }
    return db.raw.prepare(`SELECT * FROM screenshots ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY ts DESC LIMIT ?`).all(...args, Math.min(limit, 500));
  }

  function get(id) { return db.raw.prepare("SELECT * FROM screenshots WHERE id=?").get(Number(id)); }
  function annotate(id, note) { db.raw.prepare("UPDATE screenshots SET note=? WHERE id=?").run(String(note || "").slice(0, 4000), Number(id)); return get(id); }

  return { consider, list, get, annotate };
}
