// Accounts and sessions.
//
// * Email + password: scrypt (N=2^15, r=8, p=1, 32-byte salt), constant-time
//   compare, minimum length, failure-based rate limiting per IP.
// * Sign in with Apple: the app sends Apple's identity token and the raw
//   nonce it hashed into the request. The token's RS256 signature is checked
//   against Apple's published keys, plus issuer, audience (our bundle id),
//   expiry and nonce. The stable `sub` identifies the account.
// * Sessions: random bearer tokens ("mcs_…"). Only their SHA-256 is stored.
//   Sessions expire, can be listed and revoked one by one or all at once.
// * Every security-relevant action lands in the audit log.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const sha = (s) => crypto.createHash("sha256").update(String(s)).digest("hex");
const b64u = (b) => Buffer.from(b).toString("base64url");
export const err = (status, message, body) => Object.assign(new Error(message), { status, body });

const SCRYPT = { N: 32768, r: 8, p: 1, maxmem: 96 * 1024 * 1024 };
export function hashPassword(pw) {
  const salt = crypto.randomBytes(32);
  const dk = crypto.scryptSync(String(pw).normalize("NFKC"), salt, 32, SCRYPT);
  return `scrypt$${SCRYPT.N}$${SCRYPT.r}$${SCRYPT.p}$${salt.toString("base64")}$${dk.toString("base64")}`;
}
export function verifyPassword(pw, stored) {
  const [alg, N, r, p, salt, dk] = String(stored || "").split("$");
  if (alg !== "scrypt") return false;
  const want = Buffer.from(dk, "base64");
  const got = crypto.scryptSync(String(pw).normalize("NFKC"), Buffer.from(salt, "base64"), want.length, { N: +N, r: +r, p: +p, maxmem: SCRYPT.maxmem });
  return crypto.timingSafeEqual(want, got);
}
// Spend the same time when the account doesn't exist.
const DUMMY = hashPassword(crypto.randomBytes(16).toString("hex"));

export function normEmail(e) {
  const s = String(e || "").trim().toLowerCase();
  if (s.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s)) return null;
  return s;
}

// Fixed-window counters per key.
export function createLimiter() {
  const m = new Map();
  return {
    hit(key, max, windowMs) {
      const now = Date.now(); let e = m.get(key);
      if (!e || e.until < now) { e = { n: 0, until: now + windowMs }; m.set(key, e); }
      e.n++;
      if (m.size > 50_000) for (const [k, v] of m) if (v.until < now) m.delete(k);
      return e.n <= max;
    },
    count(key) { const e = m.get(key); return e && e.until > Date.now() ? e.n : 0; },
    clear(key) { m.delete(key); },
  };
}

// AES-256-GCM for the few secrets the cloud must keep (Apple refresh tokens,
// needed to revoke Sign in with Apple when an account is deleted).
function sealer(cfg) {
  const f = path.join(cfg.dataDir, "seal.key");
  if (!fs.existsSync(f)) fs.writeFileSync(f, crypto.randomBytes(32), { mode: 0o600 });
  const key = fs.readFileSync(f);
  return {
    seal(text) { const iv = crypto.randomBytes(12); const c = crypto.createCipheriv("aes-256-gcm", key, iv); const enc = Buffer.concat([c.update(String(text), "utf8"), c.final()]); return `v1.${b64u(iv)}.${b64u(enc)}.${b64u(c.getAuthTag())}`; },
    open(s) { const [, iv, enc, tag] = String(s).split("."); const d = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(iv, "base64url")); d.setAuthTag(Buffer.from(tag, "base64url")); return Buffer.concat([d.update(Buffer.from(enc, "base64url")), d.final()]).toString("utf8"); },
  };
}

