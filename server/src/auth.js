// Device pairing and request authentication.
//
// The iPad pairs once with the existing workspace password (checked against
// the dashboard's bcrypt hash, never stored) and receives a random device
// token. Only the token's SHA-256 is kept server-side; the app keeps the token
// in the iOS Keychain. Tokens expire and can be revoked from the app or CLI.
// Web views (noVNC) can't send headers, so a token can be exchanged for a
// short-lived HttpOnly cookie scoped to the gateway's path.
//
// Companion profile (someone's own machine): there is no workspace password.
// A device token comes from
//   * the local CLI (`musa-companion token`), which the app runs over its own
//     SSH connection: being able to log in as this OS user is the proof;
//   * a one-time pairing code printed by `musa-companion pair` (10 minutes,
//     single use, rate-limited), for machines on the same network; or
//   * the relay: requests forwarded by this process's own relay link carry an
//     in-memory secret plus the Musa Control account id, and are accepted only
//     when that account is the one the machine was linked to.
import crypto from "node:crypto";
import fs from "node:fs";
import bcrypt from "bcryptjs";

const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
const WEB_COOKIE = "mc_web";
const WEB_TTL = 8 * 60 * 60 * 1000;

export function clientAddress(req) {
  // The gateway only listens on loopback behind Caddy, which appends the real
  // client address as the last X-Forwarded-For entry.
  const xff = String(req.headers["x-forwarded-for"] || "").split(",").map((s) => s.trim()).filter(Boolean);
  return xff.length ? xff[xff.length - 1] : req.socket.remoteAddress || "unknown";
}

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export function newPairCode() {
  const b = crypto.randomBytes(8);
  return [...b].map((x) => CODE_ALPHABET[x % CODE_ALPHABET.length]).join("").replace(/^(.{4})/, "$1-");
}
const normCode = (c) => String(c || "").toUpperCase().replace(/[^A-Z0-9]/g, "");

