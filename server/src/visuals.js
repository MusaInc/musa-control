// Visualiser: a folder of preview outputs per project, plus sandboxed Python
// runs that write into it.
//
// Anything an agent (or a run) puts in <dataDir>/visuals/<project>/ shows in
// the app's Visualiser panel and refreshes when it changes: images, SVG,
// GIF/video, HTML apps, 3D models, PDFs, text. Agents launched from Musa get
// $MUSA_PREVIEW_DIR pointing there and `musa-preview` on PATH.
//
// Python runs never get the network or write access outside their own run
// folder: bubblewrap on Linux, sandbox-exec on macOS. Without either, runs
// are refused rather than executed unconfined.
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { hasCommand } from "./platform.js";

const KINDS = [
  ["image", /\.(png|jpe?g|gif|webp|bmp|heic)$/i],
  ["svg", /\.svg$/i],
  ["video", /\.(mp4|m4v|mov|webm)$/i],
  ["html", /\.html?$/i],
  ["model", /\.(glb|gltf|obj|stl|ply|usdz|dae)$/i],
  ["pdf", /\.pdf$/i],
  ["text", /\.(txt|log|md|csv|tsv|json|py|js|ts|gd|xml|yaml|yml)$/i],
];
export function visualKind(name) {
  for (const [k, re] of KINDS) if (re.test(name)) return k;
  return "other";
}

const RUNNER = new URL("../py/musa_runner.py", import.meta.url).pathname;
const MAX_OUTPUT = 200 * 1024;

