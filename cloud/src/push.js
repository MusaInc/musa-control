// Push for public users: each companion sends its notification payloads up
// the relay; this fans them out to the owner's registered devices with the
// one APNs key the service holds. Per-device category switches are applied
// here; the payload's `mc.machine` tells the app which machine to open (and
// where an Approve/Reject from the notification must go).
import { loadApnsConfig, createApns } from "./apns.js";
import { err } from "./accounts.js";

const CATEGORIES = ["approvals", "input", "completed", "failed", "builds", "server"];
const DEFAULT = { categories: Object.fromEntries(CATEGORIES.map((c) => [c, true])), mutedMachines: [] };
const mergePrefs = (p = {}) => ({ categories: { ...DEFAULT.categories, ...(p.categories || {}) }, mutedMachines: Array.isArray(p.mutedMachines) ? p.mutedMachines.map(String).slice(0, 50) : [] });

export function createPush(cfg, db, { transport } = {}) {
  const conf = loadApnsConfig(cfg);
  const apns = conf.configured || transport ? createApns(conf.configured ? conf : { topic: "test" }, { transport }) : null;
  const sent = [];

  function register(auth, { token, environment, prefs }) {
    if (!/^[0-9a-f]{32,200}$/i.test(String(token || ""))) throw err(400, "Invalid APNs device token");
    const env = environment === "sandbox" ? "sandbox" : "production";
    const tok = String(token).toLowerCase();
    db.run("DELETE FROM push_devices WHERE apns_token=? AND session_id<>?", tok, auth.sessionId);
    const existing = db.get("SELECT prefs FROM push_devices WHERE session_id=?", auth.sessionId);
    db.run(`INSERT INTO push_devices(session_id,user_id,apns_token,environment,prefs,updated_at) VALUES(?,?,?,?,?,?)
      ON CONFLICT(session_id) DO UPDATE SET apns_token=excluded.apns_token, environment=excluded.environment, prefs=excluded.prefs, updated_at=excluded.updated_at, last_error=NULL`,
      auth.sessionId, auth.userId, tok, env, JSON.stringify(mergePrefs(prefs || (existing ? JSON.parse(existing.prefs) : {}))), Date.now());
    return status(auth);
  }
  function unregister(auth) { db.run("DELETE FROM push_devices WHERE session_id=?", auth.sessionId); return status(auth); }
  function setPrefs(auth, prefs) {
    const row = db.get("SELECT prefs FROM push_devices WHERE session_id=?", auth.sessionId);
    if (!row) throw err(409, "Allow notifications on this device first.");
    db.run("UPDATE push_devices SET prefs=?, updated_at=? WHERE session_id=?", JSON.stringify(mergePrefs({ ...JSON.parse(row.prefs), ...prefs })), Date.now(), auth.sessionId);
    return status(auth);
  }
  function status(auth) {
    const row = db.get("SELECT * FROM push_devices WHERE session_id=?", auth.sessionId);
    return { serverConfigured: Boolean(apns), reason: apns ? null : conf.reason, registered: Boolean(row), environment: row?.environment || null, lastError: row?.last_error || null, prefs: mergePrefs(row ? JSON.parse(row.prefs) : {}) };
  }

  async function fanOut(machine, message) {
    if (!apns || !message?.payload) return;
    const payload = message.payload;
    const mc = { ...(payload.mc || {}), machine: machine.id, machineName: machine.name };
    const cat = mc.category;
    const alert = payload.aps?.alert;
    if (alert && typeof alert === "object") alert.title = `${String(alert.title || "").slice(0, 120)}${machine.name ? ` · ${machine.name}` : ""}`.slice(0, 160);
    const devices = db.all("SELECT p.* FROM push_devices p JOIN sessions s ON s.id=p.session_id WHERE p.user_id=? AND s.revoked_at IS NULL AND s.expires_at>?", machine.user_id, Date.now());
    for (const d of devices) {
      const prefs = mergePrefs(JSON.parse(d.prefs));
      if (cat && prefs.categories[cat] === false) continue;
      if (prefs.mutedMachines.includes(machine.id) && !mc.withdraw) continue;
      const r = await apns.send({ deviceToken: d.apns_token, environment: d.environment, payload: { ...payload, mc }, collapseId: message.collapseId ? `${machine.id.slice(0, 8)}-${message.collapseId}`.slice(0, 64) : undefined,
        expiration: message.expiration, pushType: message.pushType || "alert", priority: message.priority || 10 });
      sent.push({ session: d.session_id, status: r.status });
      if (r.status === 200) db.run("UPDATE push_devices SET last_error=NULL WHERE session_id=?", d.session_id);
      else if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") db.run("DELETE FROM push_devices WHERE session_id=?", d.session_id);
      else db.run("UPDATE push_devices SET last_error=? WHERE session_id=?", `${r.status} ${r.reason || ""}`.trim(), d.session_id);
    }
  }

  async function test(auth) {
    if (!apns) throw err(503, conf.reason);
    const d = db.get("SELECT * FROM push_devices WHERE session_id=?", auth.sessionId);
    if (!d) throw err(409, "This device hasn't registered for push yet.");
    const r = await apns.send({ deviceToken: d.apns_token, environment: d.environment, payload: { aps: { alert: { title: "Musa Control", body: "Push notifications are working." }, sound: "default", category: "MC_TEST" }, mc: { kind: "test" } } });
    if (r.status !== 200) throw err(502, `Apple refused the push: ${r.status} ${r.reason || ""}`);
    return { ok: true };
  }

  return { register, unregister, setPrefs, status, fanOut, test, close: () => apns?.close(), enabled: Boolean(apns), _sent: sent };
}
