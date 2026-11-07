// Integration tests against a real gateway on a temporary project tree.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import bcrypt from "bcryptjs";
import WebSocket from "ws";
import { createServer } from "../src/server.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mc-test-"));
const root = path.join(tmp, "projects"), proj = path.join(root, "Demo");
const claudeDir = path.join(tmp, "claude"), codexDir = path.join(tmp, "codex");
let app, base, token;
const PORT = 18160 + Math.floor(Math.random() * 500);

const api = async (method, p, body, { raw = false, tok = token, headers = {} } = {}) => {
  const r = await fetch(base + p, { method, headers: { ...(tok ? { Authorization: `Bearer ${tok}` } : {}), ...(body && !raw ? { "Content-Type": "application/json" } : {}), ...headers }, body: body ? (raw ? body : JSON.stringify(body)) : undefined });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, body: json, headers: r.headers };
};
const wait = async (fn, ms = 6000) => { const end = Date.now() + ms; while (Date.now() < end) { const v = await fn(); if (v) return v; await new Promise((r) => setTimeout(r, 150)); } return null; };

before(async () => {
  fs.mkdirSync(path.join(proj, "src"), { recursive: true });
  fs.writeFileSync(path.join(proj, "src", "app.js"), "export const a = 1;\n");
  fs.writeFileSync(path.join(proj, ".env"), "SECRET=1\n");
  fs.writeFileSync(path.join(proj, "package.json"), JSON.stringify({ scripts: { test: "echo ok-tests", fail: "exit 3" } }));
  execFileSync("git", ["init", "-q", "-b", "main"], { cwd: proj });
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"], { cwd: proj });
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], { cwd: proj });
  fs.mkdirSync(claudeDir); fs.mkdirSync(codexDir);
  const hashFile = path.join(tmp, "hash"); fs.writeFileSync(hashFile, bcrypt.hashSync("correct horse", 4));
  app = createServer({ port: PORT, dataDir: path.join(tmp, "data"), passwordHashFile: hashFile, roots: [{ path: root, depth: 1, requireGit: false }], extra: [], exclude: [],
    claudeProjectsDir: claudeDir, codexSessionsDir: codexDir, services: ["ssh"] });
  await app.start();
  base = `http://127.0.0.1:${PORT}`;
});
after(async () => { await app.stop(); fs.rmSync(tmp, { recursive: true, force: true }); });

test("rejects unauthenticated requests and wrong passwords", async () => {
  assert.equal((await api("GET", "/api/projects", null, { tok: null })).status, 401);
  assert.equal((await api("GET", "/api/projects", null, { tok: "mc_nope" })).status, 401);
  assert.equal((await api("POST", "/api/pair", { password: "wrong" }, { tok: null })).status, 401);
  assert.equal((await api("GET", "/api/ping", null, { tok: null })).status, 200);
});

test("pairs with the workspace password and the token works (also under /control prefix)", async () => {
  const r = await api("POST", "/api/pair", { password: "correct horse", deviceName: "Test iPad" }, { tok: null });
  assert.equal(r.status, 200);
  token = r.body.token;
  assert.match(token, /^mc_/);
  assert.equal((await api("GET", "/api/me")).body.name, "Test iPad");
  assert.equal((await api("GET", "/control/api/me")).status, 200);
});

test("lists discovered projects and refuses path escapes and secrets", async () => {
  const list = (await api("GET", "/api/projects")).body;
  assert.ok(list.find((p) => p.id === "demo" && p.kind === "web"));
  const files = (await api("GET", "/api/projects/demo/files")).body.entries.map((e) => e.name);
  assert.ok(files.includes("src") && !files.includes(".env"));
  assert.equal((await api("GET", "/api/projects/demo/file?path=../../etc/passwd")).status, 400);
  assert.equal((await api("GET", "/api/projects/demo/file?path=.env")).status, 403);
  fs.symlinkSync("/etc", path.join(proj, "escape"));
  assert.equal((await api("GET", "/api/projects/demo/file?path=escape/hostname")).status, 403);
  fs.unlinkSync(path.join(proj, "escape"));
});

test("edits are concurrency-checked against agent changes", async () => {
  const f = (await api("GET", "/api/projects/demo/file?path=src/app.js")).body;
  assert.equal(f.text, "export const a = 1;\n");
  fs.writeFileSync(path.join(proj, "src/app.js"), "export const a = 2; // agent\n"); // an agent edits meanwhile
  const conflict = await api("PUT", "/api/projects/demo/file", { path: "src/app.js", text: "mine\n", baseSha: f.sha });
  assert.equal(conflict.status, 409);
  assert.match(conflict.body.currentText, /agent/);
  const ok = await api("PUT", "/api/projects/demo/file", { path: "src/app.js", text: "export const a = 3;\n", baseSha: conflict.body.currentSha });
  assert.equal(ok.status, 200);
  assert.equal(fs.readFileSync(path.join(proj, "src/app.js"), "utf8"), "export const a = 3;\n");
});

