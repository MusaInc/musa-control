// Machines linked to an account, and the relay that carries the owner's
// requests to them.
//
// Linking: the signed-in app asks for a short code; the user (or the app's
// SSH setup) runs `musa-companion link <code>` on the machine; the companion
// trades the code for a machine id and a long random machine secret (only its
// hash is stored here). The machine then holds one outbound WebSocket here.
//
// Authorization: every relayed request and socket is checked against the
// session's user id and the machine's owner in this file. A machine that
// belongs to someone else is indistinguishable from one that doesn't exist.
import crypto from "node:crypto";
import { WebSocketServer } from "ws";
import { err } from "./accounts.js";

const sha = (s) => crypto.createHash("sha256").update(String(s)).digest("hex");
export const FRAME = { BODY: 1, WS_BIN: 2, WS_TEXT: 3 };
export function frame(kind, id, payload) {
  const head = Buffer.alloc(5); head.writeUInt8(kind, 0); head.writeUInt32BE(id >>> 0, 1);
  return Buffer.concat([head, Buffer.isBuffer(payload) ? payload : Buffer.from(payload)]);
}
const unframe = (b) => ({ kind: b.readUInt8(0), id: b.readUInt32BE(1), payload: b.subarray(5) });

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const newCode = () => [...crypto.randomBytes(8)].map((x) => CODE_ALPHABET[x % CODE_ALPHABET.length]).join("").replace(/^(.{4})/, "$1-");
const normCode = (c) => String(c || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
// Request headers never forwarded to a machine (credentials for *this*
// service, hop-by-hop, and anything that could impersonate the relay).
const DROP_REQ = new Set(["authorization", "cookie", "host", "connection", "keep-alive", "upgrade", "proxy-connection", "te", "trailer", "transfer-encoding", "content-length",
  "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-real-ip", "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-protocol"]);
const DROP_RES = new Set(["connection", "keep-alive", "transfer-encoding", "content-length", "set-cookie"]);
const cleanReq = (h) => Object.fromEntries(Object.entries(h).filter(([k]) => !DROP_REQ.has(k) && !k.startsWith("x-mc-")));
const cleanRes = (h) => Object.fromEntries(Object.entries(h || {}).filter(([k]) => !DROP_RES.has(k.toLowerCase())));

export function createMachines(cfg, db, accounts, push) {
  const online = new Map();  // machineId → conn {ws, machine, streams, next}
  const appSockets = new Map(); // sessionId → Set<ws> (closed when the session is revoked)
  const limiter = accounts.limiter;
  const wssMachine = new WebSocketServer({ noServer: true, maxPayload: 32 * 1024 * 1024 });
  const wssApp = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024, handleProtocols: (p) => (p.has("binary") ? "binary" : [...p][0] || false) });

  const view = (m) => ({ id: m.id, name: m.name, platform: m.platform, hostname: m.hostname, osUser: m.os_user, createdAt: m.created_at, lastSeen: online.has(m.id) ? Date.now() : m.last_seen,
    online: online.has(m.id), info: m.info ? JSON.parse(m.info) : null });

  function owned(auth, id) {
    const m = db.get("SELECT * FROM machines WHERE id=? AND user_id=? AND revoked_at IS NULL", String(id), auth.userId);
    if (!m) throw err(404, "No such machine.");
    return m;
  }

  function list(auth) { return db.all("SELECT * FROM machines WHERE user_id=? AND revoked_at IS NULL ORDER BY created_at", auth.userId).map(view); }

  function linkCode(auth, { name } = {}, ip) {
    const count = db.get("SELECT COUNT(*) n FROM machines WHERE user_id=? AND revoked_at IS NULL", auth.userId).n;
    if (count >= cfg.limits.machinesPerUser) throw err(409, `You can link up to ${cfg.limits.machinesPerUser} machines.`);
    if (!limiter.hit(`linkcode:${auth.userId}`, 30, 3600_000)) throw err(429, "Too many link codes. Try again later.");
    const code = newCode();
    const ttl = 15 * 60_000;
    db.run("DELETE FROM link_codes WHERE user_id=? AND (used_at IS NOT NULL OR expires_at < ?)", auth.userId, Date.now());
    db.run("INSERT INTO link_codes(code_hash,user_id,name,created_at,expires_at) VALUES(?,?,?,?,?)", sha(normCode(code)), auth.userId, name ? String(name).slice(0, 80) : null, Date.now(), Date.now() + ttl);
    accounts.audit("machine.code_created", { user: auth.userId, ip, session: auth.sessionId });
    return { code, expiresAt: Date.now() + ttl, command: `musa-companion link ${code} --relay ${cfg.publicUrl}` };
  }

  function claim({ code, name, platform, hostname, user }, ip) {
    accounts.authGate(ip);
    const row = db.get("SELECT * FROM link_codes WHERE code_hash=?", sha(normCode(code)));
    if (!row || row.used_at || row.expires_at < Date.now()) { accounts.authFail(ip); throw err(401, "That link code isn't valid or has expired. Create a new one in the app."); }
    const used = db.run("UPDATE link_codes SET used_at=? WHERE code_hash=? AND used_at IS NULL", Date.now(), row.code_hash);
    if (!used.changes) throw err(401, "That link code was already used.");
    const id = crypto.randomUUID();
    const secret = "mcm_" + crypto.randomBytes(32).toString("base64url");
    db.run("INSERT INTO machines(id,user_id,name,platform,hostname,os_user,secret_hash,created_at) VALUES(?,?,?,?,?,?,?,?)",
      id, row.user_id, String(row.name || name || hostname || "My computer").slice(0, 80), String(platform || "").slice(0, 20), String(hostname || "").slice(0, 120), String(user || "").slice(0, 64), sha(secret), Date.now());
    db.run("UPDATE link_codes SET machine_id=? WHERE code_hash=?", id, row.code_hash);
    accounts.audit("machine.linked", { user: row.user_id, ip, machine: id, detail: { platform, hostname } });
    return { machineId: id, machineSecret: secret, owner: row.user_id };
  }

  function rename(auth, id, name, ip) {
    owned(auth, id);
    const n = String(name || "").trim().slice(0, 80);
    if (!n) throw err(400, "Give the machine a name.");
    db.run("UPDATE machines SET name=? WHERE id=?", n, id);
    accounts.audit("machine.renamed", { user: auth.userId, ip, machine: id, session: auth.sessionId });
    return view(db.get("SELECT * FROM machines WHERE id=?", id));
  }

  function remove(auth, id, ip) {
    owned(auth, id);
    db.run("UPDATE machines SET revoked_at=?, secret_hash=? WHERE id=?", Date.now(), "revoked:" + crypto.randomUUID(), id);
    disconnect(id, "unlinked");
    accounts.audit("machine.removed", { user: auth.userId, ip, machine: id, session: auth.sessionId });
    return { ok: true };
  }

  function disconnect(id, why = "unlinked") {
    const c = online.get(id);
    if (!c) return;
    try { c.ws.send(JSON.stringify({ t: why })); } catch {}
    c.ws.close(4001, why);
    online.delete(id);
  }

  function machineFromSecret(secret) {
    if (!String(secret || "").startsWith("mcm_")) return null;
    return db.get("SELECT * FROM machines WHERE secret_hash=? AND revoked_at IS NULL", sha(secret)) || null;
  }

  function unlinkSelf(secret, ip) {
    const m = machineFromSecret(secret);
    if (!m) throw err(401, "Unknown machine.");
    db.run("UPDATE machines SET revoked_at=?, secret_hash=? WHERE id=?", Date.now(), "revoked:" + crypto.randomUUID(), m.id);
    disconnect(m.id);
    accounts.audit("machine.unlinked_by_machine", { user: m.user_id, ip, machine: m.id });
    return { ok: true };
  }

  // ---------- machine side ----------
  function machineUpgrade(req, socket, head, ip) {
    const m = machineFromSecret(String(req.headers.authorization || "").replace(/^Bearer\s+/i, ""));
    if (!m) { accounts.authFail(ip); socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"); return socket.destroy(); }
    wssMachine.handleUpgrade(req, socket, head, (ws) => {
      online.get(m.id)?.ws.close(4000, "replaced by a newer connection");
      const conn = { ws, machine: m, streams: new Map(), next: 1, pushes: 0, pushWindow: Date.now() };
      online.set(m.id, conn);
      db.run("UPDATE machines SET last_seen=? WHERE id=?", Date.now(), m.id);
      accounts.audit("machine.online", { user: m.user_id, ip, machine: m.id });
      let alive = true;
      const ping = setInterval(() => { if (!alive) return ws.terminate(); alive = false; try { ws.ping(); } catch {} }, 25_000);
      ws.on("pong", () => { alive = true; });
      ws.on("message", (data, isBinary) => { try { isBinary ? fromMachineBinary(conn, data) : fromMachineControl(conn, JSON.parse(String(data))); } catch (e) { console.warn("relay frame", e.message); } });
      ws.on("close", () => {
        clearInterval(ping);
        if (online.get(m.id) === conn) online.delete(m.id);
        if (!closing) db.run("UPDATE machines SET last_seen=? WHERE id=?", Date.now(), m.id);
        for (const s of conn.streams.values()) s.fail?.("The machine disconnected.");
        conn.streams.clear();
      });
    });
  }

  function fromMachineControl(conn, msg) {
    if (msg.t === "hello") { db.run("UPDATE machines SET info=? WHERE id=?", JSON.stringify(sanitizeInfo(msg.info)), conn.machine.id); return; }
    if (msg.t === "push") return machinePush(conn, msg.message);
    const s = conn.streams.get(msg.id);
    if (!s) return;
    if (msg.t === "res") s.onRes?.(msg);
    else if (msg.t === "end") { s.onEnd?.(); conn.streams.delete(msg.id); }
    else if (msg.t === "err") { s.fail?.(msg.message || "Machine error"); conn.streams.delete(msg.id); }
    else if (msg.t === "ws-ok") s.onOpen?.(msg);
    else if (msg.t === "ws-fail") { s.fail?.(`Refused (${msg.status})`); conn.streams.delete(msg.id); }
    else if (msg.t === "ws-close") { s.onClose?.(msg.code); conn.streams.delete(msg.id); }
  }

  function fromMachineBinary(conn, buf) {
    const { kind, id, payload } = unframe(buf);
    const s = conn.streams.get(id);
    if (s) s.onData?.(kind, payload);
  }

  const sanitizeInfo = (i = {}) => ({ name: String(i.name || "").slice(0, 80), platform: String(i.platform || "").slice(0, 20), os: String(i.os || "").slice(0, 80),
    version: String(i.version || "").slice(0, 20), profile: String(i.profile || "").slice(0, 20), agents: Array.isArray(i.agents) ? i.agents.slice(0, 8).map((a) => String(a).slice(0, 20)) : [] });

  function machinePush(conn, message) {
    const now = Date.now();
    if (now - conn.pushWindow > 3600_000) { conn.pushWindow = now; conn.pushes = 0; }
    if (++conn.pushes > cfg.limits.pushesPerMachinePerHour) return;
    push.fanOut(conn.machine, message).catch((e) => console.warn("push fan-out", e.message));
  }

  // ---------- app side ----------
  function connFor(auth, id) {
    const m = owned(auth, id);
    const c = online.get(m.id);
    if (!c) throw err(503, `${m.name} is offline. Check that the Musa Control companion is running on it.`);
    if (c.streams.size >= cfg.limits.streamsPerMachine) throw err(429, "Too many requests in flight to this machine.");
    return c;
  }

  function relayContext(auth, m) {
    return { user: m.user_id, session: auth.sessionId, device: auth.deviceName, base: `${cfg.publicUrl}/m/${m.id}` };
  }

  // Streams one HTTP request to the machine and its response back.
  function relayHttp(auth, machineId, rest, req, res) {
    const c = connFor(auth, machineId);
    const id = c.next++ >>> 0;
    const pathQs = "/" + rest;
    let answered = false;
    const timer = setTimeout(() => { if (!answered) s.fail("The machine didn't answer in time."); }, 60_000);
    const s = {
      onRes(m) { answered = true; clearTimeout(timer); res.writeHead(m.status, { ...cleanRes(m.headers), "X-Content-Type-Options": "nosniff" }); },
      onData(kind, payload) { if (kind === FRAME.BODY && !res.writableEnded) { if (!res.headersSent) res.writeHead(200); res.write(payload); } },
      onEnd() { clearTimeout(timer); if (!res.headersSent) res.writeHead(204); res.end(); },
      fail(msg) { clearTimeout(timer); c.streams.delete(id); if (!res.headersSent) { res.writeHead(502, { "Content-Type": "application/json" }); res.end(JSON.stringify({ error: msg })); } else res.destroy(); },
    };
    c.streams.set(id, s);
    if (["POST", "PUT", "PATCH", "DELETE"].includes(req.method)) {
      accounts.audit("relay.action", { user: auth.userId, session: auth.sessionId, machine: c.machine.id, detail: { method: req.method, path: pathQs.split("?")[0].slice(0, 200) } });
    }
    c.ws.send(JSON.stringify({ t: "req", id, method: req.method, path: pathQs, headers: cleanReq(req.headers), ...relayContext(auth, c.machine) }));
    let sent = 0;
    req.on("data", (chunk) => {
      sent += chunk.length;
      if (sent > cfg.limits.relayBodyBytes) { s.fail("Upload too large."); req.destroy(); return; }
      c.ws.send(frame(FRAME.BODY, id, chunk));
      if (c.ws.bufferedAmount > 8 * 1024 * 1024) { req.pause(); const t = setInterval(() => { if (c.ws.readyState !== 1 || c.ws.bufferedAmount < 2 * 1024 * 1024) { clearInterval(t); req.resume(); } }, 30); }
    });
    req.on("end", () => { try { c.ws.send(JSON.stringify({ t: "end", id })); } catch {} });
    res.on("close", () => { clearTimeout(timer); if (c.streams.has(id)) { c.streams.delete(id); try { c.ws.send(JSON.stringify({ t: "cancel", id })); } catch {} } });
  }

  function relaySocket(auth, machineId, rest, req, socket, head) {
    let c;
    try { c = connFor(auth, machineId); } catch (e) { socket.write(`HTTP/1.1 ${e.status || 500} Error\r\nConnection: close\r\n\r\n`); return socket.destroy(); }
    const id = c.next++ >>> 0;
    const protocols = String(req.headers["sec-websocket-protocol"] || "").split(",").map((s) => s.trim()).filter(Boolean);
    let app = null; const queue = [];
    const s = {
      onOpen() {
        wssApp.handleUpgrade(req, socket, head, (ws) => {
          app = ws;
          track(auth.sessionId, ws);
          for (const q of queue) ws.send(q.data, { binary: q.binary });
          ws.on("message", (d, isBinary) => c.ws.send(frame(isBinary ? FRAME.WS_BIN : FRAME.WS_TEXT, id, Buffer.isBuffer(d) ? d : Buffer.from(d))));
          ws.on("close", (code) => { if (c.streams.has(id)) { c.streams.delete(id); try { c.ws.send(JSON.stringify({ t: "ws-close", id, code })); } catch {} } });
        });
      },
      onData(kind, payload) { const msg = { data: kind === FRAME.WS_TEXT ? payload.toString("utf8") : payload, binary: kind === FRAME.WS_BIN }; app ? app.send(msg.data, { binary: msg.binary }) : queue.push(msg); },
      onClose(code) { try { app?.close(code >= 1000 && code < 5000 && code !== 1005 && code !== 1006 ? code : 1000); } catch {} if (!app) socket.destroy(); },
      fail(msg) { if (app) app.close(1011, String(msg).slice(0, 100)); else { socket.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"); socket.destroy(); } },
    };
    c.streams.set(id, s);
    c.ws.send(JSON.stringify({ t: "ws", id, path: "/" + rest, headers: cleanReq(req.headers), protocols, ...relayContext(auth, c.machine) }));
  }

  function track(sessionId, ws) {
    let set = appSockets.get(sessionId);
    if (!set) appSockets.set(sessionId, (set = new Set()));
    set.add(ws); ws.on("close", () => set.delete(ws));
  }
  function dropSession(sessionId) { for (const ws of appSockets.get(sessionId) || []) ws.close(4401, "Signed out"); appSockets.delete(sessionId); }

  let closing = false;
  function closeAll() {
    closing = true;
    for (const c of online.values()) c.ws.close(1001, "server shutting down"); online.clear(); }

  return { list, linkCode, claim, rename, remove, unlinkSelf, disconnect, machineUpgrade, relayHttp, relaySocket, dropSession, owned, closeAll, isOnline: (id) => online.has(id), _online: online };
}
