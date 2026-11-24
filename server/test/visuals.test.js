// Visualiser: preview folder, live change events, sandboxed Python runs.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import bcrypt from "bcryptjs";
import { createServer } from "../src/server.js";
import { visualKind } from "../src/visuals.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mc-vis-"));
const root = path.join(tmp, "projects"), proj = path.join(root, "Demo");
const PORT = 18700 + Math.floor(Math.random() * 400);
let app, base, token;
const hasBwrap = (() => { try { execFileSync("bwrap", ["--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64", "--symlink", "usr/bin", "/bin", "--unshare-all", "/usr/bin/true"], { stdio: "ignore" }); return true; } catch { return false; } })();

const api = async (method, p, body, { raw = false } = {}) => {
  const r = await fetch(base + p, { method, headers: { Authorization: `Bearer ${token}`, ...(body && !raw ? { "Content-Type": "application/json" } : {}) }, body: body ? (raw ? body : JSON.stringify(body)) : undefined });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, body: json, headers: r.headers };
};
const wait = async (fn, ms = 20000) => { const end = Date.now() + ms; while (Date.now() < end) { const v = await fn(); if (v) return v; await new Promise((r) => setTimeout(r, 200)); } return null; };

before(async () => {
  fs.mkdirSync(path.join(proj, "data"), { recursive: true });
  fs.writeFileSync(path.join(proj, "data", "numbers.txt"), "1 2 3\n");
  fs.writeFileSync(path.join(proj, "plot.py"), "print(open('" + path.join(proj, "data", "numbers.txt") + "').read().split())\nopen('result.txt','w').write('ok')\n");
  const hashFile = path.join(tmp, "hash"); fs.writeFileSync(hashFile, bcrypt.hashSync("pw", 4));
  app = createServer({ port: PORT, dataDir: path.join(tmp, "data"), passwordHashFile: hashFile, roots: [{ path: root, depth: 1, requireGit: false }], extra: [], exclude: [],
    claudeProjectsDir: path.join(tmp, "c"), codexSessionsDir: path.join(tmp, "x"), geminiDir: path.join(tmp, "g"), services: [], authorizedKeysFile: path.join(tmp, "ak"), apnsConfigFile: path.join(tmp, "none.json") });
  await app.start();
  base = `http://127.0.0.1:${PORT}`;
  token = (await (await fetch(base + "/api/pair", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ password: "pw", deviceName: "test" }) })).json()).token;
});
after(async () => { await app.stop(); fs.rmSync(tmp, { recursive: true, force: true }); });

test("kinds", () => {
  assert.equal(visualKind("a.PNG"), "image"); assert.equal(visualKind("m.glb"), "model"); assert.equal(visualKind("x.html"), "html");
  assert.equal(visualKind("v.webm"), "video"); assert.equal(visualKind("s.svg"), "svg"); assert.equal(visualKind("z.bin"), "other");
});

test("published files list newest first, stream a change event and can be removed", async () => {
  const seen = [];
  const off = app.events.subscribe((e) => { if (e.kind === "visual.output") seen.push(e); });
  assert.equal((await api("PUT", "/api/visuals/demo/file?path=chart.png", Buffer.from("png"), { raw: true })).status, 200);
  await new Promise((r) => setTimeout(r, 30));
  assert.equal((await api("PUT", "/api/visuals/demo/file?path=sub/page.html", Buffer.from("<p>hi</p>"), { raw: true })).status, 200);
  const l = await api("GET", "/api/visuals/demo");
  assert.deepEqual(l.body.items.map((x) => x.path), ["sub/page.html", "chart.png"]);
  assert.equal(l.body.items[0].kind, "html");
  assert.ok(await wait(() => seen.some((e) => e.project === "demo" && e.detail.path === "chart.png"), 4000), "change event");
  const f = await api("GET", "/api/visuals/demo/file?path=chart.png");
  assert.equal(f.status, 200); assert.equal(f.body, "png");
  assert.equal((await api("DELETE", "/api/visuals/demo/file?path=chart.png")).status, 200);
  assert.equal((await api("GET", "/api/visuals/demo/file?path=chart.png")).status, 404);
  off();
});