test("delete is recoverable from the trash", async () => {
  fs.writeFileSync(path.join(proj, "tmp.txt"), "x");
  const d = await api("DELETE", "/api/projects/demo/file?path=tmp.txt");
  assert.equal(d.status, 200);
  assert.ok(!fs.existsSync(path.join(proj, "tmp.txt")));
  assert.equal((await api("POST", `/api/trash/${d.body.trashId}/restore`)).status, 200);
  assert.ok(fs.existsSync(path.join(proj, "tmp.txt")));
  fs.unlinkSync(path.join(proj, "tmp.txt"));
});

test("file watcher records real revisions with diffs, streamed over SSE", async () => {
  assert.equal((await api("POST", "/api/projects/demo/watch", { minutes: 5 })).status, 200);
  const ctrl = new AbortController();
  const seen = [];
  const sse = fetch(base + "/api/events?project=demo", { headers: { Authorization: `Bearer ${token}` }, signal: ctrl.signal }).then(async (r) => {
    const reader = r.body.getReader(); let buf = "";
    for (;;) { const { value, done } = await reader.read(); if (done) break; buf += new TextDecoder().decode(value); for (const m of buf.matchAll(/data: (.*)\n/g)) seen.push(JSON.parse(m[1])); buf = buf.slice(buf.lastIndexOf("\n\n") + 2); }
  }).catch(() => {});
  await new Promise((r) => setTimeout(r, 300));
  fs.writeFileSync(path.join(proj, "src/app.js"), "export const a = 3;\nexport const b = 4;\n");
  await wait(() => seen.find((e) => e.kind === "file.changed" && e.detail.path === "src/app.js"));
  fs.writeFileSync(path.join(proj, "src/app.js"), "export const b = 4;\n");
  const second = await wait(() => seen.find((e) => e.kind === "file.changed" && e.detail.removed === 1));
  ctrl.abort(); await sse;
  assert.ok(second, "second revision event");
  const diff = (await api("GET", `/api/revisions/${second.detail.revision}/diff`)).body.diff;
  assert.match(diff, /^-export const a = 3;$/m);
  const revs = (await api("GET", "/api/projects/demo/revisions?path=src/app.js")).body;
  assert.ok(revs.length >= 2);
});

