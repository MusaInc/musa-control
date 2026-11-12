// HTTP API for the Musa Control app. Everything except /api/ping and
// /api/pair requires a device token (Authorization: Bearer) — or, for pages
// and media loaded inside web views, the short-lived mc_web cookie.
import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { WebSocketServer } from "ws";
import { loadConfig } from "./config.js";
import { openDb } from "./db.js";
import { createAuth, clientAddress } from "./auth.js";
import { createEvents } from "./events.js";
import { createProjects } from "./projects.js";
import { createFiles, mimeOf } from "./files.js";
import { createGit } from "./git.js";
import { createWatcher } from "./watcher.js";
import { createScreenshots } from "./screenshots.js";
import { createAgents } from "./agents.js";
import { createVnc } from "./vnc.js";
import { createBuilds } from "./builds.js";
import { createGithub } from "./github.js";
import { createSystem } from "./system.js";
import { createPush } from "./push.js";
import { createProviders } from "./providers.js";
import { createTerminal } from "./terminal.js";
import { createRelayLink } from "./relay-link.js";
import { hasCommand, osName } from "./platform.js";
import { AGENTS } from "./agents.js";
import os from "node:os";
import { unifiedDiff } from "./diff.js";
import * as tmux from "./tmux.js";
import * as ssh from "./ssh.js";

export const VERSION = "0.4.0";
export const RELAY_PUSH_TOKEN = "0".repeat(64); // the pseudo push device that stands for "the linked account"
const WEB_DIR = new URL("../web/", import.meta.url).pathname;

function json(res, status, body, headers = {}) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers });
  res.end(data);
}

async function readBody(req, limit = 2 * 1024 * 1024) {
  const chunks = []; let n = 0;
  for await (const c of req) { n += c.length; if (n > limit) throw Object.assign(new Error("Request too large"), { status: 413 }); chunks.push(c); }
  return Buffer.concat(chunks);
}
async function readJson(req) { const b = await readBody(req); if (!b.length) return {}; try { return JSON.parse(b.toString("utf8")); } catch { throw Object.assign(new Error("Invalid JSON"), { status: 400 }); } }

async function sendFile(req, res, full, { mime, cache = "private, max-age=60", extra = {} } = {}) {
  const st = await fsp.stat(full);
  const type = mime || mimeOf(full);
  const range = req.headers.range && /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
  const base = { "Content-Type": type, "Cache-Control": cache, "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff", ...extra };
  if (type === "text/html" || type === "image/svg+xml") base["Content-Security-Policy"] = "sandbox allow-scripts";
  if (range) {
    let start = range[1] ? +range[1] : st.size - +range[2], end = range[1] && range[2] ? +range[2] : st.size - 1;
    if (!range[1]) end = st.size - 1;
    if (start > end || end >= st.size) { res.writeHead(416, { "Content-Range": `bytes */${st.size}` }); return res.end(); }
    res.writeHead(206, { ...base, "Content-Range": `bytes ${start}-${end}/${st.size}`, "Content-Length": end - start + 1 });
    return fs.createReadStream(full, { start, end }).pipe(res);
  }
  res.writeHead(200, { ...base, "Content-Length": st.size });
  if (req.method === "HEAD") return res.end();
  fs.createReadStream(full).pipe(res);
}

