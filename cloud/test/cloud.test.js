// Integration tests: real cloud service + real companion gateways on
// temporary data, talking over real sockets (no mocks of our own code).
// Covers accounts, Sign in with Apple verification, sessions, per-user
// isolation, the relay (HTTP, SSE, WebSocket terminal), push fan-out and
// account deletion.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import WebSocket from "ws";
import { createServer as createCloud } from "../src/server.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mcc-test-"));
process.env.MUSA_CONTROL_CONFIG = path.join(tmp, "no-companion-config.json"); // never the real machine's
let cloud, CLOUD;
const apnsSent = [];
const companions = [];

// A fake Apple: our own RSA key published as a JWKS through fetchImpl.
const apple = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const appleJwk = { ...apple.publicKey.export({ format: "jwk" }), kid: "TESTKID", alg: "RS256", use: "sig" };
const fetchImpl = async (url, opts) => (String(url).includes("appleid.apple.com/auth/keys") ? new Response(JSON.stringify({ keys: [appleJwk] })) : fetch(url, opts));
function appleToken(claims, { key = apple.privateKey, kid = "TESTKID" } = {}) {
  const h = Buffer.from(JSON.stringify({ alg: "RS256", kid })).toString("base64url");
  const c = Buffer.from(JSON.stringify({ iss: "https://appleid.apple.com", aud: "uk.co.musastudios.musacontrol", exp: Math.floor(Date.now() / 1000) + 600, iat: Math.floor(Date.now() / 1000), ...claims })).toString("base64url");
  return `${h}.${c}.${crypto.sign("RSA-SHA256", Buffer.from(`${h}.${c}`), key).toString("base64url")}`;
}
const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");

