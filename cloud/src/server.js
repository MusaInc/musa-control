// Musa Control Cloud HTTP API.
//
//   /v1/*        accounts, sessions, machines, push (JSON; Bearer session token)
//   /m/<id>/*    the owner's requests relayed to machine <id> (same token, or
//                the short-lived web cookie for pages inside web views)
//   /v1/relay/connect   companions' outbound WebSocket (machine secret)
//
// No endpoint exposes another user's data or any administrator function;
// administration is the local CLI only (src/cli.js).
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import { loadConfig } from "./config.js";
import { openDb } from "./db.js";
import { createAccounts, err } from "./accounts.js";
import { createMachines } from "./machines.js";
import { createPush } from "./push.js";

export const VERSION = "0.1.0";
const WEB_COOKIE = "mc_rw";
const WEB_TTL = 8 * 3600_000;

function json(res, status, body, headers = {}) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers });
  res.end(JSON.stringify(body));
}
async function readJson(req, limit = 64 * 1024) {
  const chunks = []; let n = 0;
  for await (const c of req) { n += c.length; if (n > limit) throw err(413, "Request too large"); chunks.push(c); }
  if (!n) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw err(400, "Invalid JSON"); }
}
const SECURITY = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Strict-Transport-Security": "max-age=31536000", "X-Frame-Options": "DENY" };