test("paths can't escape the preview folder and links outside projects are hidden", async () => {
  assert.equal((await api("GET", "/api/visuals/demo/file?path=../../hash")).status, 400);
  assert.equal((await api("PUT", "/api/visuals/demo/file?path=../evil.txt", Buffer.from("x"), { raw: true })).status, 400);
  const dir = app.visuals.dirFor("demo");
  fs.symlinkSync(path.join(tmp, "hash"), path.join(dir, "secret.txt"));
  fs.symlinkSync(path.join(proj, "data", "numbers.txt"), path.join(dir, "numbers.txt"));
  const l = await api("GET", "/api/visuals/demo");
  assert.ok(!l.body.items.some((x) => x.name === "secret.txt"));
  assert.ok(l.body.items.some((x) => x.name === "numbers.txt" && x.linked));
  assert.equal((await api("GET", "/api/visuals/demo/file?path=secret.txt")).status, 404);
});

test("the viewer page and three.js are served", async () => {
  const r = await api("GET", "/api/viewer/model.html");
  assert.equal(r.status, 200); assert.match(r.body, /importmap/);
  assert.equal((await api("GET", "/api/viewer/three/three.module.min.js")).status, 200);
  assert.equal((await api("GET", "/api/viewer/../visuals.js")).status, 404);
});

test("python runs in the sandbox: outputs kept, no network, no writes outside", { skip: !hasBwrap && "bubblewrap not available" }, async () => {
  const code = [
    "import socket, os",
    "open('made.txt','w').write('hello')",
    "try:\n    socket.create_connection(('1.1.1.1', 80), timeout=2); print('NET-OPEN')\nexcept OSError: print('net-blocked')",
    `try:\n    open(${JSON.stringify(path.join(proj, "x.txt"))}, 'w'); print('WROTE-PROJECT')\nexcept OSError: print('project-readonly')`,
    "try:\n    open('/etc/passwd-x', 'w'); print('WROTE-ETC')\nexcept OSError: print('etc-blocked')",
    `try:\n    open(${JSON.stringify(path.join(tmp, "escape.txt"))}, 'w'); print('WROTE-HOST')\nexcept OSError: print('host-blocked')`,
  ].join("\n");
  const r = await api("POST", "/api/visuals/demo/run", { code });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const done = await wait(async () => { const x = (await api("GET", `/api/visual-runs/${r.body.id}`)).body; return x.status !== "running" && x; });
  assert.equal(done.status, "ok", done.output);
  assert.match(done.output, /net-blocked/); assert.match(done.output, /project-readonly/); assert.match(done.output, /etc-blocked/);
  assert.ok(done.files.some((f) => f.endsWith("made.txt")));
  assert.ok(!fs.existsSync(path.join(proj, "x.txt"))); assert.ok(!fs.existsSync(path.join(tmp, "escape.txt")));
});

test("a project script can read its project", { skip: !hasBwrap && "bubblewrap not available" }, async () => {
  const r = await api("POST", "/api/visuals/demo/run", { file: "plot.py" });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const done = await wait(async () => { const x = (await api("GET", `/api/visual-runs/${r.body.id}`)).body; return x.status !== "running" && x; });
  assert.equal(done.status, "ok", done.output);
  assert.match(done.output, /'1', '2', '3'/);
  assert.ok(done.files.some((f) => f.endsWith("result.txt")));
});

test("runs time out", { skip: !hasBwrap && "bubblewrap not available" }, async () => {
  const r = await api("POST", "/api/visuals/demo/run", { code: "import time\ntime.sleep(60)", timeout: 5 });
  const done = await wait(async () => { const x = (await api("GET", `/api/visual-runs/${r.body.id}`)).body; return x.status !== "running" && x; }, 15000);
  assert.equal(done.status, "timeout");
});