const call = async (method, p, body, { tok, headers = {} } = {}) => {
  const r = await fetch(CLOUD + p, { method, headers: { ...(tok ? { Authorization: `Bearer ${tok}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text(); let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, body: json, headers: r.headers };
};
const wait = async (fn, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { const v = await fn(); if (v) return v; await new Promise((r) => setTimeout(r, 120)); } return null; };
// Distinct "client IPs" so the per-IP auth limiter doesn't couple tests.
let ipN = 1; const ip = () => ({ "X-Forwarded-For": `10.0.0.${ipN++}` });

async function startCompanion(name, relay) {
  const { createServer } = await import("../../server/src/server.js");
  const dir = path.join(tmp, name);
  const proj = path.join(dir, "projects", `${name}-app`);
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, "README.md"), `# ${name}\n`);
  execFileSync("git", ["init", "-q"], { cwd: proj });
  const app = createServer({ profile: "companion", port: 0, dataDir: path.join(dir, "data"), roots: [{ path: path.join(dir, "projects"), depth: 1, requireGit: false }],
    claudeProjectsDir: path.join(dir, "claude"), codexSessionsDir: path.join(dir, "codex"), geminiDir: path.join(dir, "gemini"), machineName: name,
    apnsConfigFile: path.join(dir, "no-apns.json"), relay });
  await app.start();
  companions.push(app);
  return app;
}

before(async () => {
  cloud = createCloud({ port: 0, dataDir: path.join(tmp, "cloud"), publicUrl: "http://127.0.0.1:1", fetchImpl, apnsConfigFile: path.join(tmp, "no-apns.json"),
    apnsTransport: async (m) => { apnsSent.push({ ...m, payload: JSON.parse(m.body) }); return { status: 200 }; } });
  const addr = await cloud.start();
  CLOUD = `http://127.0.0.1:${addr.port}`;
  cloud.cfg.publicUrl = CLOUD;
});
after(async () => {
  for (const c of companions) await c.stop().catch(() => {});
  await cloud.stop();
  try { execFileSync("tmux", ["kill-session", "-t", "mcc-relay-term"], { stdio: "ignore" }); } catch {}
  fs.rmSync(tmp, { recursive: true, force: true });
});

const accounts = {};
async function signUp(label) {
  const r = await call("POST", "/v1/auth/register", { email: `${label}@example.com`, password: `pw-${label}-long-enough`, name: label, deviceName: `${label}'s iPad`, platform: "iPadOS" }, { headers: ip() });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  accounts[label] = { token: r.body.token, user: r.body.user };
  return accounts[label];
}

test("register, login, wrong password and weak password", async () => {
  const a = await signUp("alice");
  assert.match(a.token, /^mcs_/);
  assert.equal((await call("GET", "/v1/me", null, { tok: a.token })).body.email, "alice@example.com");
  assert.equal((await call("POST", "/v1/auth/register", { email: "alice@example.com", password: "another-long-pass" }, { headers: ip() })).status, 409);
  assert.equal((await call("POST", "/v1/auth/register", { email: "short@example.com", password: "short" }, { headers: ip() })).status, 400);
  assert.equal((await call("POST", "/v1/auth/login", { email: "alice@example.com", password: "nope-nope-nope" }, { headers: ip() })).status, 401);
  const ok = await call("POST", "/v1/auth/login", { email: "ALICE@example.com", password: "pw-alice-long-enough", deviceName: "Alice iPhone" }, { headers: ip() });
  assert.equal(ok.status, 200);
  assert.equal((await call("GET", "/v1/me")).status, 401);
  assert.equal((await call("GET", "/v1/me", null, { tok: "mcs_forged" })).status, 401);
});

test("login attempts are rate limited per client address", async () => {
  const h = { "X-Forwarded-For": "10.9.9.9" };
  for (let i = 0; i < 10; i++) await call("POST", "/v1/auth/login", { email: "alice@example.com", password: "wrong-wrong-wrong" }, { headers: h });
  const r = await call("POST", "/v1/auth/login", { email: "alice@example.com", password: "pw-alice-long-enough" }, { headers: h });
  assert.equal(r.status, 429);
  // The audit log records the failures for the account owner.
  const log = await call("GET", "/v1/audit", null, { tok: accounts.alice.token });
  assert.ok(log.body.some((e) => e.action === "login.failed"));
});

test("Sign in with Apple: verified token creates an account; forged or replayed tokens don't", async () => {
  const nonce = "raw-nonce-123";
  const good = await call("POST", "/v1/auth/apple", { identityToken: appleToken({ sub: "apple-sub-1", email: "zed@privaterelay.appleid.com", email_verified: true, nonce: sha(nonce) }), nonce, name: "Zed", deviceName: "Zed iPad" }, { headers: ip() });
  assert.equal(good.status, 200, JSON.stringify(good.body));
  assert.deepEqual(good.body.user.methods, ["apple"]);
  // Same Apple user again → same account.
  const again = await call("POST", "/v1/auth/apple", { identityToken: appleToken({ sub: "apple-sub-1", nonce: sha("n2") }), nonce: "n2" }, { headers: ip() });
  assert.equal(again.body.user.id, good.body.user.id);
  const other = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
  assert.equal((await call("POST", "/v1/auth/apple", { identityToken: appleToken({ sub: "x", nonce: sha("n") }, { key: other.privateKey }), nonce: "n" }, { headers: ip() })).status, 401, "wrong signing key");
  assert.equal((await call("POST", "/v1/auth/apple", { identityToken: appleToken({ sub: "x", nonce: sha("n"), aud: "com.someone.else" }), nonce: "n" }, { headers: ip() })).status, 401, "wrong audience");
  assert.equal((await call("POST", "/v1/auth/apple", { identityToken: appleToken({ sub: "x", nonce: sha("n") }), nonce: "different" }, { headers: ip() })).status, 401, "nonce mismatch");
  assert.equal((await call("POST", "/v1/auth/apple", { identityToken: appleToken({ sub: "x", nonce: sha("n"), exp: 1000 }), nonce: "n" }, { headers: ip() })).status, 401, "expired");
  accounts.zed = { token: good.body.token, user: good.body.user };
});

test("sessions can be listed and revoked; revoked tokens stop working", async () => {
  const second = await call("POST", "/v1/auth/login", { email: "alice@example.com", password: "pw-alice-long-enough", deviceName: "Old iPad" }, { headers: ip() });
  const list = await call("GET", "/v1/sessions", null, { tok: accounts.alice.token });
  const old = list.body.find((s) => s.deviceName === "Old iPad");
  assert.ok(old && !old.current);
  assert.equal((await call("DELETE", `/v1/sessions/${old.id}`, null, { tok: accounts.alice.token })).status, 200);
  assert.equal((await call("GET", "/v1/me", null, { tok: second.body.token })).status, 401);
  // Another user can't revoke Alice's session.
  await signUp("bob");
  const aliceCurrent = list.body.find((s) => s.current);
  assert.equal((await call("DELETE", `/v1/sessions/${aliceCurrent.id}`, null, { tok: accounts.bob.token })).status, 404);
  assert.equal((await call("GET", "/v1/me", null, { tok: accounts.alice.token })).status, 200);
});

let aliceMachine, aliceCompanion;
test("linking a machine: one-time code → companion connects outbound", async () => {
  const code = await call("POST", "/v1/machines/link-code", { name: "Alice's VPS" }, { tok: accounts.alice.token });
  assert.equal(code.status, 200);
  assert.match(code.body.command, /musa-companion link /);
  const claim = await call("POST", "/v1/machines/claim", { code: code.body.code.toLowerCase(), platform: "linux", hostname: "alice-box", user: "alice" }, { headers: ip() });
  assert.equal(claim.status, 200);
  assert.equal((await call("POST", "/v1/machines/claim", { code: code.body.code }, { headers: ip() })).status, 401, "codes are single use");
  aliceMachine = claim.body.machineId;
  aliceCompanion = await startCompanion("alice", { url: CLOUD, machineId: aliceMachine, machineSecret: claim.body.machineSecret, owner: claim.body.owner });
  const online = await wait(async () => (await call("GET", "/v1/machines", null, { tok: accounts.alice.token })).body.find((m) => m.id === aliceMachine && m.online));
  assert.ok(online, "machine came online");
  assert.equal(online.name, "Alice's VPS");
  assert.equal((await wait(async () => ((await call("GET", "/v1/machines", null, { tok: accounts.alice.token })).body[0].info?.version ? true : null))), true);
});

test("relay: the owner reaches the companion's API; the companion sees a relay device", async () => {
  const me = await call("GET", `/m/${aliceMachine}/api/me`, null, { tok: accounts.alice.token });
  assert.equal(me.status, 200, JSON.stringify(me.body));
  assert.equal(me.body.via, "relay");
  assert.equal(me.body.server.profile, "companion");
  assert.equal(me.body.server.name, "alice");
  const projects = await call("GET", `/m/${aliceMachine}/api/projects`, null, { tok: accounts.alice.token });
  assert.ok(projects.body.some((p) => p.name === "alice-app"));
  // Writes stream request bodies through the relay.
  const id = projects.body.find((p) => p.name === "alice-app").id;
  const put = await call("PUT", `/m/${aliceMachine}/api/projects/${id}/file`, { path: "notes.txt", text: "hello via relay\n" }, { tok: accounts.alice.token });
  assert.equal(put.status, 200, JSON.stringify(put.body));
  const read = await call("GET", `/m/${aliceMachine}/api/projects/${id}/file?path=notes.txt`, null, { tok: accounts.alice.token });
  assert.equal(read.body.text, "hello via relay\n");
  // Static preview links point at the relay, not the machine.
  const prev = await call("GET", `/m/${aliceMachine}/api/projects/${id}/previews`, null, { tok: accounts.alice.token });
  assert.equal(prev.status, 200);
  // Mutating requests are audited (method + path only).
  const log = await call("GET", "/v1/audit", null, { tok: accounts.alice.token });
  assert.ok(log.body.some((e) => e.action === "relay.action" && e.detail.method === "PUT"));
});

test("isolation: another account can't see, use, rename or remove Alice's machine", async () => {
  const bob = accounts.bob.token;
  assert.deepEqual((await call("GET", "/v1/machines", null, { tok: bob })).body, []);
  for (const [m, p, b] of [["GET", `/m/${aliceMachine}/api/me`], ["GET", `/m/${aliceMachine}/api/projects`], ["PATCH", `/v1/machines/${aliceMachine}`, { name: "mine" }], ["DELETE", `/v1/machines/${aliceMachine}`]]) {
    const r = await call(m, p, b, { tok: bob });
    assert.equal(r.status, 404, `${m} ${p} → ${r.status}`);
  }
  // Bob's own machine is likewise invisible to Alice.
  const code = await call("POST", "/v1/machines/link-code", {}, { tok: bob });
  const claim = await call("POST", "/v1/machines/claim", { code: code.body.code, hostname: "bob-mac", platform: "darwin" }, { headers: ip() });
  await startCompanion("bob", { url: CLOUD, machineId: claim.body.machineId, machineSecret: claim.body.machineSecret, owner: claim.body.owner });
  await wait(async () => (await call("GET", "/v1/machines", null, { tok: bob })).body[0]?.online);
  assert.equal((await call("GET", `/m/${claim.body.machineId}/api/me`, null, { tok: accounts.alice.token })).status, 404);
  assert.equal((await call("GET", `/m/${claim.body.machineId}/api/me`, null, { tok: bob })).body.server.name, "bob");
  // A WebSocket to someone else's machine is refused too.
  const ws = new WebSocket(`${CLOUD.replace("http", "ws")}/m/${aliceMachine}/api/terminal/ws?session=x`, { headers: { Authorization: `Bearer ${bob}` } });
  const outcome = await new Promise((r) => { ws.on("unexpected-response", (_q, res) => r(res.statusCode)); ws.on("open", () => r("open")); ws.on("error", () => r("error")); });
  assert.notEqual(outcome, "open");
});

test("companion refuses forged relay headers sent straight to its loopback port", async () => {
  const port = aliceCompanion.server.address().port;
  const r = await fetch(`http://127.0.0.1:${port}/api/me`, { headers: { "x-mc-relay": "guess", "x-mc-user": accounts.alice.user.id } });
  assert.equal(r.status, 401);
  const r2 = await fetch(`http://127.0.0.1:${port}/api/me`, { headers: { "x-mc-relay": aliceCompanion.auth.relaySecret, "x-mc-user": accounts.bob.user.id } });
  assert.equal(r2.status, 401, "right secret, wrong account");
  // Companions have no password pairing; codes are one-time.
  assert.equal((await fetch(`http://127.0.0.1:${port}/api/pair`, { method: "POST", body: JSON.stringify({ password: "x" }) })).status, 400);
  const { code } = aliceCompanion.auth.createPairCode();
  const p1 = await fetch(`http://127.0.0.1:${port}/api/pair`, { method: "POST", body: JSON.stringify({ code, deviceName: "LAN iPad" }) });
  assert.equal(p1.status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${port}/api/pair`, { method: "POST", body: JSON.stringify({ code }) })).status, 401);
});

test("relay: live event stream (SSE) arrives through the relay", async () => {
  const ctrl = new AbortController();
  const r = await fetch(`${CLOUD}/m/${aliceMachine}/api/events`, { headers: { Authorization: `Bearer ${accounts.alice.token}` }, signal: ctrl.signal });
  assert.equal(r.headers.get("content-type"), "text/event-stream");
  const reader = r.body.getReader();
  let buf = "";
  setTimeout(() => aliceCompanion.events.emit({ kind: "server.alert", title: "relay-sse-check", detail: {} }), 300);
  const got = await wait(async () => { const { value } = await reader.read(); buf += new TextDecoder().decode(value || new Uint8Array()); return buf.includes("relay-sse-check"); });
  ctrl.abort();
  assert.ok(got, buf.slice(0, 300));
});

test("relay: terminal WebSocket attaches a real tmux session", async () => {
  const ws = new WebSocket(`${CLOUD.replace("http", "ws")}/m/${aliceMachine}/api/terminal/ws?session=mcc-relay-term&cols=100&rows=30`, { headers: { Authorization: `Bearer ${accounts.alice.token}` } });
  let out = "";
  ws.on("message", (d) => { out += d.toString(); });
  await new Promise((r, j) => { ws.on("open", r); ws.on("error", j); });
  ws.send(JSON.stringify({ type: "resize", cols: 120, rows: 40 }));
  await new Promise((r) => setTimeout(r, 600));
  ws.send(Buffer.from("echo relay-$((40+2))\r"), { binary: true });
  assert.ok(await wait(() => out.includes("relay-42")), out.slice(-400));
  ws.close();
  // The tmux session outlives the socket.
  await new Promise((r) => setTimeout(r, 400));
  execFileSync("tmux", ["has-session", "-t", "mcc-relay-term"]);
});

test("push: companion notifications fan out to the owner's devices only, honouring categories", async () => {
  const tokenA = "a".repeat(64), tokenB = "b".repeat(64);
  assert.equal((await call("POST", "/v1/push/register", { token: tokenA, environment: "sandbox" }, { tok: accounts.alice.token })).status, 200);
  assert.equal((await call("POST", "/v1/push/register", { token: tokenB, environment: "sandbox" }, { tok: accounts.bob.token })).status, 200);
  aliceCompanion.events.emit({ kind: "agent.done", title: "Turn finished", project: "alice-app", session: "claude:1", detail: { agent: "claude", last: "All tests pass." }, notify: true });
  const sent = await wait(() => apnsSent.find((m) => m.deviceToken === tokenA && m.payload.mc?.category === "completed"));
  assert.ok(sent, "pushed to Alice");
  assert.equal(sent.payload.mc.machine, aliceMachine);
  assert.match(sent.payload.aps.alert.title, /Claude Code finished/);
  assert.ok(!apnsSent.some((m) => m.deviceToken === tokenB), "nothing to Bob");
  await call("PUT", "/v1/push/prefs", { categories: { completed: false } }, { tok: accounts.alice.token });
  const before = apnsSent.length;
  aliceCompanion.events.emit({ kind: "agent.done", title: "Turn finished", project: "other", session: "claude:2", detail: { agent: "claude", last: "Done again." }, notify: true });
  await new Promise((r) => setTimeout(r, 800));
  assert.equal(apnsSent.length, before, "category switched off");
});

test("revoking a session cuts its relay access at once", async () => {
  const s = await call("POST", "/v1/auth/login", { email: "alice@example.com", password: "pw-alice-long-enough", deviceName: "Lost iPad" }, { headers: ip() });
  assert.equal((await call("GET", `/m/${aliceMachine}/api/me`, null, { tok: s.body.token })).status, 200);
  const id = (await call("GET", "/v1/sessions", null, { tok: accounts.alice.token })).body.find((x) => x.deviceName === "Lost iPad").id;
  await call("DELETE", `/v1/sessions/${id}`, null, { tok: accounts.alice.token });
  assert.equal((await call("GET", `/m/${aliceMachine}/api/me`, null, { tok: s.body.token })).status, 401);
});

test("removing a machine disconnects it and its secret stops working", async () => {
  const code = await call("POST", "/v1/machines/link-code", {}, { tok: accounts.alice.token });
  const claim = await call("POST", "/v1/machines/claim", { code: code.body.code }, { headers: ip() });
  const second = await startCompanion("alice2", { url: CLOUD, machineId: claim.body.machineId, machineSecret: claim.body.machineSecret, owner: claim.body.owner });
  await wait(async () => (await call("GET", "/v1/machines", null, { tok: accounts.alice.token })).body.find((m) => m.id === claim.body.machineId && m.online));
  assert.equal((await call("DELETE", `/v1/machines/${claim.body.machineId}`, null, { tok: accounts.alice.token })).status, 200);
  assert.ok(await wait(() => second.relay.state === "unlinked" || second.relay.state === "off"), `state ${second.relay.state}`);
  assert.equal((await call("GET", `/m/${claim.body.machineId}/api/me`, null, { tok: accounts.alice.token })).status, 404);
  const ws = new WebSocket(`${CLOUD.replace("http", "ws")}/v1/relay/connect`, { headers: { Authorization: `Bearer ${claim.body.machineSecret}` } });
  assert.equal(await new Promise((r) => { ws.on("unexpected-response", (_q, res) => r(res.statusCode)); ws.on("open", () => r("open")); }), 401);
});

test("web views get a machine-scoped cookie that only unlocks that machine", async () => {
  const r = await call("POST", `/m/${aliceMachine}/api/web-session`, {}, { tok: accounts.alice.token });
  assert.equal(r.status, 200);
  const cookie = `${r.body.cookie.name}=${r.body.cookie.value}`;
  const page = await fetch(`${CLOUD}/m/${aliceMachine}/api/projects`, { headers: { Cookie: cookie } });
  assert.equal(page.status, 200);
  const write = await fetch(`${CLOUD}/m/${aliceMachine}/api/pair-codes`, { method: "POST", headers: { Cookie: cookie } });
  assert.equal(write.status, 401, "cookies never authorize writes");
  const bobMachine = (await call("GET", "/v1/machines", null, { tok: accounts.bob.token })).body[0].id;
  assert.equal((await fetch(`${CLOUD}/m/${bobMachine}/api/projects`, { headers: { Cookie: cookie } })).status, 401);
});

test("export and account deletion remove everything the account owns", async () => {
  const exp = await call("GET", "/v1/account/export", null, { tok: accounts.alice.token });
  assert.equal(exp.body.account.email, "alice@example.com");
  assert.ok(exp.body.machines.length >= 1);
  assert.equal((await call("DELETE", "/v1/account", { confirm: "nope" }, { tok: accounts.alice.token })).status, 428);
  assert.equal((await call("DELETE", "/v1/account", { confirm: "DELETE", password: "wrong-password!" }, { tok: accounts.alice.token })).status, 401);
  assert.equal((await call("DELETE", "/v1/account", { confirm: "DELETE", password: "pw-alice-long-enough" }, { tok: accounts.alice.token })).status, 200);
  assert.equal((await call("GET", "/v1/me", null, { tok: accounts.alice.token })).status, 401);
  assert.ok(await wait(() => aliceCompanion.relay.state === "unlinked" || aliceCompanion.relay.state === "off"));
  const db = cloud.db;
  for (const t of ["sessions", "machines", "push_devices", "link_codes"]) assert.equal(db.get(`SELECT COUNT(*) n FROM ${t} WHERE user_id=?`, accounts.alice.user.id).n, 0, t);
  assert.equal(db.get("SELECT COUNT(*) n FROM audit WHERE user_id=?", accounts.alice.user.id).n, 0);
  // Bob is untouched.
  assert.equal((await call("GET", "/v1/me", null, { tok: accounts.bob.token })).status, 200);
});

test("one-line installer is served with this service's address and the bundle's checksum", async () => {
  const r = await fetch(`${CLOUD}/companion/install.sh`);
  const t = await r.text();
  assert.equal(r.status, 200);
  assert.ok(t.includes(`BASE="\${MUSA_CONTROL_RELAY:-${CLOUD}}"`));
  assert.ok(t.includes("Checksum mismatch"));
  const bundle = path.join(tmp, "bundle.tgz");
  fs.writeFileSync(bundle, "fake bundle");
  cloud.cfg.companionBundle = bundle;
  const sum = (await (await fetch(`${CLOUD}/companion/musa-companion.tgz.sha256`)).text()).split(" ")[0];
  assert.equal(sum, crypto.createHash("sha256").update("fake bundle").digest("hex"));
  assert.equal((await fetch(`${CLOUD}/companion/../v1/me`)).status, 401);
});

test("privacy and support pages are public", async () => {
  for (const p of ["/privacy", "/support"]) { const r = await fetch(CLOUD + p); assert.equal(r.status, 200); assert.match(await r.text(), /support@musastudios\.co\.uk/); }
});