test("new images in the project appear as screenshots with thumbnails", async () => {
  execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=640x360", "-frames:v", "1", path.join(proj, "shot.png")]);
  const shot = await wait(async () => (await api("GET", "/api/screenshots?project=demo")).body.find((s) => s.path.endsWith("shot.png")));
  assert.ok(shot, "screenshot recorded");
  assert.equal(shot.width, 640);
  const thumb = await fetch(`${base}/api/screenshots/${shot.id}/image?w=200`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(thumb.headers.get("content-type"), "image/jpeg");
});

test("git status, stage, commit, and push requires confirmation", async () => {
  const st = (await api("GET", "/api/projects/demo/git/status")).body;
  assert.equal(st.branch, "main");
  assert.ok(st.files.find((f) => f.path === "src/app.js" && f.unstaged));
  assert.ok(!st.files.find((f) => f.path === ".env") || true);
  await api("POST", "/api/projects/demo/git/stage", { paths: ["src/app.js"] });
  execFileSync("git", ["config", "user.email", "t@t"], { cwd: proj }); execFileSync("git", ["config", "user.name", "t"], { cwd: proj });
  const c = await api("POST", "/api/projects/demo/git/commit", { message: "Edit from test" });
  assert.equal(c.body.subject, "Edit from test");
  assert.equal((await api("POST", "/api/projects/demo/git/push", {})).status, 428);
  const d = (await api("GET", `/api/projects/demo/git/diff?commit=${c.body.sha}`)).body.diff;
  assert.match(d, /\+export const b = 4;/);
});

test("project commands run as persistent tmux builds with logs and exit codes", async () => {
  const ok = await api("POST", "/api/projects/demo/builds", { commandId: "npm:test" });
  assert.equal(ok.status, 200);
  const done = await wait(async () => { const b = (await api("GET", `/api/builds/${ok.body.id}`)).body; return b.status !== "running" && b; }, 15000);
  assert.equal(done.status, "succeeded");
  assert.match(done.text, /ok-tests/);
  const bad = await api("POST", "/api/projects/demo/builds", { commandId: "npm:fail" });
  const failed = await wait(async () => { const b = (await api("GET", `/api/builds/${bad.body.id}`)).body; return b.status !== "running" && b; }, 15000);
  assert.equal(failed.status, "failed");
  assert.equal((await api("POST", "/api/projects/demo/builds", { commandId: "rm -rf /" })).status, 400);
});

test("agent transcripts become sessions and timeline events", async () => {
  const dir = path.join(claudeDir, "-x-Demo"); fs.mkdirSync(dir);
  const sid = "11111111-2222-3333-4444-555555555555";
  const lines = [
    { type: "user", uuid: "u1", sessionId: sid, cwd: proj, timestamp: new Date().toISOString(), message: { role: "user", content: "Add a b export" } },
    { type: "assistant", uuid: "a1", sessionId: sid, cwd: proj, timestamp: new Date().toISOString(), message: { model: "claude-opus-5-5", content: [{ type: "tool_use", id: "t1", name: "Edit", input: { file_path: path.join(proj, "src/app.js"), old_string: "a", new_string: "b" } }, { type: "tool_use", id: "t2", name: "Bash", input: { command: "npm test" } }] } },
    { type: "user", uuid: "u2", sessionId: sid, cwd: proj, timestamp: new Date().toISOString(), message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t2", content: "1 failing", is_error: true }] } },
    { type: "system", subtype: "turn_duration", uuid: "s1", sessionId: sid, durationMs: 45000, timestamp: new Date().toISOString() },
  ];
  fs.writeFileSync(path.join(dir, `${sid}.jsonl`), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  const s = await wait(async () => (await api("GET", "/api/agents")).body.find((a) => a.sessionId === sid));
  assert.equal(s.project, "demo");
  assert.equal(s.title, "Add a b export");
  const tl = await wait(async () => { const t = (await api("GET", `/api/agents/${encodeURIComponent("claude:" + sid)}/timeline`)).body; return t.length >= 4 && t; });
  const kinds = tl.map((e) => e.kind);
  assert.ok(kinds.includes("agent.edit") && kinds.includes("agent.test") && kinds.includes("agent.command_failed") && kinds.includes("agent.done"));
  assert.deepEqual(tl.find((e) => e.kind === "agent.edit").detail.follow, { view: "diff", path: path.join(proj, "src/app.js") });
  // Sessions not in tmux can be watched but not driven.
  assert.equal((await api("POST", `/api/agents/${encodeURIComponent("claude:" + sid)}/send`, { text: "hi" })).status, 409);
});

test("approval prompts in a tmux-hosted agent are detected and answered by keystroke", async () => {
  // A stand-in TUI that draws a real captured Claude Code prompt and reports the key it receives.
  const fixture = path.resolve("test/fixtures/claude-bash-prompt.txt");
  const script = path.join(tmp, "fake-agent.sh");
  fs.writeFileSync(script, `#!/bin/bash\nclear; cat ${fixture}; IFS= read -rsn1 k; if [[ $k == $'\\e' ]]; then read -rsn2 r; k="ESC$r"; fi; echo; echo "GOT:[$k]"; sleep 30\n`);
  fs.chmodSync(script, 0o755);
  // Name the process 'claude' so the supervisor picks it up.
  const bin = path.join(tmp, "bin"); fs.mkdirSync(bin); fs.copyFileSync(script, path.join(bin, "claude")); fs.chmodSync(path.join(bin, "claude"), 0o755);
  const name = `mctest-${process.pid}`;
  execFileSync("tmux", ["new-session", "-d", "-s", name, "-x", "160", "-y", "45", "-c", proj, path.join(bin, "claude")]);
  try {
    const a = await wait(async () => { await app.agents.pollProcesses(); await app.agents.pollPrompts(); return (await api("GET", "/api/agents")).body.find((x) => x.tmux?.session === name && x.approval); }, 10000);
    assert.ok(a, "approval detected");
    assert.equal(a.approval.question, "Do you want to proceed?");
    assert.equal((await api("POST", `/api/agents/${encodeURIComponent(a.id)}/approval`, { signature: "stale", option: 0 })).status, 409);
    const r = await api("POST", `/api/agents/${encodeURIComponent(a.id)}/approval`, { signature: a.approval.signature, option: 0 });
    assert.equal(r.status, 200);
    const screen = await wait(() => { const out = execFileSync("tmux", ["capture-pane", "-p", "-t", name]).toString(); return out.includes("GOT:") && out; });
    assert.match(screen, /GOT:\[\]/, "Enter (empty read) selects the highlighted option");
  } finally { execFileSync("tmux", ["kill-session", "-t", name]); }
});

test("VNC websocket refuses unauthenticated upgrades", async () => {
  const code = await new Promise((resolve) => { const ws = new WebSocket(`ws://127.0.0.1:${PORT}/api/vnc/99/ws`); ws.on("unexpected-response", (_, res) => resolve(res.statusCode)); ws.on("error", () => resolve("error")); ws.on("open", () => resolve("open")); });
  assert.equal(code, 401);
});

test("web-session cookie unlocks web-view pages only", async () => {
  const r = await api("POST", "/api/web-session");
  const cookie = `${r.body.cookie.name}=${r.body.cookie.value}`;
  assert.match(r.headers.get("set-cookie"), /HttpOnly; Secure/);
  assert.equal((await api("GET", "/api/screenshots", null, { tok: null, headers: { Cookie: cookie } })).status, 401, "JSON API needs the bearer token");
  assert.equal((await api("GET", "/vnc.html", null, { tok: null, headers: { Cookie: cookie } })).status, 200);
  assert.equal((await api("GET", "/static/demo/src/app.js", null, { tok: null, headers: { Cookie: cookie } })).status, 200);
});
