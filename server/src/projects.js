// Project discovery: real directories on the VPS, never a hard-coded list.
// A project is a git repository (or configured folder) under one of the
// configured roots. Paths handed to the file API are always resolved through
// `resolveInside`, which refuses anything that escapes the project root.
import fs from "node:fs";
import path from "node:path";
import { expand } from "./config.js";

export function slug(name) {
  return String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "project";
}

function detectKind(dir) {
  const has = (f) => fs.existsSync(path.join(dir, f));
  if (has("project.godot")) return "godot";
  if (has("project.yml") || fs.readdirSync(dir).some((f) => f.endsWith(".xcodeproj"))) return "ios";
  if (has("app.json") && has("package.json")) return "expo";
  if (has("settings.gradle.kts") || has("settings.gradle")) return "android";
  if (has("package.json")) return "web";
  if (has("pyproject.toml") || has("requirements.txt")) return "python";
  return "folder";
}

function githubRepo(dir) {
  try {
    const conf = fs.readFileSync(path.join(dir, ".git", "config"), "utf8");
    const m = conf.match(/\[remote "origin"\][^[]*?url = (\S+)/);
    if (!m) return null;
    const g = m[1].match(/github\.com[:/]([^/]+)\/([^/.\s]+?)(\.git)?$/);
    return g && g[1] !== "YOUR_USERNAME" ? `${g[1]}/${g[2]}` : null;
  } catch { return null; }
}

function commands(dir, kind) {
  const out = [];
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
    for (const name of Object.keys(pkg.scripts || {})) out.push({ id: `npm:${name}`, label: `npm run ${name}`, command: `npm run ${name}` });
  } catch {}
  for (const sub of ["tools", "scripts"]) {
    try {
      for (const f of fs.readdirSync(path.join(dir, sub)).sort()) {
        if (f.endsWith(".sh")) out.push({ id: `${sub}:${f}`, label: `${sub}/${f}`, command: `bash ${sub}/${f}` });
      }
    } catch {}
  }
  if (kind === "godot" && fs.existsSync(path.join(dir, "tests", "run_tests.gd"))) {
    out.unshift({ id: "godot:tests", label: "Godot tests", command: "godot --headless --script tests/run_tests.gd" });
  }
  return out.slice(0, 60);
}

export function createProjects(cfg) {
  let cache = null, cachedAt = 0;
  const excluded = new Set(cfg.exclude.map((p) => path.resolve(expand(p))));

  function scan() {
    const found = new Map();
    const add = (dir, name) => {
      const real = fs.realpathSync(dir);
      if (excluded.has(real) || [...found.values()].some((p) => p.path === real)) return;
      let id = slug(name || path.basename(real));
      if (found.has(id)) id = slug(`${path.basename(path.dirname(real))}-${path.basename(real)}`);
      const kind = detectKind(real);
      const base = path.basename(real);
      found.set(id, {
        id, name: name || base, path: real, kind, git: fs.existsSync(path.join(real, ".git")),
        github: githubRepo(real), previews: cfg.previews[base] || cfg.previews[id] || [],
      });
    };
    for (const root of cfg.roots) {
      const dir = expand(root.path);
      let entries = [];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
      for (const e of entries) {
        if (!e.isDirectory() || e.name.startsWith(".")) continue;
        const full = path.join(dir, e.name);
        if (root.requireGit && !fs.existsSync(path.join(full, ".git"))) continue;
        try { add(full); } catch {}
      }
    }
    for (const x of cfg.extra) { try { if (fs.existsSync(expand(x.path))) add(expand(x.path), x.name); } catch {} }
    return found;
  }

  function all() {
    if (!cache || Date.now() - cachedAt > 60_000) { cache = scan(); cachedAt = Date.now(); }
    return cache;
  }

  function get(id) {
    const p = all().get(id);
    if (!p) throw Object.assign(new Error(`Unknown project ${id}`), { status: 404 });
    return p;
  }

  function details(id) {
    const p = get(id);
    return { ...p, commands: commands(p.path, p.kind) };
  }

  // Which project a filesystem path belongs to (deepest root wins).
  function forPath(file) {
    if (!file) return null;
    let best = null;
    for (const p of all().values()) {
      if ((file === p.path || file.startsWith(p.path + "/")) && (!best || p.path.length > best.path.length)) best = p;
    }
    return best;
  }

  function isSecret(rel) { return cfg.secretRegexps.some((r) => r.test(rel)); }

  // Resolve a project-relative path, refusing escapes (.., symlinks out) and secrets.
  function resolveInside(id, rel = "", { mustExist = true, allowSecret = false } = {}) {
    const p = get(id);
    const clean = String(rel || "").replace(/^\/+/, "");
    if (clean.split("/").includes("..")) throw Object.assign(new Error("Path escapes the project"), { status: 400 });
    const full = path.resolve(p.path, clean);
    if (full !== p.path && !full.startsWith(p.path + "/")) throw Object.assign(new Error("Path escapes the project"), { status: 400 });
    if (!allowSecret && clean && isSecret(clean)) throw Object.assign(new Error("Secret files are not available through Musa Control"), { status: 403 });
    let real = full;
    if (fs.existsSync(full)) {
      real = fs.realpathSync(full);
      if (real !== p.path && !real.startsWith(p.path + "/")) throw Object.assign(new Error("Symlink points outside the project"), { status: 403 });
    } else if (mustExist) {
      throw Object.assign(new Error("Not found"), { status: 404 });
    } else {
      const parent = fs.existsSync(path.dirname(full)) ? fs.realpathSync(path.dirname(full)) : null;
      if (parent && parent !== p.path && !parent.startsWith(p.path + "/")) throw Object.assign(new Error("Path escapes the project"), { status: 403 });
    }
    return { project: p, full: real, rel: path.relative(p.path, real) };
  }

  return { all, get, details, forPath, resolveInside, isSecret, refresh: () => { cache = null; } };
}