export function createServer(overrides = {}) {
  const cfg = loadConfig(overrides);
  const db = openDb(cfg);
  const auth = createAuth(cfg, db);
  const events = createEvents(db);
  const projects = createProjects(cfg);
  const files = createFiles(cfg, projects, events);
  const git = createGit(projects, events);
  const screenshots = createScreenshots(cfg, db, projects, events);
  const watcher = createWatcher(cfg, db, projects, events, screenshots);
  const providers = createProviders(cfg, events);
  const agents = createAgents(cfg, db, projects, events, { watcher, screenshots, providerEnv: providers.envFor });
  const vnc = createVnc(cfg, events);
  const builds = createBuilds(cfg, db, projects, events);
  const github = createGithub(events);
  const system = createSystem(cfg, events);
  // Relay link (companion linked to a Musa Control account): requests come in
  // over it, and pushes for the owner's devices go out through it.
  let relayState = { state: cfg.relay?.url ? "connecting" : "off", detail: null, since: Date.now() };
  const relay = cfg.relay?.url ? createRelayLink(cfg, auth, {
    localPort: () => server.address()?.port || cfg.port,
    info: () => ({ name: cfg.machineName || os.hostname(), platform: process.platform, os: osName(), version: VERSION, profile: cfg.profile, agents: AGENTS }),
    onState: (st, detail) => { relayState = { state: st, detail: detail || null, since: Date.now() }; },
  }) : null;
  const push = createPush(cfg, db, events, agents, { transport: overrides.apnsTransport, relay, relayToken: RELAY_PUSH_TOKEN });
  const terminal = createTerminal(cfg, projects, events);
  const wss = new WebSocketServer({ noServer: true, handleProtocols: (protocols) => (protocols.has("binary") ? "binary" : false), maxPayload: 8 * 1024 * 1024 });

  const routes = [];
  const route = (method, pattern, handler, opts = {}) => {
    const keys = [];
    const re = new RegExp("^" + pattern.replace(/:(\w+)/g, (_, k) => { keys.push(k); return "([^/]+)"; }).replace(/\*$/, "(.*)") + "$");
    if (pattern.endsWith("*")) keys.push("rest");
    routes.push({ method, re, keys, handler, opts });
  };

  // ---------- public ----------
  route("GET", "/api/ping", () => ({ ok: true, service: "musa-control", version: VERSION, time: Date.now() }), { public: true });
  route("POST", "/api/pair", async ({ req, res }) => {
    const body = await readJson(req);
    const r = await auth.pair(body, clientAddress(req));
    json(res, r.status, r.body || { error: r.error });
  }, { public: true });

  // Absolute base URL of this gateway as the app sees it: the public Caddy
  // prefix (personal), the relay's /m/<machine> prefix (relay requests carry
  // it), or the local end of the app's SSH tunnel (Host header).
  function baseFor(req, device) {
    if (device?.relay && /^https:\/\//.test(device.base || "")) return device.base.replace(/\/+$/, "");
    if (cfg.publicBase) return cfg.publicBase.replace(/\/+$/, "");
    const host = String(req.headers.host || `127.0.0.1:${cfg.port}`).replace(/[^\w.:\[\]-]/g, "");
    return `http://${host}`;
  }

  async function capabilities() {
    const [tmuxBin, py, git, gh, ss, lsof] = await Promise.all(["tmux", cfg.python3 || "python3", "git", "gh", "ss", "lsof"].map((c) => hasCommand(c)));
    return {
      profile: cfg.profile, platform: process.platform, os: osName(), arch: process.arch, node: process.version,
      terminal: Boolean(tmuxBin), terminalOverSocket: Boolean(tmuxBin && py && terminal.available()), agents: Boolean(tmuxBin),
      git: Boolean(git), github: Boolean(gh), remoteDesktop: fs.existsSync(cfg.noVncDir) && Object.keys(cfg.vnc?.known || {}).length > 0,
      previews: Boolean(ss || lsof), services: cfg.services.length > 0, push: push.enabled || Boolean(relay),
      relay: relay ? relayState.state : "off",
    };
  }

  // ---------- session ----------
  route("GET", "/api/me", async ({ device }) => ({ id: device.id, name: device.name, expiresAt: device.expires_at, via: device.relay ? "relay" : "token",
    server: { version: VERSION, host: cfg.sshHost || (cfg.profile === "personal" ? "musastudios.co.uk" : os.hostname()), profile: cfg.profile, name: cfg.machineName || os.hostname(), user: os.userInfo().username, home: cfg.home },
    capabilities: await capabilities() }));
  route("GET", "/api/capabilities", () => capabilities());
  // A paired device can mint a one-time code to pair another one.
  route("POST", "/api/pair-codes", ({ device }) => { const c = auth.createPairCode(); events.emit({ kind: "device.code", title: `Pairing code created by ${device.name}`, detail: {} }); return c; });
  route("GET", "/api/relay", () => ({ linked: Boolean(cfg.relay?.url), url: cfg.relay?.url || null, machineId: cfg.relay?.machineId || null, ...relayState }));

  // ---------- AI providers (on this machine) ----------
  route("GET", "/api/providers", ({ q }) => providers.list({ fresh: q.get("fresh") === "1" }));
  route("POST", "/api/providers/:id/login", ({ params, body }) => providers.startLogin(params.id, { method: body.method }));
  route("POST", "/api/providers/:id/install", ({ params, body }) => { confirm(body, "install"); return providers.install(params.id); });
  route("PUT", "/api/providers/:id/key", ({ params, body }) => providers.setKey(params.id, body.key));
  route("DELETE", "/api/providers/:id/key", ({ params }) => providers.deleteKey(params.id));
  route("GET", "/api/provider-sessions/:tmux", ({ params }) => providers.loginState(params.tmux));
  route("POST", "/api/provider-sessions/:tmux/input", ({ params, body }) => providers.loginInput(params.tmux, body.text));
  route("DELETE", "/api/provider-sessions/:tmux", ({ params }) => providers.endLogin(params.tmux));
  route("GET", "/api/devices", () => auth.listDevices().filter((d) => d.id !== "relay"));
  route("DELETE", "/api/devices/:id", ({ params }) => { auth.revoke(params.id); ssh.deauthorize(params.id, cfg.authorizedKeysFile); return { ok: true }; });
  route("GET", "/api/ssh/hostkeys", () => ({ ...ssh.hostKeys(), host: cfg.sshHost || (cfg.profile === "personal" ? "musastudios.co.uk" : os.hostname()) }));
  route("POST", "/api/ssh/authorize", ({ device, body }) => {
    const r = ssh.authorize(device.id, device.name, body.publicKey, cfg.authorizedKeysFile);
    events.emit({ kind: "ssh.authorized", title: `SSH key installed for ${device.name}`, detail: { device: device.id } });
    return { ...r, ...ssh.hostKeys(), host: cfg.sshHost || (cfg.profile === "personal" ? "musastudios.co.uk" : os.hostname()) };
  });
  route("POST", "/api/web-session", ({ device, req, res }) => {
    const base = new URL(baseFor(req, device));
    const c = auth.issueWebCookie(device, { path: base.pathname.replace(/\/+$/, "") || "/", secure: base.protocol === "https:" });
    json(res, 200, { cookie: { name: c.name, value: c.value, path: c.path, maxAge: c.maxAge, secure: base.protocol === "https:" }, base: base.toString().replace(/\/+$/, "") }, { "Set-Cookie": c.header });
  });

  // ---------- overview ----------
  route("GET", "/api/overview", async () => {
    const [sys, agentList, shots] = await Promise.all([system.snapshot(), agents.list(), screenshots.list({ limit: 12 })]);
    const recent = events.query({ limit: 60, kinds: ["agent.done", "agent.error", "agent.approval", "build.finished", "ci.finished", "git.commit", "git.push", "screenshot.new", "server.alert", "agent.started", "agent.edit", "file.changed"] });
    const changing = new Map();
    for (const e of events.query({ limit: 400, kinds: ["file.changed", "agent.edit"] })) {
      if (!e.project || Date.now() - e.ts > 3600_000) continue;
      const c = changing.get(e.project) || { project: e.project, files: new Set(), last: 0 };
      if (e.detail?.path) c.files.add(e.detail.path); c.last = Math.max(c.last, e.ts); changing.set(e.project, c);
    }
    return {
      system: { healthy: sys.healthy, issues: sys.issues, load: sys.load, cpus: sys.cpus, memory: sys.memory, disk: sys.disk, uptime: sys.uptime,
        services: sys.services.filter((s) => s.active !== "inactive" || cfg.services.includes(s.name)) },
      agents: agentList.filter((a) => a.status !== "ended" || Date.now() - a.lastActivity < 6 * 3600_000).slice(0, 40),
      attention: agentList.filter((a) => a.status === "approval" || a.status === "failed"),
      changingProjects: [...changing.values()].map((c) => ({ project: c.project, files: c.files.size, sample: [...c.files].slice(0, 5), last: c.last })).sort((a, b) => b.last - a.last),
      screenshots: shots, builds: builds.list(null, 10), recent: recent.reverse().slice(0, 40), watching: watcher.status(),
    };
  });
  route("GET", "/api/system", () => system.snapshot());
  route("GET", "/api/tmux", async () => ({ sessions: await tmux.listSessions(), panes: await tmux.listPanes() }));

  // ---------- projects + files ----------
  route("GET", "/api/projects", () => {
    const active = new Map();
    for (const a of agents.list()) if (a.project && a.status !== "ended") active.set(a.project, (active.get(a.project) || 0) + 1);
    return [...projects.all().values()].map((p) => ({ ...p, activeAgents: active.get(p.id) || 0 })).sort((a, b) => b.activeAgents - a.activeAgents || a.name.localeCompare(b.name));
  });
  route("GET", "/api/projects/:id", async ({ params }) => {
    const d = projects.details(params.id);
    const ports = (await system.listeningPorts()).filter((p) => p.cwd && (p.cwd === d.path || p.cwd.startsWith(d.path + "/")));
    return { ...d, localServers: ports, git: await git.status(params.id).catch((e) => ({ error: e.message })), builds: builds.list(params.id, 10) };
  });
  route("POST", "/api/projects/:id/watch", async ({ params, body }) => watcher.activate(params.id, Math.min(+body.minutes || 30, 240)));
  route("GET", "/api/projects/:id/files", ({ params, q }) => files.list(params.id, q.get("path") || ""));
  route("GET", "/api/projects/:id/file", ({ params, q }) => files.read(params.id, q.get("path")));
  route("PUT", "/api/projects/:id/file", async ({ params, body, res }) => { const r = await files.write(params.id, body.path, String(body.text ?? ""), body.baseSha || null, { force: Boolean(body.force) }); json(res, r.status, r.body); }, { bodyLimit: 8 * 1024 * 1024 });
  route("DELETE", "/api/projects/:id/file", ({ params, q }) => files.remove(params.id, q.get("path")));
  route("POST", "/api/projects/:id/mkdir", ({ params, body }) => files.mkdir(params.id, body.path));
  route("POST", "/api/projects/:id/move", ({ params, body }) => files.move(params.id, body.from, body.to, { copy: Boolean(body.copy) }));
  route("POST", "/api/projects/:id/upload", async ({ params, q, req }) => files.upload(params.id, q.get("path"), await readBody(req, 200 * 1024 * 1024)), { raw: true });
  route("GET", "/api/projects/:id/search", ({ params, q }) => files.search(params.id, q.get("q") || "", { mode: q.get("mode") || "content" }));
  route("GET", "/api/projects/:id/raw", async ({ params, q, req, res }) => { const r = projects.resolveInside(params.id, q.get("path")); await sendFile(req, res, r.full, { extra: q.get("download") ? { "Content-Disposition": `attachment; filename="${path.basename(r.full).replace(/"/g, "")}"` } : {} }); }, { cookie: true });
  route("GET", "/api/projects/:id/thumb", async ({ params, q, req, res }) => { const r = projects.resolveInside(params.id, q.get("path")); await sendFile(req, res, await files.thumbnail(r.full, Math.min(+q.get("w") || 480, 1600)), { mime: "image/jpeg", cache: "private, max-age=3600" }); }, { cookie: true });
  route("GET", "/api/trash", () => files.trashList());
  route("POST", "/api/trash/:id/restore", ({ params }) => files.restore(params.id));
  route("GET", "/api/projects/:id/revisions", ({ params, q }) => (q.get("path") ? watcher.revisions(params.id, projects.resolveInside(params.id, q.get("path"), { mustExist: false }).rel) : watcher.recentRevisions(params.id)));
  route("GET", "/api/revisions/:id", ({ params }) => watcher.revisionContent(+params.id) || Promise.reject(Object.assign(new Error("No such revision"), { status: 404 })));
  route("GET", "/api/revisions/:id/diff", ({ params }) => {
    const r = watcher.revisionContent(+params.id);
    if (!r) throw Object.assign(new Error("No such revision"), { status: 404 });
    return { id: r.id, path: r.path, previousId: r.previousId, diff: r.previousText === null ? null : unifiedDiff(r.previousText, r.text, { path: r.path }) };
  });

  // ---------- git ----------
  route("GET", "/api/projects/:id/git/status", ({ params }) => git.status(params.id));
  route("GET", "/api/projects/:id/git/log", ({ params, q }) => git.log(params.id, { limit: q.get("limit"), file: q.get("file") }));
  route("GET", "/api/projects/:id/git/branches", ({ params }) => git.branches(params.id));
  route("GET", "/api/projects/:id/git/diff", ({ params, q }) => git.diff(params.id, { file: q.get("file"), staged: q.get("staged") === "1", commit: q.get("commit") }));
  route("GET", "/api/projects/:id/git/show", ({ params, q }) => git.showFile(params.id, q.get("path"), q.get("ref") || "HEAD"));
  route("POST", "/api/projects/:id/git/stage", ({ params, body }) => git.stage(params.id, body.paths));
  route("POST", "/api/projects/:id/git/unstage", ({ params, body }) => git.unstage(params.id, body.paths));
  route("POST", "/api/projects/:id/git/commit", ({ params, body }) => git.commit(params.id, body.message));
  route("POST", "/api/projects/:id/git/push", ({ params, body }) => { confirm(body, "push"); return git.push(params.id); });
  route("POST", "/api/projects/:id/git/pull", ({ params, body }) => { confirm(body, "pull"); return git.pull(params.id); });

  // ---------- previews ----------
  route("GET", "/api/projects/:id/previews", async ({ params, req, device }) => {
    const d = projects.details(params.id);
    const ports = (await system.listeningPorts()).filter((p) => p.cwd && (p.cwd === d.path || p.cwd.startsWith(d.path + "/")) && p.port > 1024);
    const staticBuilds = [];
    for (const rel of ["build/web/index.html", "dist/index.html", "build/index.html", "web/index.html", "public/index.html", "redesigned/index.html", "out/index.html", "index.html"]) {
      if (fs.existsSync(path.join(d.path, rel))) staticBuilds.push({ label: rel.replace(/\/?index\.html$/, "") || "Project root", path: rel, url: `${baseFor(req, device)}/static/${d.id}/${rel}` });
    }
    return { public: d.previews, local: ports.map((p) => ({ port: p.port, process: p.process, pid: p.pid, cwd: p.cwd, label: `${p.process} :${p.port}` })), static: staticBuilds };
  });

  // Authenticated reverse proxy to a project's local dev server. Only ports
  // owned by a process running inside a project directory are reachable, so
  // infrastructure ports (CDP, Caddy admin, VNC, databases) never are.
  async function previewPorts() {
    const all = [...projects.all().values()];
    return new Set((await system.listeningPorts()).filter((p) => p.port > 1024 && p.cwd && all.some((x) => p.cwd === x.path || p.cwd.startsWith(x.path + "/"))).map((p) => p.port));
  }
  let portCache = { at: 0, set: new Set() };
  for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]) {
    route(method, "/api/proxy/:port/*", async ({ req, res, params }) => {
      const port = Number(params.port);
      if (Date.now() - portCache.at > 5000) portCache = { at: Date.now(), set: await previewPorts() };
      if (!portCache.set.has(port)) throw Object.assign(new Error("That port isn't a project dev server"), { status: 403 });
      const qs = new URL(req.url, "http://x").search;
      const headers = { ...req.headers, host: `127.0.0.1:${port}` };
      for (const h of ["authorization", "connection", "upgrade", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "origin", "referer", "cookie"]) delete headers[h];
      if (req.headers["x-mc-cookie"]) { headers.cookie = req.headers["x-mc-cookie"]; delete headers["x-mc-cookie"]; }
      await new Promise((resolve) => {
        const up = http.request({ host: "127.0.0.1", port, method: req.method, path: "/" + (params.rest || "") + qs, headers }, (r) => {
          const h = { ...r.headers };
          delete h["content-security-policy"]; delete h["x-frame-options"];
          if (h["set-cookie"]) { h["x-mc-set-cookie"] = h["set-cookie"].join("\n"); delete h["set-cookie"]; }
          res.writeHead(r.statusCode, h);
          r.pipe(res); r.on("end", resolve);
        });
        up.on("error", (e) => { if (!res.headersSent) json(res, 502, { error: `Dev server on ${port} didn't answer: ${e.message}` }); resolve(); });
        req.pipe(up);
      });
    }, { raw: true, cookie: true });
  }

  // ---------- builds + CI ----------
  route("GET", "/api/builds", ({ q }) => builds.list(q.get("project") || null, 40));
  route("GET", "/api/projects/:id/builds", ({ params }) => builds.list(params.id));
  route("POST", "/api/projects/:id/builds", ({ params, body }) => builds.start(params.id, body.commandId));
  route("GET", "/api/builds/:id", ({ params, q }) => builds.log(params.id, { tail: Math.min(+q.get("tail") || 64 * 1024, 4 * 1024 * 1024) }));
  route("POST", "/api/builds/:id/cancel", ({ params }) => builds.cancel(params.id));
  route("GET", "/api/github/repos", () => [...projects.all().values()].filter((p) => p.github).map((p) => ({ project: p.id, name: p.name, repo: p.github })));
  route("GET", "/api/github/:owner/:repo/runs", ({ params, q }) => github.runs(`${params.owner}/${params.repo}`, Math.min(+q.get("limit") || 20, 100)));
  route("GET", "/api/github/:owner/:repo/runs/:run", ({ params }) => github.runDetail(`${params.owner}/${params.repo}`, params.run));
  route("GET", "/api/github/:owner/:repo/runs/:run/log", ({ params, q }) => github.runLog(`${params.owner}/${params.repo}`, params.run, { failedOnly: q.get("all") !== "1" }));
  route("POST", "/api/github/:owner/:repo/runs/:run/rerun", ({ params, body }) => { confirm(body, "rerun"); return github.rerun(`${params.owner}/${params.repo}`, params.run, { failed: body.failedOnly !== false }); });
  route("POST", "/api/github/:owner/:repo/runs/:run/cancel", ({ params, body }) => { confirm(body, "cancel"); return github.cancel(`${params.owner}/${params.repo}`, params.run); });
  route("GET", "/api/github/:owner/:repo/workflows", ({ params }) => github.workflows(`${params.owner}/${params.repo}`));
  route("POST", "/api/github/:owner/:repo/dispatch", ({ params, body }) => { confirm(body, "dispatch"); return github.dispatch(`${params.owner}/${params.repo}`, body.workflow, body.inputs || {}); });
  route("GET", "/api/github/:owner/:repo/pulls", ({ params }) => github.prs(`${params.owner}/${params.repo}`));
  route("GET", "/api/github/:owner/:repo/pulls/:n", ({ params }) => github.prView(`${params.owner}/${params.repo}`, params.n));
  route("GET", "/api/github/:owner/:repo/pulls/:n/diff", ({ params }) => github.prDiff(`${params.owner}/${params.repo}`, params.n));

  // ---------- agents ----------
  route("GET", "/api/agents", ({ q }) => agents.list({ includeEnded: q.get("all") !== "0" }));
  route("POST", "/api/agents", ({ body }) => agents.launch(body));
  route("GET", "/api/agents/:id", ({ params }) => agents.get(decodeURIComponent(params.id)));
  route("GET", "/api/agents/:id/screen", ({ params, q }) => agents.screen(decodeURIComponent(params.id), { ansi: q.get("ansi") !== "0", lines: Math.min(+q.get("lines") || 200, 3000) }));
  route("GET", "/api/agents/:id/timeline", ({ params, q }) => events.query({ session: decodeURIComponent(params.id), before: q.get("before"), after: q.get("after"), limit: q.get("limit") || 300 }));
  route("POST", "/api/agents/:id/send", ({ params, body }) => agents.send(decodeURIComponent(params.id), String(body.text || "")));
  route("POST", "/api/agents/:id/approval", ({ params, body }) => agents.answer(decodeURIComponent(params.id), body));
  route("POST", "/api/agents/:id/interrupt", ({ params }) => agents.interrupt(decodeURIComponent(params.id)));
  route("POST", "/api/agents/:id/end", ({ params, body }) => { confirm(body, "end"); return agents.end(decodeURIComponent(params.id)); });
  route("POST", "/api/attachments", async ({ q, req }) => agents.attachFile(q.get("project"), q.get("name"), await readBody(req, 60 * 1024 * 1024)), { raw: true });

  // ---------- push notifications ----------
  route("GET", "/api/push", ({ device }) => push.status(device));
  route("POST", "/api/push/register", ({ device, body }) => push.register(device, body));
  route("DELETE", "/api/push/register", ({ device }) => push.unregister(device));
  route("PUT", "/api/push/prefs", ({ device, body }) => push.setPrefs(device, body));
  route("POST", "/api/push/test", ({ device }) => push.test(device));
  route("POST", "/api/push/action", ({ device, body }) => push.act(device, body));

  // ---------- timeline + events ----------
  route("GET", "/api/timeline", ({ q }) => events.query({ project: q.get("project"), session: q.get("session"), kinds: q.get("kinds")?.split(",").filter(Boolean), after: q.get("after"), before: q.get("before"), limit: q.get("limit") || 200 }));
  route("GET", "/api/notifications", ({ q }) => events.query({ notify: true, after: q.get("after") || 0, limit: 50 }));
  route("GET", "/api/events", ({ req, res, q }) => {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive", "X-Accel-Buffering": "no" });
    const project = q.get("project");
    const since = req.headers["last-event-id"] || q.get("since");
    const send = (e) => { if (project && e.project && e.project !== project) return; res.write(`${e.id ? `id: ${e.id}\n` : ""}event: ${e.kind}\ndata: ${JSON.stringify(e)}\n\n`); };
    if (since) for (const e of events.query({ after: since, project, limit: 500 })) send(e);
    res.write(`event: hello\ndata: ${JSON.stringify({ time: Date.now(), version: VERSION })}\n\n`);
    const unsub = events.subscribe(send);
    const ping = setInterval(() => res.write(`: ping ${Date.now()}\n\n`), 20_000);
    req.on("close", () => { unsub(); clearInterval(ping); });
  });

  // ---------- screenshots ----------
  route("GET", "/api/screenshots", ({ q }) => screenshots.list({ project: q.get("project"), session: q.get("session"), limit: Math.min(+q.get("limit") || 100, 500), before: q.get("before") }));
  route("GET", "/api/screenshots/:id/image", async ({ params, q, req, res }) => {
    const s = screenshots.get(params.id);
    if (!s || !fs.existsSync(s.path)) throw Object.assign(new Error("Screenshot gone"), { status: 404 });
    const w = +q.get("w");
    if (w) await sendFile(req, res, await files.thumbnail(s.path, Math.min(w, 1600)), { mime: "image/jpeg", cache: "private, max-age=3600" });
    else await sendFile(req, res, s.path, { cache: "private, max-age=300" });
  }, { cookie: true });
  // Captures taken in the app (preview snapshots) are stored by the gateway,
  // not written into the project tree.
  route("POST", "/api/screenshots", async ({ q, req }) => {
    const project = projects.get(q.get("project")).id;
    const name = String(q.get("name") || "capture.png").replace(/[^\w.-]+/g, "_").slice(-80);
    if (!/\.(png|jpe?g)$/i.test(name)) throw Object.assign(new Error("PNG or JPEG only"), { status: 400 });
    const dir = path.join(cfg.dataDir, "captures", project);
    await fsp.mkdir(dir, { recursive: true });
    const full = path.join(dir, `${Date.now()}-${name}`);
    await fsp.writeFile(full, await readBody(req, 40 * 1024 * 1024));
    const row = await screenshots.consider(full, { project, source: "preview" });
    if (!row) throw Object.assign(new Error("Image was too small or unreadable"), { status: 422 });
    return row;
  }, { raw: true });
  route("POST", "/api/screenshots/:id/note", ({ params, body }) => screenshots.annotate(params.id, body.note));
  route("POST", "/api/screenshots/:id/send", async ({ params, body }) => {
    const s = screenshots.get(params.id);
    if (!s) throw Object.assign(new Error("Unknown screenshot"), { status: 404 });
    let extra = "";
    if (body.annotatedPng) {
      const a = await agents.attachFile(s.project || "musa-control", `annotated-${path.basename(s.path)}`, Buffer.from(String(body.annotatedPng), "base64"));
      extra = `\nAnnotated copy (my markings): ${a.path}`;
    }
    const text = `${String(body.text || "Look at this screenshot.").trim()}\n\nScreenshot: ${s.path}${extra}`;
    return agents.send(String(body.agent), text);
  }, { bodyLimit: 30 * 1024 * 1024 });

  // ---------- remote desktop ----------
  route("GET", "/api/vnc/displays", () => vnc.displays());

  // ---------- web pages for WKWebView (cookie auth) ----------
  route("GET", "/vnc.html", async ({ req, res }) => sendFile(req, res, path.join(WEB_DIR, "vnc.html"), { mime: "text/html; charset=utf-8", cache: "no-store", extra: { "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' wss:; img-src 'self' data: blob:", "X-Frame-Options": "DENY" } }), { cookie: true });
  route("GET", "/web/*", async ({ params, req, res }) => {
    const rel = params.rest.replace(/\.\./g, "");
    const full = path.join(WEB_DIR, rel);
    if (!full.startsWith(WEB_DIR) || !fs.existsSync(full)) throw Object.assign(new Error("Not found"), { status: 404 });
    const mime = full.endsWith(".js") ? "text/javascript; charset=utf-8" : full.endsWith(".css") ? "text/css" : undefined;
    await sendFile(req, res, full, { mime, cache: "no-cache" });
  }, { cookie: true });
  route("GET", "/novnc/*", async ({ params, req, res }) => {
    const full = path.resolve(cfg.noVncDir, params.rest);
    if (!full.startsWith(cfg.noVncDir + "/") || !fs.existsSync(full) || fs.statSync(full).isDirectory()) throw Object.assign(new Error("Not found"), { status: 404 });
    await sendFile(req, res, full, { mime: full.endsWith(".js") ? "text/javascript; charset=utf-8" : undefined, cache: "private, max-age=86400" });
  }, { cookie: true });
  // Static project builds (Godot web exports, built sites) with the headers
  // Godot's threaded builds need.
  route("GET", "/static/:project/*", async ({ params, req, res }) => {
    const r = projects.resolveInside(params.project, decodeURIComponent(params.rest || "index.html"));
    let full = r.full;
    if (fs.statSync(full).isDirectory()) full = path.join(full, "index.html");
    const mime = full.endsWith(".wasm") ? "application/wasm" : full.endsWith(".js") ? "text/javascript; charset=utf-8" : full.endsWith(".html") ? "text/html; charset=utf-8" : full.endsWith(".pck") ? "application/octet-stream" : full.endsWith(".css") ? "text/css" : undefined;
    await sendFile(req, res, full, { mime, cache: "no-cache", extra: { "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp", "Cross-Origin-Resource-Policy": "same-origin", "Content-Security-Policy": "frame-ancestors 'self'" } });
  }, { cookie: true });

  // The linked account appears to push.js as one device whose "token" is the
  // relay; the service fans each push out to the owner's own iPads/iPhones.
  function ensureRelayPushDevice() {
    db.raw.prepare("INSERT OR IGNORE INTO devices(id,name,token_hash,created_at,expires_at) VALUES('relay','Musa Control account',?,?,?)")
      .run("relay-unusable-" + auth._hash(String(Math.random())), Date.now(), Date.now() + 100 * 365 * 86400_000);
    db.raw.prepare(`INSERT OR IGNORE INTO push_devices(device_id,apns_token,environment,prefs,updated_at) VALUES('relay',?,'production','{}',?)`).run(RELAY_PUSH_TOKEN, Date.now());
  }

  function confirm(body, what) {
    if (body?.confirm !== true) throw Object.assign(new Error(`Confirmation required to ${what}`), { status: 428 });
  }

  async function handle(req, res) {
    const url = new URL(req.url, "http://localhost");
    let pathname = url.pathname.replace(/^\/control(?=\/)/, ""); // tolerate an unstripped prefix
    for (const r of routes) {
      if (r.method !== req.method && !(r.method === "GET" && req.method === "HEAD")) continue;
      const m = r.re.exec(pathname);
      if (!m) continue;
      const params = Object.fromEntries(r.keys.map((k, i) => [k, m[i + 1]]));
      let device = null;
      if (!r.opts.public) {
        device = auth.authenticate(req, { allowCookie: Boolean(r.opts.cookie) });
        if (!device) return json(res, 401, { error: "Pair this device with Musa Control first." }, { "WWW-Authenticate": "Bearer" });
      }
      try {
        const body = !r.opts.raw && ["POST", "PUT", "PATCH", "DELETE"].includes(req.method) && !r.opts.public ? await (async () => { const b = await readBody(req, r.opts.bodyLimit || 2 * 1024 * 1024); return b.length ? JSON.parse(b.toString("utf8")) : {}; })() : {};
        const out = await r.handler({ req, res, params, q: url.searchParams, body, device });
        if (!res.headersSent && out !== undefined) json(res, 200, out);
      } catch (e) {
        if (!res.headersSent) json(res, e.status || 500, { error: e.status ? e.message : "Internal error", ...(e.body || {}) });
        if (!e.status) console.error(req.method, pathname, e);
      }
      return;
    }
    json(res, 404, { error: "Not found" });
  }

  const server = http.createServer((req, res) => { handle(req, res).catch((e) => { console.error(e); if (!res.headersSent) json(res, 500, { error: "Internal error" }); }); });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url, "http://localhost");
    const pathname = url.pathname.replace(/^\/control(?=\/)/, "");
    const m = pathname.match(/^\/api\/vnc\/(\d{1,4})\/ws$/);
    const device = auth.authenticate(req, { allowCookie: true });
    if (pathname === "/api/terminal/ws" && device) {
      return wss.handleUpgrade(req, socket, head, (ws) => terminal.attach(ws, { session: url.searchParams.get("session"), project: url.searchParams.get("project"), dir: url.searchParams.get("dir"), cols: url.searchParams.get("cols"), rows: url.searchParams.get("rows"), device }));
    }
    if (!m || !device) { socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"); return socket.destroy(); }
    wss.handleUpgrade(req, socket, head, (ws) => {
      vnc.bridge(ws, { display: m[1], mode: url.searchParams.get("mode") === "control" ? "control" : "observe", device })
        .catch((e) => { try { ws.close(1011, String(e.message).slice(0, 100)); } catch {} });
    });
  });

  let ghTimer, sysTimer, pruneTimer;
  async function start() {
    await new Promise((r) => server.listen(cfg.port, cfg.host, r));
    await agents.start();
    if (relay) { ensureRelayPushDevice(); relay.start(); }
    const repos = () => [...new Set([...projects.all().values()].map((p) => p.github).filter(Boolean))];
    ghTimer = setInterval(() => github.watch(repos()).catch(() => {}), 60_000);
    github.watch(repos()).catch(() => {});
    sysTimer = setInterval(() => system.snapshot().catch(() => {}), 60_000);
    pruneTimer = setInterval(() => db.prune(), 3600_000);
    return server.address();
  }
  async function stop() {
    clearInterval(ghTimer); clearInterval(sysTimer); clearInterval(pruneTimer);
    relay?.stop(); terminal.closeAll();
    agents.stop(); push.close(); watcher.close(); builds.close(); vnc.closeAll();
    await new Promise((r) => server.close(r));
    server.closeAllConnections?.();
    db.close();
  }
  return { cfg, server, start, stop, db, auth, events, projects, agents, watcher, screenshots, files, push, providers, relay, terminal };
}
