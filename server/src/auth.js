// Device pairing and request authentication.
//
// The iPad pairs once with the existing workspace password (checked against
// the dashboard's bcrypt hash, never stored) and receives a random device
// token. Only the token's SHA-256 is kept server-side; the app keeps the token
// in the iOS Keychain. Tokens expire and can be revoked from the app or CLI.
// Web views (noVNC) can't send headers, so a token can be exchanged for a
// short-lived HttpOnly cookie scoped to the gateway's path.
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

export function createAuth(cfg, db) {
  const failures = new Map();
  const webSessions = new Map(); // cookie value → {device, expires}
  const insert = db.raw.prepare("INSERT INTO devices(id,name,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)");
  const byHash = db.raw.prepare("SELECT * FROM devices WHERE token_hash=? AND revoked=0");
  const touch = db.raw.prepare("UPDATE devices SET last_seen=? WHERE id=?");
  let lastTouch = new Map();

  function blocked(ip) { const f = failures.get(ip); return Boolean(f && f.until > Date.now() && f.count >= 5); }
  function fail(ip) { const now = Date.now(), f = failures.get(ip); failures.set(ip, { count: f && f.until > now ? f.count + 1 : 1, until: now + 15 * 60 * 1000 }); }

  async function pair({ password, deviceName }, ip) {
    if (blocked(ip)) return { status: 429, error: "Too many attempts. Wait 15 minutes and try again." };
    const hash = fs.readFileSync(cfg.passwordHashFile, "utf8").trim();
    if (!/^\$2[aby]\$/.test(hash)) return { status: 500, error: "Workspace password hash is not bcrypt." };
    if (!password || !(await bcrypt.compare(String(password), hash))) {
      fail(ip);
      console.warn("pairing rejected: credential mismatch", { client: ip });
      return { status: 401, error: "That password was not accepted." };
    }
    failures.delete(ip);
    const token = "mc_" + crypto.randomBytes(32).toString("base64url");
    const id = crypto.randomUUID();
    const now = Date.now();
    const name = String(deviceName || "iPad").slice(0, 80);
    insert.run(id, name, sha(token), now, now + cfg.deviceTokenDays * 86400_000);
    console.info("device paired", { id, name, client: ip });
    return { status: 200, body: { token, deviceId: id, expiresAt: now + cfg.deviceTokenDays * 86400_000 } };
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

  function issueWebCookie(device) {
    for (const [k, s] of webSessions) if (s.expires < Date.now()) webSessions.delete(k);
    const value = crypto.randomBytes(32).toString("base64url");
    webSessions.set(value, { device, expires: Date.now() + WEB_TTL });
    return { name: WEB_COOKIE, value, maxAge: WEB_TTL / 1000,
      header: `${WEB_COOKIE}=${value}; Path=/control; Max-Age=${WEB_TTL / 1000}; HttpOnly; Secure; SameSite=Lax` };
  }

  function listDevices() {
    return db.raw.prepare("SELECT id,name,created_at,last_seen,expires_at,revoked FROM devices ORDER BY created_at DESC").all();
  }
  function revoke(id) {
    db.raw.prepare("UPDATE devices SET revoked=1 WHERE id=?").run(id);
    for (const [k, s] of webSessions) if (s.device.id === id) webSessions.delete(k);
  }
  return { pair, authenticate, issueWebCookie, listDevices, revoke, _hash: sha };
}
