// Companion profile: generic machines, provider detection and sign-in,
// Gemini CLI sessions and prompts, API keys kept on the machine.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createServer } from "../src/server.js";
import { parsePrompt, keysFor } from "../src/prompts.js";
import { parseGeminiLine } from "../src/transcripts.js";
import { loadConfig } from "../src/config.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mc-comp-"));
process.env.MUSA_CONTROL_CONFIG = path.join(tmp, "absent.json");
const bin = path.join(tmp, "bin"), gem = path.join(tmp, "gemini"), proj = path.join(tmp, "code", "web-app");
let app, base, token;
const api = async (method, p, body, tok = token) => {
  const r = await fetch(base + p, { method, headers: { ...(tok ? { Authorization: `Bearer ${tok}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; } return { status: r.status, body: j };
};
const wait = async (fn, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { const v = await fn(); if (v) return v; await new Promise((r) => setTimeout(r, 150)); } return null; };
const script = (name, body) => { const f = path.join(bin, name); fs.writeFileSync(f, `#!/bin/bash\n${body}\n`); fs.chmodSync(f, 0o755); return f; };

before(async () => {
  fs.mkdirSync(bin, { recursive: true }); fs.mkdirSync(proj, { recursive: true });
  execFileSync("git", ["init", "-q"], { cwd: proj });
  // Stand-ins for the provider CLIs that answer exactly like the real ones'
  // status commands (real outputs: `claude auth status`, `codex login status`).
  const claude = script("claude", `case "$1 $2" in
  "--version "*) echo "2.1.99 (Claude Code)";;
  "auth status") echo '{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}'; exit 1;;
  "auth login") echo "Opening browser to sign in…"; echo "If the browser didn't open, visit: https://claude.ai/oauth/authorize?code=true&client_id=test&state=abc"; read -p "Paste code here if prompted > " c; echo "Got code: $c"; echo "Login successful.";;
esac`);
  const codex = script("codex", `case "$1 $2" in
  "--version "*) echo "codex-cli 0.166.0";;
  "login status") echo "Logged in using ChatGPT";;
  "login --with-api-key") read k; echo "stored";;
esac`);
  fs.mkdirSync(path.join(gem, "tmp", "web-app", "chats"), { recursive: true });
  fs.writeFileSync(path.join(gem, "settings.json"), JSON.stringify({ security: { auth: { selectedType: "oauth-personal" } } }));
  fs.writeFileSync(path.join(gem, "projects.json"), JSON.stringify({ projects: { [proj]: "web-app" } }));
  app = createServer({ profile: "companion", port: 0, dataDir: path.join(tmp, "data"), roots: [{ path: path.join(tmp, "code"), depth: 1, requireGit: true }],
    claudeProjectsDir: path.join(tmp, "claude"), codexSessionsDir: path.join(tmp, "codex"), geminiDir: gem, claudeBinary: claude, codexBinary: codex, geminiBinary: path.join(bin, "gemini-missing"),
    apnsConfigFile: path.join(tmp, "no-apns.json") });
  await app.start();
  base = `http://127.0.0.1:${app.server.address().port}`;
  token = app.auth.issue("Test iPad", "test").token;
});
after(async () => {
  await app.stop();
  try { for (const l of execFileSync("tmux", ["list-sessions", "-F", "#{session_name}"], { encoding: "utf8" }).split("\n")) if (/^mc-(login|install)-/.test(l)) execFileSync("tmux", ["kill-session", "-t", l]); } catch {}
  fs.rmSync(tmp, { recursive: true, force: true });
});

test("companion profile: generic defaults, never the Musa Studios ones", () => {
  const c = loadConfig({ profile: "companion", dataDir: path.join(tmp, "cfgcheck") });
  assert.equal(c.profile, "companion");
  assert.equal(c.passwordHashFile, null);
  assert.equal(c.publicBase, null);
  assert.deepEqual(c.services, []);
  assert.ok(!JSON.stringify(c.roots).includes("projects"));
  const p = loadConfig({ dataDir: path.join(tmp, "cfgcheck2") });
  assert.equal(p.profile, "personal");
  assert.equal(p.publicBase, "https://musastudios.co.uk/control");
});

test("/api/me reports the machine and what it can do", async () => {
  const me = await api("GET", "/api/me");
  assert.equal(me.status, 200);
  assert.equal(me.body.server.profile, "companion");
  assert.equal(me.body.server.user, os.userInfo().username);
  assert.equal(typeof me.body.capabilities.terminal, "boolean");
  assert.equal(me.body.capabilities.relay, "off");
  const projects = await api("GET", "/api/projects");
  assert.ok(projects.body.some((p) => p.name === "web-app"));
  // The tunnel's own address is the base for web views (no /control prefix, no Secure flag over loopback).
  const ws = await api("POST", "/api/web-session");
  assert.equal(ws.body.cookie.path, "/");
  assert.equal(ws.body.cookie.secure, false);
});

test("providers: detects install and sign-in state through each CLI's own status", async () => {
  const list = (await api("GET", "/api/providers?fresh=1")).body;
  const by = Object.fromEntries(list.map((p) => [p.id, p]));
  assert.equal(by.claude.installed, true);
  assert.equal(by.claude.version, "2.1.99");
  assert.equal(by.claude.auth.signedIn, false);
  assert.equal(by.codex.auth.signedIn, true);
  assert.equal(by.codex.auth.method, "ChatGPT");
  assert.equal(by.gemini.installed, false);
  for (const p of list) assert.ok(!("token" in p) && !JSON.stringify(p).includes("oauth_creds"), "no credentials in the response");
});

test("providers: sign-in runs the provider's own login in tmux; the app relays the link and the code", async () => {
  const r = await api("POST", "/api/providers/claude/login", {});
  assert.equal(r.status, 200);
  assert.match(r.body.tmux, /^mc-login-claude-[0-9a-f]{4}$/);
  const st = await wait(async () => { const s = (await api("GET", `/api/provider-sessions/${r.body.tmux}`)).body; return s.wantsCode ? s : null; });
  assert.ok(st, "waiting for the code");
  assert.ok(st.urls.some((u) => u.startsWith("https://claude.ai/oauth/authorize")));
  assert.equal((await api("POST", `/api/provider-sessions/${r.body.tmux}/input`, { text: "abc-123" })).status, 200);
  assert.ok(await wait(async () => (await api("GET", `/api/provider-sessions/${r.body.tmux}`)).body.screen?.includes("Got code: abc-123")));
  // Only sign-in sessions can be typed into through this route.
  assert.equal((await api("POST", "/api/provider-sessions/some-other-session/input", { text: "rm -rf /" })).status, 404);
  assert.equal((await api("POST", `/api/provider-sessions/${r.body.tmux}/input`, { text: "two\nlines" })).status, 400);
  await api("DELETE", `/api/provider-sessions/${r.body.tmux}`);
  // Installing needs an explicit confirmation.
  assert.equal((await api("POST", "/api/providers/gemini/install", {})).status, 428);
});

test("providers: API keys stay on the machine and are never returned", async () => {
  assert.equal((await api("PUT", "/api/providers/claude/key", { key: "not-a-key" })).status, 400);
  const key = "sk-ant-api03-" + "x".repeat(40) + "WXYZ";
  const r = await api("PUT", "/api/providers/claude/key", { key });
  assert.equal(r.status, 200);
  assert.equal(r.body.last4, "WXYZ");
  const list = (await api("GET", "/api/providers?fresh=1")).body;
  assert.equal(list.find((p) => p.id === "claude").apiKey.last4, "WXYZ");
  assert.ok(!JSON.stringify(list).includes(key));
  const file = path.join(tmp, "data", "provider-keys.json");
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(app.providers.envFor("claude"), { ANTHROPIC_API_KEY: key });
  await api("DELETE", "/api/providers/claude/key");
  assert.deepEqual(app.providers.envFor("claude"), {});
});

test("gemini: real CLI dialogs (folder trust, auth choice) parse as prompts", () => {
  const trust = parsePrompt(fs.readFileSync(new URL("./fixtures/gemini-trust-prompt.txt", import.meta.url), "utf8"));
  assert.equal(trust.kind, "trust");
  assert.equal(trust.question, "Do you trust the files in this folder?");
  assert.deepEqual(trust.options.map((o) => o.tone), ["allow", "allow", "deny"]);
  assert.deepEqual(keysFor(trust, 2), ["Down", "Down", "Enter"]);
  const auth = parsePrompt(fs.readFileSync(new URL("./fixtures/gemini-auth-choice.txt", import.meta.url), "utf8"));
  assert.deepEqual(auth.options.map((o) => o.label), ["Sign in with Google", "Use Gemini API Key", "Vertex AI"]);
});

test("gemini: chat recordings become sessions with prompts, commands, edits and turns", async () => {
  const st = {};
  const lines = [
    { sessionId: "g-1", projectHash: "h", startTime: "2026-11-12T10:00:00Z", kind: "main" },
    { id: "m1", timestamp: "2026-11-12T10:00:01Z", type: "user", content: [{ text: "Add a footer" }] },
    { id: "m2", timestamp: "2026-11-12T10:00:05Z", type: "gemini", content: "", toolCalls: [{ id: "t1", name: "run_shell_command", args: { command: "npm test" }, status: "executing" }] },
    { id: "m2", timestamp: "2026-11-12T10:00:06Z", type: "gemini", content: "", toolCalls: [{ id: "t1", name: "run_shell_command", args: { command: "npm test" }, status: "success", resultDisplay: "ok\nExit Code: 0" },
      { id: "t2", name: "replace", args: { file_path: `${proj}/index.html`, old_string: "a", new_string: "b" }, status: "success" }] },
    { id: "m3", timestamp: "2026-11-12T10:00:09Z", type: "gemini", content: "Added the footer.", model: "gemini-2.5-pro" },
    { $set: { summary: "footer" } },
  ];
  const evs = lines.flatMap((l) => parseGeminiLine(JSON.stringify(l), st));
  assert.equal(st.sessionId, "g-1");
  assert.deepEqual(evs.map((e) => e.kind), ["agent.prompt", "agent.test", "agent.edit", "agent.message", "agent.done"]);
  assert.equal(st.turn, "idle");
  // Live: a session file under ~/.gemini/tmp/<project>/chats shows up as an agent of that project.
  fs.writeFileSync(path.join(gem, "tmp", "web-app", "chats", "session-2026-11-12T10-00-g1.jsonl"), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  await app.agents.pollTranscripts();
  const a = (await api("GET", "/api/agents")).body.find((x) => x.id === "gemini:g-1");
  assert.ok(a, "gemini session listed");
  assert.equal(a.agentName, "Gemini CLI");
  assert.equal(a.project, "web-app");
  assert.equal(a.counts.edits, 1);
});

test("pairing codes are single-use and rate limited", async () => {
  const { code } = (await api("POST", "/api/pair-codes")).body;
  assert.match(code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  const ok = await api("POST", "/api/pair", { code: code.toLowerCase(), deviceName: "Second iPad" }, null);
  assert.equal(ok.status, 200);
  assert.match(ok.body.token, /^mc_/);
  assert.equal((await api("POST", "/api/pair", { code }, null)).status, 401);
});
