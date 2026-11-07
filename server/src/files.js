// Project file API. Every path goes through projects.resolveInside, writes
// are optimistic-concurrency checked (the client sends the SHA it edited),
// and deletes move into a gateway trash so they can be restored.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { run } from "./exec.js";

export const sha1 = (buf) => crypto.createHash("sha1").update(buf).digest("hex");
const TEXT_EXT = new Set(["js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "md", "txt", "html", "css", "scss", "py", "gd", "gdshader",
  "gdshaderinc", "swift", "kt", "kts", "java", "sh", "yml", "yaml", "toml", "cfg", "ini", "xml", "plist", "svg", "sql", "rs", "go", "c",
  "h", "cpp", "hpp", "m", "mm", "rb", "php", "vue", "svelte", "tscn", "tres", "import", "godot", "gradle", "properties", "csv", "lock",
  "env.example", "conf", "service", "dockerfile", "makefile", "gitignore", "license", "glsl", "wgsl", "lua"]);
const MIME = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", svg: "image/svg+xml",
  mp4: "video/mp4", mov: "video/quicktime", webm: "video/webm", m4v: "video/mp4", pdf: "application/pdf", wav: "audio/wav", mp3: "audio/mpeg",
  json: "application/json", html: "text/html", txt: "text/plain", md: "text/markdown" };

export function extOf(name) { const b = path.basename(name).toLowerCase(); return b.includes(".") ? b.split(".").pop() : b; }
export function mimeOf(name) { return MIME[extOf(name)] || "application/octet-stream"; }
export function isImage(name) { return ["png", "jpg", "jpeg", "gif", "webp"].includes(extOf(name)); }

export function looksText(buf, name) {
  if (TEXT_EXT.has(extOf(name))) return !buf.subarray(0, 8000).includes(0);
  const sample = buf.subarray(0, 8000);
  if (sample.includes(0)) return false;
  let odd = 0; for (const b of sample) if (b < 9 || (b > 13 && b < 32)) odd++;
  return odd < sample.length * 0.02;
}