export function createServer(overrides = {}) {
  const cfg = loadConfig(overrides);
  const db = openDb(cfg);
  const accounts = createAccounts(cfg, db, { fetchImpl: overrides.fetchImpl || fetch });
  const push = createPush(cfg, db, { transport: overrides.apnsTransport });
  const machines = createMachines(cfg, db, accounts, push);
  const webSessions = new Map(); // cookie → {auth, machineId, expires}

  const ipOf = (req) => {
    if (cfg.trustProxy) { const x = String(req.headers["x-forwarded-for"] || "").split(",").map((s) => s.trim()).filter(Boolean); if (x.length) return x[x.length - 1]; }
    return req.socket.remoteAddress || "unknown";
  };
  const bearer = (req) => String(req.headers.authorization || "").replace(/^Bearer\s+/i, "").trim() || null;
  function cookieAuth(req, machineId) {
    const v = String(req.headers.cookie || "").split(";").map((s) => s.trim()).find((s) => s.startsWith(WEB_COOKIE + "="))?.slice(WEB_COOKIE.length + 1);
    const w = v && webSessions.get(v);
    if (!w || w.expires < Date.now() || w.machineId !== machineId) return null;
    // Re-check the session itself: revoking it kills its cookies too.
    return accounts.authenticate(w.token, ipOf(req));
  }

  const routes = [];
  const route = (method, pattern, handler, opts = {}) => {
    const keys = [];
    const re = new RegExp("^" + pattern.replace(/:(\w+)/g, (_, k) => { keys.push(k); return "([^/]+)"; }) + "$");
    routes.push({ method, re, keys, handler, opts });
  };

  // ---------- public ----------
  route("GET", "/v1/ping", () => ({ ok: true, service: "musa-control-cloud", version: VERSION, registration: cfg.registration, apple: true, password: true }), { public: true });
  route("POST", "/v1/auth/register", ({ body, ip }) => accounts.register(body, ip), { public: true });
  route("POST", "/v1/auth/login", ({ body, ip }) => accounts.login(body, ip), { public: true });
  route("POST", "/v1/auth/apple", ({ body, ip }) => accounts.appleSignIn(body, ip), { public: true });
  route("POST", "/v1/machines/claim", ({ body, ip }) => machines.claim(body, ip), { public: true });
  route("DELETE", "/v1/relay/self", ({ req, ip }) => machines.unlinkSelf(bearer(req), ip), { public: true });

  // ---------- account ----------
  route("GET", "/v1/me", ({ auth }) => accounts.me(auth));
  route("PATCH", "/v1/me", ({ auth, body }) => accounts.rename(auth, body.name));
  route("POST", "/v1/auth/logout", ({ auth, ip }) => { const r = accounts.revokeSession(auth, auth.sessionId, ip); machines.dropSession(auth.sessionId); return r; });
  route("POST", "/v1/auth/password", ({ auth, body, ip }) => { const r = accounts.changePassword(auth, body, ip); r.revoked.forEach(machines.dropSession); return { ok: true }; });
  route("GET", "/v1/sessions", ({ auth }) => accounts.sessions(auth));
  route("DELETE", "/v1/sessions/:id", ({ auth, params, ip }) => { const r = accounts.revokeSession(auth, params.id, ip); machines.dropSession(params.id); return r; });
  route("POST", "/v1/sessions/revoke-others", ({ auth, ip }) => { const r = accounts.revokeOthers(auth, ip); r.revoked.forEach(machines.dropSession); return { ok: true, count: r.revoked.length }; });
  route("GET", "/v1/audit", ({ auth, q }) => accounts.auditLog(auth, q.get("limit")));
  route("GET", "/v1/account/export", ({ auth }) => accounts.exportData(auth));
  route("DELETE", "/v1/account", async ({ auth, body, ip }) => {
    const r = await accounts.deleteAccount(auth, body, ip);
    for (const id of r.machines) machines.disconnect(id, "unlinked");
    machines.dropSession(auth.sessionId);
    return { ok: true, appleRevoked: r.appleRevoked };
  });

  // ---------- machines ----------
  route("GET", "/v1/machines", ({ auth }) => machines.list(auth));
  route("POST", "/v1/machines/link-code", ({ auth, body, ip }) => machines.linkCode(auth, body, ip));
  route("PATCH", "/v1/machines/:id", ({ auth, params, body, ip }) => machines.rename(auth, params.id, body.name, ip));
  route("DELETE", "/v1/machines/:id", ({ auth, params, ip }) => machines.remove(auth, params.id, ip));

  // ---------- push ----------
  route("GET", "/v1/push", ({ auth }) => push.status(auth));
  route("POST", "/v1/push/register", ({ auth, body }) => push.register(auth, body));
  route("DELETE", "/v1/push/register", ({ auth }) => push.unregister(auth));
  route("PUT", "/v1/push/prefs", ({ auth, body }) => push.setPrefs(auth, body));
  route("POST", "/v1/push/test", ({ auth }) => push.test(auth));

  async function handle(req, res) {
    const url = new URL(req.url, "http://x");
    const ip = ipOf(req);
    for (const [k, v] of Object.entries(SECURITY)) res.setHeader(k, v);
    if (!accounts.limiter.hit(`req:${ip}`, cfg.limits.requestsPerMinutePerIp, 60_000)) return json(res, 429, { error: "Slow down." }, { "Retry-After": "60" });

    // The companion for one-line installs (built by tools/pack_companion.sh).
    if (req.method === "GET" && url.pathname.startsWith("/companion/")) {
      const name = url.pathname.slice("/companion/".length);
      if (name === "install.sh") {
        const text = fs.readFileSync(new URL("../static/install.sh", import.meta.url), "utf8").replace("__BASE__", cfg.publicUrl);
        res.writeHead(200, { "Content-Type": "text/x-shellscript; charset=utf-8", "Cache-Control": "no-cache" }); return res.end(text);
      }
      const bundle = cfg.companionBundle && fs.existsSync(cfg.companionBundle) ? cfg.companionBundle : null;
      if (bundle && name === "musa-companion.tgz") { res.writeHead(200, { "Content-Type": "application/gzip", "Content-Length": fs.statSync(bundle).size }); return fs.createReadStream(bundle).pipe(res); }
      if (bundle && name === "musa-companion.tgz.sha256") { res.writeHead(200, { "Content-Type": "text/plain" }); return res.end(crypto.createHash("sha256").update(fs.readFileSync(bundle)).digest("hex") + "  musa-companion.tgz\n"); }
      return json(res, 404, { error: "Not found" });
    }

    // Relay: /m/<machine>/<rest>
    const rm = url.pathname.match(/^\/m\/([0-9a-f-]{36})\/(.*)$/);
    if (rm) {
      const [, machineId, rest] = rm;
      // Web views: a session-scoped cookie for this machine's pages.
      if (rest === "api/web-session" && req.method === "POST") {
        const auth = accounts.authenticate(bearer(req), ip);
        if (!auth) return json(res, 401, { error: "Sign in to Musa Control again." });
        try { machines.owned(auth, machineId); } catch (e) { return json(res, e.status, { error: e.message }); }
        for (const [k, w] of webSessions) if (w.expires < Date.now()) webSessions.delete(k);
        const value = crypto.randomBytes(32).toString("base64url");
        webSessions.set(value, { token: bearer(req), machineId, expires: Date.now() + WEB_TTL });
        const p = `/m/${machineId}`;
        return json(res, 200, { cookie: { name: WEB_COOKIE, value, path: p, maxAge: WEB_TTL / 1000, secure: cfg.publicUrl.startsWith("https") }, base: `${cfg.publicUrl}${p}` },
          { "Set-Cookie": `${WEB_COOKIE}=${value}; Path=${p}; Max-Age=${WEB_TTL / 1000}; HttpOnly;${cfg.publicUrl.startsWith("https") ? " Secure;" : ""} SameSite=Lax` });
      }
      const auth = accounts.authenticate(bearer(req), ip) || (["GET", "HEAD"].includes(req.method) ? cookieAuth(req, machineId) : null);
      if (!auth) return json(res, 401, { error: "Sign in to Musa Control again." }, { "WWW-Authenticate": "Bearer" });
      try { return machines.relayHttp(auth, machineId, rest + url.search, req, res); }
      catch (e) { return json(res, e.status || 500, { error: e.status ? e.message : "Internal error" }); }
    }

    for (const r of routes) {
      if (r.method !== req.method) continue;
      const m = r.re.exec(url.pathname);
      if (!m) continue;
      const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
      let auth = null;
      if (!r.opts.public) {
        auth = accounts.authenticate(bearer(req), ip);
        if (!auth) return json(res, 401, { error: "Sign in to Musa Control again." }, { "WWW-Authenticate": "Bearer" });
      }
      try {
        const body = ["POST", "PUT", "PATCH", "DELETE"].includes(req.method) ? await readJson(req) : {};
        const out = await r.handler({ req, res, params, q: url.searchParams, body, auth, ip });
        if (!res.headersSent) json(res, 200, out);
      } catch (e) {
        if (!res.headersSent) json(res, e.status || 500, { error: e.status ? e.message : "Internal error", ...(e.body || {}) });
        if (!e.status) console.error(req.method, url.pathname, e);
      }
      return;
    }
    json(res, 404, { error: "Not found" });
  }

  const server = http.createServer((req, res) => handle(req, res).catch((e) => { console.error(e); if (!res.headersSent) json(res, 500, { error: "Internal error" }); }));
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url, "http://x");
    const ip = ipOf(req);
    if (url.pathname === "/v1/relay/connect") return machines.machineUpgrade(req, socket, head, ip);
    const rm = url.pathname.match(/^\/m\/([0-9a-f-]{36})\/(.*)$/);
    // Cookie-authenticated sockets (noVNC in a web view) must come from our own pages.
    const origin = req.headers.origin;
    const sameOrigin = !origin || origin === new URL(cfg.publicUrl).origin;
    const auth = rm && (accounts.authenticate(bearer(req), ip) || (sameOrigin ? cookieAuth(req, rm[1]) : null));
    if (!rm || !auth) { socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"); return socket.destroy(); }
    machines.relaySocket(auth, rm[1], rm[2] + url.search, req, socket, head);
  });

  let pruneTimer;
  async function start() {
    await new Promise((r) => server.listen(cfg.port, cfg.host, r));
    pruneTimer = setInterval(() => accounts.pruneAudit(), 3600_000);
    return server.address();
  }
  async function stop() {
    clearInterval(pruneTimer);
    machines.closeAll(); push.close();
    await new Promise((r) => server.close(r));
    server.closeAllConnections?.();
    db.close();
  }
  return { cfg, server, start, stop, db, accounts, machines, push };
}