export function createVisuals(cfg, projects, events, { spawnImpl = spawn } = {}) {
  const root = path.join(cfg.dataDir, "visuals");
  const venv = path.join(cfg.dataDir, "python");
  fs.mkdirSync(root, { recursive: true });
  const runs = new Map(); // id → run record (last 50)
  let setupState = { state: "idle", output: "" };

  const safe = (id) => String(id || "").replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80) || "_shared";
  function dirFor(project) {
    const d = path.join(root, safe(project));
    fs.mkdirSync(d, { recursive: true });
    return d;
  }

  // Symlinks may only lead into a project or back into the visuals folder.
  function allowedTarget(real) {
    if (real === root || real.startsWith(root + path.sep)) return true;
    for (const p of projects.all().values()) if (real === p.path || real.startsWith(p.path + path.sep)) return true;
    return false;
  }

  function resolve(project, rel) {
    const base = dirFor(project);
    const full = path.resolve(base, String(rel || "").replace(/^\/+/, ""));
    if (full !== base && !full.startsWith(base + path.sep)) throw Object.assign(new Error("Path outside the preview folder"), { status: 400 });
    return { base, full };
  }

  async function list(project, { limit = 300 } = {}) {
    const base = dirFor(project);
    const out = [];
    async function walk(dir, depth) {
      let entries = [];
      try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (e.name.startsWith(".")) continue;
        const full = path.join(dir, e.name);
        let st;
        try {
          if (e.isSymbolicLink()) {
            const real = await fsp.realpath(full);
            if (!allowedTarget(real)) continue;
          }
          st = await fsp.stat(full);
        } catch { continue; }
        if (st.isDirectory()) { if (depth < 3) await walk(full, depth + 1); continue; }
        const rel = path.relative(base, full);
        const run = rel.startsWith("runs" + path.sep) ? rel.split(path.sep)[1] : null;
        out.push({ path: rel, name: e.name, kind: visualKind(e.name), size: st.size, mtime: Math.round(st.mtimeMs), run, linked: e.isSymbolicLink() });
      }
    }
    await walk(base, 0);
    out.sort((a, b) => b.mtime - a.mtime);
    return { project: safe(project), dir: base, items: out.slice(0, limit) };
  }

  async function file(project, rel) {
    const { full } = resolve(project, rel);
    const st = await fsp.lstat(full).catch(() => null);
    if (!st) throw Object.assign(new Error("Not found"), { status: 404 });
    if (st.isSymbolicLink() && !allowedTarget(await fsp.realpath(full))) throw Object.assign(new Error("Not found"), { status: 404 });
    if ((await fsp.stat(full)).isDirectory()) throw Object.assign(new Error("That is a folder"), { status: 400 });
    return full;
  }

  async function publish(project, rel, data) {
    if (!rel) throw Object.assign(new Error("path required"), { status: 400 });
    const { full } = resolve(project, rel);
    await fsp.mkdir(path.dirname(full), { recursive: true });
    const tmp = full + ".part-" + crypto.randomBytes(3).toString("hex");
    await fsp.writeFile(tmp, data);
    await fsp.rename(tmp, full);
    return { path: path.relative(dirFor(project), full), size: data.length };
  }

  async function remove(project, rel) {
    const { base, full } = resolve(project, rel);
    if (full === base) throw Object.assign(new Error("Refusing to remove the whole folder"), { status: 400 });
    await fsp.rm(full, { recursive: true, force: true });
    return { ok: true };
  }

  // ---- live changes -------------------------------------------------------
  const pending = new Map(); // full path → timer
  let watcher = null;
  const linkTimes = new Map(); // symlink → target mtime
  function announce(full) {
    const rel = path.relative(root, full);
    const [project, ...rest] = rel.split(path.sep);
    if (!project || !rest.length || rest.some((x) => x.startsWith(".")) || /\.part-[0-9a-f]+$/.test(full)) return;
    fs.stat(full, (err, st) => {
      const p = rest.join(path.sep);
      if (err) return events.emit({ kind: "visual.removed", project, title: `Removed ${path.basename(p)}`, detail: { path: p }, persist: false });
      if (st.isDirectory()) return;
      events.emit({ kind: "visual.output", project, title: `Preview updated: ${path.basename(p)}`, persist: false,
        detail: { path: p, kind: visualKind(p), size: st.size, mtime: Math.round(st.mtimeMs) } });
    });
  }
  function onChange(full) {
    clearTimeout(pending.get(full));
    pending.set(full, setTimeout(() => { pending.delete(full); announce(full); }, 250));
  }
  function startWatching() {
    try {
      watcher = fs.watch(root, { recursive: true }, (_t, name) => { if (name) onChange(path.join(root, String(name))); });
      watcher.on("error", () => {});
    } catch { watcher = null; }
  }
  // Linked outputs (musa-preview --link) change at the target, which fs.watch
  // on the folder can't see: compare target mtimes every two seconds.
  const linkTimer = setInterval(async () => {
    let projectsDirs = [];
    try { projectsDirs = await fsp.readdir(root); } catch { return; }
    for (const pd of projectsDirs) {
      let entries = [];
      try { entries = await fsp.readdir(path.join(root, pd), { withFileTypes: true }); } catch { continue; }
      for (const e of entries) {
        if (!e.isSymbolicLink()) continue;
        const full = path.join(root, pd, e.name);
        try {
          const st = await fsp.stat(full);
          if (linkTimes.has(full) && linkTimes.get(full) !== st.mtimeMs) announce(full);
          linkTimes.set(full, st.mtimeMs);
        } catch { linkTimes.delete(full); }
      }
    }
  }, 2000);
  linkTimer.unref?.();
  startWatching();

  // ---- Python ---------------------------------------------------------------
  function pythonPath() {
    const v = path.join(venv, "bin", "python3");
    if (fs.existsSync(v)) return v;
    return cfg.pythonBinary || (fs.existsSync("/usr/bin/python3") ? "/usr/bin/python3" : "python3");
  }
  async function sandboxKind() {
    if (cfg.visuals?.sandbox === "none-for-tests") return "test";
    if (process.platform === "linux" && await hasCommand("bwrap")) return "bwrap";
    if (process.platform === "darwin" && fs.existsSync("/usr/bin/sandbox-exec")) return "sandbox-exec";
    return null;
  }

  async function status() {
    const py = pythonPath();
    const probe = await runPlain(py, ["-c", "import importlib.util as u, json; print(json.dumps({m: bool(u.find_spec(m)) for m in ['matplotlib','numpy','PIL','plotly','trimesh']}))"], 15000);
    let packages = {};
    try { packages = JSON.parse(probe.stdout.trim().split("\n").pop() || "{}"); } catch {}
    return { sandbox: await sandboxKind(), python: py, venv: fs.existsSync(path.join(venv, "bin", "python3")), packages, setup: setupState, dir: root };
  }

  function runPlain(cmd, args, timeout) {
    return new Promise((resolveRun) => {
      let stdout = "", stderr = "";
      let p;
      try { p = spawnImpl(cmd, args, { stdio: ["ignore", "pipe", "pipe"] }); } catch (e) { return resolveRun({ code: -1, stdout, stderr: String(e.message) }); }
      const t = setTimeout(() => p.kill("SIGKILL"), timeout);
      p.stdout.on("data", (c) => { stdout = (stdout + c).slice(-MAX_OUTPUT); });
      p.stderr.on("data", (c) => { stderr = (stderr + c).slice(-MAX_OUTPUT); });
      p.on("error", (e) => { clearTimeout(t); resolveRun({ code: -1, stdout, stderr: stderr + String(e.message) }); });
      p.on("close", (code) => { clearTimeout(t); resolveRun({ code, stdout, stderr }); });
    });
  }

  // A private Python with the plotting basics, so runs don't depend on (or
  // change) the system's packages.
  async function setup({ packages = ["matplotlib", "numpy", "pillow"] } = {}) {
    if (setupState.state === "running") return setupState;
    const pk = packages.filter((x) => /^[A-Za-z0-9_.\-[\]=<>]+$/.test(x)).slice(0, 12);
    setupState = { state: "running", output: "", startedAt: Date.now() };
    (async () => {
      const sys = cfg.pythonBinary || "python3";
      let r = fs.existsSync(path.join(venv, "bin", "python3")) ? { code: 0, stdout: "", stderr: "" } : await runPlain(sys, ["-m", "venv", venv], 120000);
      let out = r.stdout + r.stderr;
      if (r.code === 0) {
        r = await runPlain(path.join(venv, "bin", "python3"), ["-m", "pip", "install", "--disable-pip-version-check", "-q", ...pk], 15 * 60000);
        out += r.stdout + r.stderr;
      }
      setupState = { state: r.code === 0 ? "ready" : "failed", output: out.slice(-8000), endedAt: Date.now() };
      events.emit({ kind: "visual.setup", title: r.code === 0 ? "Visualiser Python is ready" : "Visualiser Python setup failed", detail: { ok: r.code === 0, packages: pk } });
    })();
    return setupState;
  }

  function sandboxArgs(kind, { python, script, runDir, projectDir }) {
    const env = { MUSA_OUT: runDir, MUSA_PROJECT_DIR: projectDir || "", MPLBACKEND: "Agg", MPLCONFIGDIR: "/tmp/mpl", HOME: "/tmp", PYTHONDONTWRITEBYTECODE: "1", PYTHONUNBUFFERED: "1", LANG: "C.UTF-8" };
    if (kind === "bwrap") {
      const a = ["--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64", "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin",
        "--ro-bind-try", "/etc/fonts", "/etc/fonts", "--ro-bind-try", "/etc/ssl", "/etc/ssl", "--ro-bind-try", "/etc/localtime", "/etc/localtime",
        "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
        "--ro-bind", RUNNER, "/opt/musa/runner.py", "--ro-bind", script, script];
      if (fs.existsSync(venv)) a.push("--ro-bind", venv, venv);
      if (projectDir) a.push("--ro-bind", projectDir, projectDir);
      a.push("--bind", runDir, runDir, "--remount-ro", "/", "--chdir", runDir);
      for (const [k, v] of Object.entries(env)) a.push("--setenv", k, v);
      a.push(python, "-I", "/opt/musa/runner.py", script);
      return { cmd: "bwrap", args: a, env: {} };
    }
    if (kind === "sandbox-exec") {
      const q = (s) => `"${String(s).replace(/["\\]/g, "\\$&")}"`;
      const profile = `(version 1)(allow default)(deny network*)(deny file-write* (require-not (require-any (subpath ${q(runDir)}) (subpath "/private/tmp") (subpath "/private/var/folders") (literal "/dev/null"))))`;
      return { cmd: "/usr/bin/sandbox-exec", args: ["-p", profile, python, "-I", RUNNER, script], env: { ...env, MPLCONFIGDIR: path.join(runDir, ".mpl"), HOME: runDir } };
    }
    // Unit tests only: the fake spawn records the call.
    return { cmd: python, args: ["-I", RUNNER, script], env };
  }

  async function run(project, { code, file, timeout = 120 } = {}) {
    const kind = await sandboxKind();
    if (!kind) throw Object.assign(new Error("Python runs need a sandbox on this machine: install bubblewrap (bwrap)."), { status: 409 });
    const p = project && project !== "_shared" ? projects.get(project) : null;
    const id = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14) + "-" + crypto.randomBytes(2).toString("hex");
    const runDir = path.join(dirFor(project), "runs", id);
    await fsp.mkdir(runDir, { recursive: true });
    let script;
    if (file) {
      if (!p) throw Object.assign(new Error("Running a project file needs a project"), { status: 400 });
      script = projects.resolveInside(p.id, file).full;
    } else if (code && String(code).trim()) {
      script = path.join(runDir, ".script.py");
      await fsp.writeFile(script, String(code));
    } else throw Object.assign(new Error("Nothing to run"), { status: 400 });
    const secs = Math.max(5, Math.min(Number(timeout) || 120, 600));
    const rec = { id, project: safe(project), status: "running", startedAt: Date.now(), endedAt: null, exitCode: null, output: "", file: file || null, sandbox: kind, timeout: secs };
    runs.set(id, rec);
    while (runs.size > 50) runs.delete(runs.keys().next().value);
    events.emit({ kind: "visual.run", project: rec.project, title: `Running ${file ? path.basename(file) : "Python"} in the sandbox`, detail: { run: id, status: "running" }, persist: false });
    const { cmd, args, env } = sandboxArgs(kind, { python: pythonPath(), script, runDir, projectDir: p?.path });
    const child = spawnImpl(cmd, args, { cwd: runDir, env: Object.keys(env).length ? env : { PATH: "/usr/bin:/bin" }, stdio: ["ignore", "pipe", "pipe"] });
    rec.pid = child.pid;
    const timer = setTimeout(() => { rec.timedOut = true; try { child.kill("SIGKILL"); } catch {} }, secs * 1000);
    const add = (c) => { rec.output = (rec.output + c).slice(-MAX_OUTPUT); };
    child.stdout?.on("data", add); child.stderr?.on("data", add);
    child.on?.("error", (e) => add(`\n${e.message}\n`));
    child.on?.("close", async (codeOut) => {
      clearTimeout(timer);
      rec.status = rec.timedOut ? "timeout" : codeOut === 0 ? "ok" : "failed";
      rec.exitCode = codeOut; rec.endedAt = Date.now();
      try { await fsp.writeFile(path.join(runDir, ".output.txt"), rec.output); } catch {}
      const made = (await list(project)).items.filter((x) => x.run === id).map((x) => x.path);
      rec.files = made;
      events.emit({ kind: "visual.run", project: rec.project, title: rec.status === "ok" ? `Python run finished · ${made.length} output${made.length === 1 ? "" : "s"}` : rec.timedOut ? `Python run stopped after ${secs} s` : `Python run failed (exit ${codeOut})`,
        detail: { run: id, status: rec.status, exitCode: codeOut, files: made, output: rec.output.slice(-4000) } });
    });
    return rec;
  }

  function getRun(id) {
    const r = runs.get(id);
    if (!r) throw Object.assign(new Error("No such run"), { status: 404 });
    return r;
  }
  function stopRun(id) {
    const r = getRun(id);
    if (r.status === "running" && r.pid) { r.timedOut = false; try { process.kill(r.pid, "SIGKILL"); } catch {} }
    return r;
  }

  function close() { clearInterval(linkTimer); try { watcher?.close(); } catch {} for (const t of pending.values()) clearTimeout(t); }
  return { dirFor, list, file, publish, remove, run, getRun, stopRun, status, setup, close, root };
}