export function createFiles(cfg, projects, events) {
  const trash = path.join(cfg.dataDir, "trash");
  fs.mkdirSync(trash, { recursive: true });
  const ignored = new Set(cfg.ignoreDirs);

  async function list(id, rel = "") {
    const { full, rel: r, project } = projects.resolveInside(id, rel);
    const entries = await fsp.readdir(full, { withFileTypes: true });
    const out = [];
    for (const e of entries) {
      const childRel = path.posix.join(r, e.name);
      if (projects.isSecret(childRel)) continue;
      let st; try { st = await fsp.stat(path.join(full, e.name)); } catch { continue; }
      out.push({ name: e.name, path: childRel, dir: st.isDirectory(), size: st.size, mtime: st.mtimeMs,
        ignored: st.isDirectory() && ignored.has(e.name), hidden: e.name.startsWith(".") });
    }
    out.sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name, undefined, { numeric: true }) : a.dir ? -1 : 1));
    return { project: project.id, path: r, entries: out };
  }

  async function read(id, rel) {
    const { full, rel: r } = projects.resolveInside(id, rel);
    const st = await fsp.stat(full);
    if (st.isDirectory()) throw Object.assign(new Error("Is a directory"), { status: 400 });
    const meta = { path: r, size: st.size, mtime: st.mtimeMs, mime: mimeOf(r) };
    if (st.size > cfg.watch.textLimitBytes * 4) return { ...meta, text: null, binary: true, tooLarge: true };
    const buf = await fsp.readFile(full);
    if (!looksText(buf, r)) return { ...meta, text: null, binary: true, sha: sha1(buf) };
    return { ...meta, text: buf.toString("utf8"), binary: false, sha: sha1(buf) };
  }

  // baseSha: the SHA the client loaded. If the file changed since (an agent
  // wrote it), the write is refused with the current content so the client
  // can show a merge view instead of clobbering the agent's work.
  async function write(id, rel, text, baseSha, { force = false } = {}) {
    const { full, rel: r, project } = projects.resolveInside(id, rel, { mustExist: false });
    let current = null;
    try { current = await fsp.readFile(full); } catch {}
    if (current && !force && baseSha !== sha1(current)) {
      return { status: 409, body: { error: "The file changed on the server since you opened it.", currentSha: sha1(current), currentText: looksText(current, r) ? current.toString("utf8") : null } };
    }
    if (!current && baseSha && !force) return { status: 409, body: { error: "The file was deleted on the server.", currentSha: null } };
    await fsp.mkdir(path.dirname(full), { recursive: true });
    const tmp = full + `.mc-${process.pid}-${Date.now()}.tmp`;
    await fsp.writeFile(tmp, text);
    if (current) { try { const st = await fsp.stat(full); await fsp.chmod(tmp, st.mode); } catch {} }
    await fsp.rename(tmp, full);
    const s = sha1(Buffer.from(text));
    events.emit({ kind: "file.saved", project: project.id, title: `Saved ${r} from Musa Control`, detail: { path: r, sha: s, source: "user" } });
    return { status: 200, body: { path: r, sha: s } };
  }

  async function upload(id, rel, buffer) {
    const { full, rel: r, project } = projects.resolveInside(id, rel, { mustExist: false });
    if (fs.existsSync(full)) throw Object.assign(new Error("A file with that name already exists"), { status: 409 });
    await fsp.mkdir(path.dirname(full), { recursive: true });
    await fsp.writeFile(full, buffer);
    events.emit({ kind: "file.uploaded", project: project.id, title: `Uploaded ${r}`, detail: { path: r, bytes: buffer.length } });
    return { path: r, sha: sha1(buffer) };
  }

  async function mkdir(id, rel) {
    const { full, rel: r } = projects.resolveInside(id, rel, { mustExist: false });
    await fsp.mkdir(full, { recursive: true });
    return { path: r };
  }

  async function move(id, from, to, { copy = false } = {}) {
    const src = projects.resolveInside(id, from);
    const dst = projects.resolveInside(id, to, { mustExist: false });
    if (fs.existsSync(dst.full)) throw Object.assign(new Error("Destination already exists"), { status: 409 });
    await fsp.mkdir(path.dirname(dst.full), { recursive: true });
    if (copy) await fsp.cp(src.full, dst.full, { recursive: true, errorOnExist: true });
    else await fsp.rename(src.full, dst.full);
    events.emit({ kind: copy ? "file.copied" : "file.moved", project: src.project.id, title: `${copy ? "Copied" : "Moved"} ${src.rel} → ${dst.rel}`, detail: { from: src.rel, to: dst.rel } });
    return { from: src.rel, to: dst.rel };
  }

  // Deletion is recoverable: the entry moves to the gateway trash.
  async function remove(id, rel) {
    const { full, rel: r, project } = projects.resolveInside(id, rel);
    if (!r) throw Object.assign(new Error("Refusing to delete the project root"), { status: 400 });
    const tid = `${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
    const dest = path.join(trash, tid);
    await fsp.mkdir(dest);
    await fsp.writeFile(path.join(dest, "meta.json"), JSON.stringify({ project: project.id, path: r, at: Date.now() }));
    await fsp.rename(full, path.join(dest, "item")).catch(async (e) => {
      if (e.code !== "EXDEV") throw e;
      await fsp.cp(full, path.join(dest, "item"), { recursive: true }); await fsp.rm(full, { recursive: true });
    });
    events.emit({ kind: "file.deleted", project: project.id, title: `Deleted ${r} (recoverable)`, detail: { path: r, trashId: tid } });
    return { path: r, trashId: tid };
  }

  async function trashList() {
    const out = [];
    for (const d of (await fsp.readdir(trash)).sort().reverse().slice(0, 200)) {
      try { out.push({ id: d, ...JSON.parse(await fsp.readFile(path.join(trash, d, "meta.json"), "utf8")) }); } catch {}
    }
    return out;
  }

  async function restore(trashId) {
    if (!/^[0-9]+-[0-9a-f]{8}$/.test(trashId)) throw Object.assign(new Error("Bad trash id"), { status: 400 });
    const dir = path.join(trash, trashId);
    const meta = JSON.parse(await fsp.readFile(path.join(dir, "meta.json"), "utf8"));
    const dst = projects.resolveInside(meta.project, meta.path, { mustExist: false });
    if (fs.existsSync(dst.full)) throw Object.assign(new Error("Something already exists at the original path"), { status: 409 });
    await fsp.mkdir(path.dirname(dst.full), { recursive: true });
    await fsp.rename(path.join(dir, "item"), dst.full);
    await fsp.rm(dir, { recursive: true });
    return meta;
  }

  async function search(id, query, { mode = "content", limit = 200 } = {}) {
    const { project } = projects.resolveInside(id, "");
    const globs = [];
    for (const d of cfg.ignoreDirs) globs.push("-g", `!${d}/`);
    if (mode === "name") {
      const r = await run("rg", ["--files", "--hidden", "-g", "!.git/", ...globs], { cwd: project.path, timeout: 15_000 });
      const q = String(query).toLowerCase();
      const files = r.stdout.split("\n").filter((f) => f && f.toLowerCase().includes(q) && !projects.isSecret(f)).slice(0, limit);
      return { mode, results: files.map((f) => ({ path: f })) };
    }
    const r = await run("rg", ["--json", "-S", "--max-count", "20", "--max-filesize", "2M", "--hidden", "-g", "!.git/", ...globs, "--", String(query), "."],
      { cwd: project.path, timeout: 20_000 });
    const results = [];
    for (const line of r.stdout.split("\n")) {
      if (!line.startsWith("{")) continue;
      const ev = JSON.parse(line);
      if (ev.type !== "match") continue;
      const p = ev.data.path.text.replace(/^\.\//, "");
      if (projects.isSecret(p)) continue;
      results.push({ path: p, line: ev.data.line_number, text: ev.data.lines.text?.slice(0, 300) ?? "" });
      if (results.length >= limit) break;
    }
    return { mode, results };
  }

  // Downscaled JPEG preview for galleries (cached by path+mtime).
  async function thumbnail(full, width = 480) {
    const st = await fsp.stat(full);
    const key = sha1(`${full}:${st.mtimeMs}:${width}`);
    const dir = path.join(cfg.dataDir, "thumbs");
    await fsp.mkdir(dir, { recursive: true });
    const out = path.join(dir, key + ".jpg");
    if (!fs.existsSync(out)) {
      const r = await run("ffmpeg", ["-loglevel", "error", "-y", "-i", full, "-vf", `scale='min(${width},iw)':-2`, "-frames:v", "1", "-q:v", "5", out], { timeout: 20_000 });
      if (r.code !== 0) throw Object.assign(new Error("Thumbnail failed"), { status: 422 });
    }
    return out;
  }

  return { list, read, write, upload, mkdir, move, remove, trashList, restore, search, thumbnail };
}