export function createAccounts(cfg, db, { fetchImpl = fetch } = {}) {
  const limiter = createLimiter();
  const seal = sealer(cfg);
  let jwks = { at: 0, keys: [] };

  function audit(action, { user = null, ip = null, session = null, machine = null, detail = null } = {}) {
    db.run("INSERT INTO audit(ts,user_id,action,ip,session_id,machine_id,detail) VALUES(?,?,?,?,?,?,?)", Date.now(), user, action, ip, session, machine, detail ? JSON.stringify(detail).slice(0, 2000) : null);
  }

  function authGate(ip) {
    if (limiter.count(`authfail:${ip}`) >= cfg.limits.authFailuresPerIp) throw err(429, "Too many attempts. Wait 15 minutes and try again.");
  }
  const authFail = (ip) => limiter.hit(`authfail:${ip}`, Infinity, cfg.limits.authWindowMinutes * 60_000);

  function newSession(user, { deviceName, platform, ip }) {
    const token = "mcs_" + crypto.randomBytes(32).toString("base64url");
    const id = crypto.randomUUID();
    const now = Date.now();
    db.run("INSERT INTO sessions(id,user_id,token_hash,device_name,platform,created_at,last_seen,last_ip,expires_at) VALUES(?,?,?,?,?,?,?,?,?)",
      id, user.id, sha(token), String(deviceName || "Device").slice(0, 80), String(platform || "").slice(0, 40), now, now, ip, now + cfg.sessionDays * 86400_000);
    return { token, session: { id, expiresAt: now + cfg.sessionDays * 86400_000 }, user: publicUser(user) };
  }

  const publicUser = (u) => ({ id: u.id, email: u.email, emailVerified: Boolean(u.email_verified), name: u.name, createdAt: u.created_at,
    methods: [u.password_hash ? "password" : null, u.apple_sub ? "apple" : null].filter(Boolean) });

  function register({ email, password, name, deviceName, platform }, ip) {
    if (cfg.registration !== "open") throw err(403, "Sign-ups are closed right now.");
    authGate(ip);
    if (!limiter.hit(`register:${ip}`, cfg.limits.registrationsPerIpPerDay, 86400_000)) throw err(429, "Too many new accounts from this network today.");
    const e = normEmail(email);
    if (!e) throw err(400, "Enter a valid email address.");
    if (String(password || "").length < cfg.passwordMinLength) throw err(400, `Use a password of at least ${cfg.passwordMinLength} characters.`);
    if (String(password).length > 512) throw err(400, "That password is too long.");
    if (db.get("SELECT 1 FROM users WHERE email=?", e)) { authFail(ip); throw err(409, "An account with that email already exists. Sign in instead."); }
    const user = { id: crypto.randomUUID(), email: e, name: String(name || "").trim().slice(0, 80) || null, password_hash: hashPassword(password), created_at: Date.now(), email_verified: 0 };
    db.run("INSERT INTO users(id,email,name,password_hash,created_at) VALUES(?,?,?,?,?)", user.id, user.email, user.name, user.password_hash, user.created_at);
    audit("account.created", { user: user.id, ip, detail: { method: "password" } });
    const s = newSession(user, { deviceName, platform, ip });
    audit("session.created", { user: user.id, ip, session: s.session.id, detail: { method: "password", device: deviceName } });
    return s;
  }

  function login({ email, password, deviceName, platform }, ip) {
    authGate(ip);
    const e = normEmail(email);
    const u = e ? db.get("SELECT * FROM users WHERE email=?", e) : null;
    const ok = verifyPassword(String(password || ""), u?.password_hash || DUMMY) && Boolean(u?.password_hash);
    if (!ok || u.disabled) {
      authFail(ip);
      audit("login.failed", { user: u?.id || null, ip, detail: { reason: u?.disabled ? "disabled" : "credentials" } });
      throw err(401, u?.disabled ? "This account is disabled." : "That email and password didn't match.");
    }
    limiter.clear(`authfail:${ip}`);
    const s = newSession(u, { deviceName, platform, ip });
    audit("session.created", { user: u.id, ip, session: s.session.id, detail: { method: "password", device: deviceName } });
    return s;
  }

  // ---------- Sign in with Apple ----------
  async function appleKeys(force = false) {
    if (!force && jwks.keys.length && Date.now() - jwks.at < 6 * 3600_000) return jwks.keys;
    const r = await fetchImpl(cfg.apple.jwksUrl, { signal: AbortSignal.timeout(10_000) });
    if (!r.ok) throw err(502, "Couldn't reach Apple to check the sign-in.");
    jwks = { at: Date.now(), keys: (await r.json()).keys || [] };
    return jwks.keys;
  }

  async function verifyAppleToken(idToken, rawNonce) {
    const parts = String(idToken || "").split(".");
    if (parts.length !== 3) throw err(400, "Malformed Apple identity token.");
    let header, claims;
    try { header = JSON.parse(Buffer.from(parts[0], "base64url")); claims = JSON.parse(Buffer.from(parts[1], "base64url")); } catch { throw err(400, "Malformed Apple identity token."); }
    if (header.alg !== "RS256") throw err(401, "Unexpected token algorithm.");
    let jwk = (await appleKeys()).find((k) => k.kid === header.kid);
    if (!jwk) jwk = (await appleKeys(true)).find((k) => k.kid === header.kid);
    if (!jwk) throw err(401, "Apple signing key not found.");
    const ok = crypto.verify("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), crypto.createPublicKey({ key: jwk, format: "jwk" }), Buffer.from(parts[2], "base64url"));
    if (!ok) throw err(401, "Apple identity token signature is invalid.");
    const now = Math.floor(Date.now() / 1000);
    if (claims.iss !== "https://appleid.apple.com") throw err(401, "Wrong token issuer.");
    const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!aud.some((a) => cfg.apple.audiences.includes(a))) throw err(401, "Token wasn't issued for Musa Control.");
    if (!claims.exp || claims.exp < now - 30) throw err(401, "Apple sign-in expired. Try again.");
    if (!claims.sub) throw err(401, "Token has no subject.");
    if (!rawNonce || claims.nonce !== sha(rawNonce)) throw err(401, "Sign-in nonce didn't match. Try again.");
    return claims;
  }

  async function appleSignIn({ identityToken, nonce, authorizationCode, name, deviceName, platform }, ip) {
    authGate(ip);
    let claims;
    try { claims = await verifyAppleToken(identityToken, nonce); }
    catch (e) { authFail(ip); audit("login.failed", { ip, detail: { method: "apple", reason: e.message } }); throw e; }
    let u = db.get("SELECT * FROM users WHERE apple_sub=?", claims.sub);
    const email = normEmail(claims.email);
    const verified = claims.email_verified === true || claims.email_verified === "true";
    if (!u) {
      if (cfg.registration !== "open") throw err(403, "Sign-ups are closed right now.");
      // An existing password account with the same verified email gets Apple attached.
      const byEmail = email && verified ? db.get("SELECT * FROM users WHERE email=?", email) : null;
      if (byEmail) {
        db.run("UPDATE users SET apple_sub=?, email_verified=1 WHERE id=?", claims.sub, byEmail.id);
        u = db.get("SELECT * FROM users WHERE id=?", byEmail.id);
        audit("account.apple_linked", { user: u.id, ip });
      } else {
        const id = crypto.randomUUID();
        const clash = email && db.get("SELECT 1 FROM users WHERE email=?", email);
        db.run("INSERT INTO users(id,email,email_verified,name,apple_sub,created_at) VALUES(?,?,?,?,?,?)", id, clash ? null : email, verified && !clash ? 1 : 0, String(name || "").trim().slice(0, 80) || null, claims.sub, Date.now());
        u = db.get("SELECT * FROM users WHERE id=?", id);
        audit("account.created", { user: id, ip, detail: { method: "apple" } });
      }
    }
    if (u.disabled) throw err(403, "This account is disabled.");
    if (authorizationCode && cfg.apple.revoke) {
      // Keep a refresh token (sealed) so deleting the account can revoke it at Apple.
      exchangeAppleCode(authorizationCode).then((rt) => { if (rt) db.run("UPDATE users SET apple_refresh=? WHERE id=?", seal.seal(rt), u.id); }).catch(() => {});
    }
    limiter.clear(`authfail:${ip}`);
    const s = newSession(u, { deviceName, platform, ip });
    audit("session.created", { user: u.id, ip, session: s.session.id, detail: { method: "apple", device: deviceName } });
    return s;
  }

  function appleClientSecret() {
    const r = cfg.apple.revoke;
    const key = crypto.createPrivateKey(fs.readFileSync(r.keyFile.replace(/^~/, process.env.HOME), "utf8"));
    const now = Math.floor(Date.now() / 1000);
    const h = b64u(JSON.stringify({ alg: "ES256", kid: r.keyId })), c = b64u(JSON.stringify({ iss: r.teamId, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: r.clientId }));
    const sig = crypto.sign("SHA256", Buffer.from(`${h}.${c}`), { key, dsaEncoding: "ieee-p1363" });
    return `${h}.${c}.${b64u(sig)}`;
  }
  async function exchangeAppleCode(code) {
    const body = new URLSearchParams({ client_id: cfg.apple.revoke.clientId, client_secret: appleClientSecret(), code, grant_type: "authorization_code" });
    const r = await fetchImpl("https://appleid.apple.com/auth/token", { method: "POST", body, signal: AbortSignal.timeout(10_000) });
    return r.ok ? (await r.json()).refresh_token || null : null;
  }
  async function revokeApple(u) {
    if (!cfg.apple.revoke || !u.apple_refresh) return false;
    const token = seal.open(u.apple_refresh);
    const body = new URLSearchParams({ client_id: cfg.apple.revoke.clientId, client_secret: appleClientSecret(), token, token_type_hint: "refresh_token" });
    const r = await fetchImpl("https://appleid.apple.com/auth/revoke", { method: "POST", body, signal: AbortSignal.timeout(10_000) });
    return r.ok;
  }

  // ---------- sessions ----------
  const touchAt = new Map();
  function authenticate(token, ip) {
    if (!token || !String(token).startsWith("mcs_")) return null;
    const row = db.get(`SELECT s.*, u.email, u.name, u.disabled FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash=?`, sha(token));
    if (!row || row.revoked_at || row.expires_at < Date.now() || row.disabled) return null;
    const now = Date.now();
    if (now - (touchAt.get(row.id) || 0) > 60_000) {
      touchAt.set(row.id, now);
      // Sliding expiry: active sessions stay signed in.
      db.run("UPDATE sessions SET last_seen=?, last_ip=?, expires_at=? WHERE id=?", now, ip, now + cfg.sessionDays * 86400_000, row.id);
    }
    return { sessionId: row.id, userId: row.user_id, deviceName: row.device_name, email: row.email, name: row.name };
  }

  function me(auth) { return publicUser(db.get("SELECT * FROM users WHERE id=?", auth.userId)); }
  function rename(auth, name) { db.run("UPDATE users SET name=? WHERE id=?", String(name || "").trim().slice(0, 80) || null, auth.userId); return me(auth); }

  function sessions(auth) {
    return db.all("SELECT id,device_name,platform,created_at,last_seen,expires_at FROM sessions WHERE user_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY last_seen DESC", auth.userId, Date.now())
      .map((s) => ({ id: s.id, deviceName: s.device_name, platform: s.platform, createdAt: s.created_at, lastSeen: s.last_seen, expiresAt: s.expires_at, current: s.id === auth.sessionId }));
  }

  function revokeSession(auth, id, ip) {
    const r = db.run("UPDATE sessions SET revoked_at=? WHERE id=? AND user_id=? AND revoked_at IS NULL", Date.now(), id, auth.userId);
    if (!r.changes) throw err(404, "No such session.");
    db.run("DELETE FROM push_devices WHERE session_id=?", id);
    audit("session.revoked", { user: auth.userId, ip, session: id, detail: { by: auth.sessionId } });
    return { ok: true };
  }
  function revokeOthers(auth, ip) {
    const ids = db.all("SELECT id FROM sessions WHERE user_id=? AND id<>? AND revoked_at IS NULL", auth.userId, auth.sessionId).map((r) => r.id);
    for (const id of ids) { db.run("UPDATE sessions SET revoked_at=? WHERE id=?", Date.now(), id); db.run("DELETE FROM push_devices WHERE session_id=?", id); }
    audit("session.revoked_all", { user: auth.userId, ip, detail: { count: ids.length } });
    return { ok: true, revoked: ids };
  }

  function changePassword(auth, { current, next }, ip) {
    const u = db.get("SELECT * FROM users WHERE id=?", auth.userId);
    if (u.password_hash && !verifyPassword(String(current || ""), u.password_hash)) { authFail(ip); throw err(401, "Your current password didn't match."); }
    if (String(next || "").length < cfg.passwordMinLength) throw err(400, `Use a password of at least ${cfg.passwordMinLength} characters.`);
    db.run("UPDATE users SET password_hash=? WHERE id=?", hashPassword(next), u.id);
    audit("account.password_changed", { user: u.id, ip, session: auth.sessionId });
    return revokeOthers(auth, ip);
  }

  // Deletes the account and everything that belongs to it.
  async function deleteAccount(auth, { confirm, password }, ip) {
    if (confirm !== "DELETE") throw err(428, 'Type DELETE to confirm.');
    const u = db.get("SELECT * FROM users WHERE id=?", auth.userId);
    if (u.password_hash && !u.apple_sub && !verifyPassword(String(password || ""), u.password_hash)) { authFail(ip); throw err(401, "Your password didn't match."); }
    let appleRevoked = false;
    try { appleRevoked = await revokeApple(u); } catch {}
    const machines = db.all("SELECT id FROM machines WHERE user_id=?", u.id).map((m) => m.id);
    db.run("DELETE FROM users WHERE id=?", u.id); // cascades: sessions, machines, codes, push devices
    db.run("DELETE FROM audit WHERE user_id=?", u.id);
    // A single record without personal data, for abuse investigations.
    audit("account.deleted", { detail: { ref: sha(u.id).slice(0, 16), machines: machines.length, appleRevoked } });
    return { ok: true, machines, appleRevoked };
  }

  function exportData(auth) {
    const u = db.get("SELECT * FROM users WHERE id=?", auth.userId);
    return {
      exportedAt: new Date().toISOString(), account: publicUser(u), sessions: sessions(auth),
      machines: db.all("SELECT id,name,platform,hostname,os_user,created_at,last_seen,revoked_at FROM machines WHERE user_id=?", u.id),
      pushDevices: db.all("SELECT session_id,environment,updated_at FROM push_devices WHERE user_id=?", u.id),
      audit: db.all("SELECT ts,action,ip,session_id,machine_id,detail FROM audit WHERE user_id=? ORDER BY id", u.id),
    };
  }

  function auditLog(auth, limit = 100) {
    return db.all("SELECT id,ts,action,ip,session_id AS session,machine_id AS machine,detail FROM audit WHERE user_id=? ORDER BY id DESC LIMIT ?", auth.userId, Math.min(+limit || 100, 500))
      .map((r) => ({ ...r, detail: r.detail ? JSON.parse(r.detail) : null }));
  }

  function pruneAudit() { db.run("DELETE FROM audit WHERE ts < ?", Date.now() - cfg.auditDays * 86400_000); db.run("DELETE FROM sessions WHERE expires_at < ? OR revoked_at < ?", Date.now() - 86400_000, Date.now() - 30 * 86400_000); }

  return { register, login, appleSignIn, verifyAppleToken, authenticate, me, rename, sessions, revokeSession, revokeOthers, changePassword, deleteAccount, exportData, auditLog, audit, limiter, authGate, authFail, pruneAudit };
}