export function createAuth(cfg, db) {
  // Shared only with this process's relay link (relay-link.js).
  const relaySecret = crypto.randomBytes(32).toString("base64url");
  const failures = new Map();
  const webSessions = new Map(); // cookie value → {device, expires}
  const insert = db.raw.prepare("INSERT INTO devices(id,name,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)");
  const byHash = db.raw.prepare("SELECT * FROM devices WHERE token_hash=? AND revoked=0");
  const touch = db.raw.prepare("UPDATE devices SET last_seen=? WHERE id=?");
  let lastTouch = new Map();

  function blocked(ip) { const f = failures.get(ip); return Boolean(f && f.until > Date.now() && f.count >= 5); }
  function fail(ip) { const now = Date.now(), f = failures.get(ip); failures.set(ip, { count: f && f.until > now ? f.count + 1 : 1, until: now + 15 * 60 * 1000 }); }

  function issue(deviceName, via) {
    const token = "mc_" + crypto.randomBytes(32).toString("base64url");
    const id = crypto.randomUUID();
    const now = Date.now();
    const name = String(deviceName || "iPad").slice(0, 80);
    insert.run(id, name, sha(token), now, now + cfg.deviceTokenDays * 86400_000);
    console.info("device paired", { id, name, via });
    return { token, deviceId: id, expiresAt: now + cfg.deviceTokenDays * 86400_000 };
  }

  function createPairCode(ttlMs = 10 * 60_000) {
    const code = newPairCode();
    const codes = (db.get("pair-codes", []) || []).filter((c) => c.expires > Date.now());
    codes.push({ hash: sha(normCode(code)), expires: Date.now() + ttlMs });
    db.set("pair-codes", codes.slice(-5));
    return { code, expiresAt: Date.now() + ttlMs };
  }

  function useCode(code) {
    const h = sha(normCode(code));
    const codes = (db.get("pair-codes", []) || []).filter((c) => c.expires > Date.now());
    const hit = codes.find((c) => crypto.timingSafeEqual(Buffer.from(c.hash), Buffer.from(h)));
    db.set("pair-codes", codes.filter((c) => c !== hit));
    return Boolean(hit);
  }

  async function pair({ password, code, deviceName }, ip) {
    if (blocked(ip)) return { status: 429, error: "Too many attempts. Wait 15 minutes and try again." };
    if (code !== undefined) {
      if (!useCode(code)) { fail(ip); return { status: 401, error: "That pairing code isn't valid or has expired." }; }
      failures.delete(ip);
      return { status: 200, body: issue(deviceName, "code") };
    }
    if (!cfg.passwordHashFile) return { status: 400, error: "This machine pairs with a code: run `musa-companion pair` on it." };
    const hash = fs.readFileSync(cfg.passwordHashFile, "utf8").trim();
    if (!/^\$2[aby]\$/.test(hash)) return { status: 500, error: "Workspace password hash is not bcrypt." };
    if (!password || !(await bcrypt.compare(String(password), hash))) {
      fail(ip);
      console.warn("pairing rejected: credential mismatch", { client: ip });
      return { status: 401, error: "That password was not accepted." };
    }
    failures.delete(ip);
    return { status: 200, body: issue(deviceName, "password") };
  }

  // A request forwarded by our own relay link for the linked account.
  function relayDevice(req) {
    const given = String(req.headers["x-mc-relay"] || "");
    if (!given || !cfg.relay?.owner) return null;
    const a = Buffer.from(given), b = Buffer.from(relaySecret);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    if (String(req.headers["x-mc-user"] || "") !== cfg.relay.owner) return null;
    const sess = String(req.headers["x-mc-session"] || "").replace(/[^\w-]/g, "").slice(0, 64) || "unknown";
    return { id: `relay:${sess}`, name: String(req.headers["x-mc-device-name"] || "Linked device").slice(0, 80), relay: true, expires_at: Date.now() + 3600_000, base: String(req.headers["x-mc-base"] || "") };
  }

  function cookieValue(req) {
    const header = String(req.headers.cookie || "");
    for (const part of header.split(";")) {
      const [k, ...v] = part.trim().split("=");
      if (k === WEB_COOKIE) return v.join("=");
    }
    return null;
  }

  // Returns the device row for a request, or null.
  function authenticate(req, { allowCookie = false } = {}) {
    const viaRelay = relayDevice(req);
    if (viaRelay) return viaRelay;
    if (req.headers["x-mc-relay"]) return null; // a forged or stale relay header never falls through
    const h = String(req.headers.authorization || "");
    let token = h.startsWith("Bearer ") ? h.slice(7).trim() : null;
    if (!token && allowCookie) {
      const c = cookieValue(req);
      const s = c && webSessions.get(c);
      if (s && s.expires > Date.now()) return s.device;
      return null;
    }
    if (!token) return null;
    const row = byHash.get(sha(token));
    if (!row || row.expires_at < Date.now()) return null;
    const now = Date.now();
    if (now - (lastTouch.get(row.id) || 0) > 60_000) { touch.run(now, row.id); lastTouch.set(row.id, now); }
    return row;
  }

  function issueWebCookie(device, { path: cookiePath = "/control", secure = true } = {}) {
    for (const [k, s] of webSessions) if (s.expires < Date.now()) webSessions.delete(k);
    const value = crypto.randomBytes(32).toString("base64url");
    webSessions.set(value, { device, expires: Date.now() + WEB_TTL });
    return { name: WEB_COOKIE, value, maxAge: WEB_TTL / 1000,
      path: cookiePath, header: `${WEB_COOKIE}=${value}; Path=${cookiePath}; Max-Age=${WEB_TTL / 1000}; HttpOnly;${secure ? " Secure;" : ""} SameSite=Lax` };
  }

  function listDevices() {
    return db.raw.prepare("SELECT id,name,created_at,last_seen,expires_at,revoked FROM devices ORDER BY created_at DESC").all();
  }
  function revoke(id) {
    db.raw.prepare("UPDATE devices SET revoked=1 WHERE id=?").run(id);
    for (const [k, s] of webSessions) if (s.device.id === id) webSessions.delete(k);
  }
  return { pair, issue, createPairCode, authenticate, issueWebCookie, listDevices, revoke, relaySecret, _hash: sha };
}
