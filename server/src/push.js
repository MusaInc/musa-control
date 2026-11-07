// Push notifications to paired devices while Musa Control is closed,
// backgrounded or the device is locked.
//
// * Devices register their APNs token and preferences (categories, sounds,
//   muted projects/agents). Filtering happens here, so it works when the app
//   isn't running.
// * Only meaningful events push: approvals, finished turns, agents waiting
//   for an answer, real errors, builds/CI and server alerts. Routine commands
//   never do.
// * Approval pushes carry a one-time action token. Approve/Reject from the
//   notification is accepted only for this device, only once, only while the
//   same prompt is still on the agent's screen, and only within 15 minutes.
//   High-risk or partly hidden commands get no buttons: they must be reviewed
//   in the app.
import crypto from "node:crypto";
import { loadApnsConfig, createApns } from "./apns.js";

const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
const ACTION_TTL = 15 * 60_000;

export const CATEGORIES = ["approvals", "input", "completed", "failed", "builds", "server"];
export const DEFAULT_PREFS = {
  categories: { approvals: true, input: true, completed: true, failed: true, builds: true, server: true },
  sounds: { approvals: true, input: true, completed: false, failed: true, builds: false, server: true },
  mutedProjects: [], mutedAgents: [],
};

// Commands that must be reviewed in the app, never approved from a lock screen.
const HIGH_RISK = [
  /\brm\s+(-[a-z]*[rf][a-z]*\s+)+/i, /\bsudo\b/, /\bgit\s+push\b.*(--force|-f\b|--delete|:)/i, /\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|filter-branch|push\s+--mirror)/i,
  /\bdrop\s+(table|database|schema)\b/i, /\btruncate\s+table\b/i, /\bdelete\s+from\b/i, /\bmkfs\b|\bdd\s+if=/i, /\bchmod\s+-R\b|\bchown\s+-R\b/i,
  /(curl|wget)\b[^|]*\|\s*(ba|z)?sh\b/i, /\bsystemctl\s+(stop|disable|mask|restart|reboot|poweroff)\b/i, /\b(reboot|shutdown|poweroff)\b/i,
  /\bkill(all)?\s+-9\b|\bpkill\b/i, /\b(npm|pnpm|yarn)\s+publish\b|\bgh\s+release\s+create\b|\beas\s+submit\b|\bfastlane\b|\baltool\b|\btransporter\b/i,
  /\bterraform\s+(apply|destroy)\b|\bkubectl\s+delete\b|\bdocker\s+(rm|rmi|system\s+prune)\b/i, /\bcaddy\s+(reload|stop)\b/i,
  />\s*\/etc\/|\/etc\/(sudoers|passwd|shadow)|authorized_keys|\.ssh\//i, /\b(security\s+delete|keychain)\b/i, /\.env\b|\.p8\b|\.pem\b|\.keystore\b/i,
  /\bdeploy\b|\bproduction\b|\bprod\b/i,
];
const FOLDED = /\[…\s*\+?\d+ lines?\]|… \+\d+ lines|ctrl \+ [a-z] (to )?view/i;

export function assessApproval(prompt) {
  const text = `${prompt.command || ""}\n${prompt.context || ""}`;
  if (prompt.kind === "trust") return { reviewOnly: true, reason: "Folder trust must be confirmed in the app." };
  if (FOLDED.test(prompt.context || "")) return { reviewOnly: true, reason: "Part of the command is hidden on the agent's screen." };
  if (HIGH_RISK.some((r) => r.test(text))) return { reviewOnly: true, reason: "High-risk command: review it in the app." };
  const approve = prompt.options.find((o) => o.tone === "allow" && !/always|don.t ask|for this session|all edits|auto/i.test(o.label));
  const reject = [...prompt.options].reverse().find((o) => o.tone === "deny");
  if (!approve || !reject) return { reviewOnly: true, reason: "No plain yes/no choice." };
  return { reviewOnly: false, approve: approve.index, reject: reject.index };
}

export function createPush(cfg, db, events, agents, { transport } = {}) {
  db.raw.exec(`
    CREATE TABLE IF NOT EXISTS push_devices (
      device_id TEXT PRIMARY KEY, apns_token TEXT NOT NULL, environment TEXT NOT NULL, prefs TEXT NOT NULL,
      updated_at INTEGER NOT NULL, last_sent INTEGER, last_error TEXT
    );
    CREATE TABLE IF NOT EXISTS push_actions (
      nonce_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL, session TEXT NOT NULL, signature TEXT NOT NULL,
      approve INTEGER NOT NULL, reject INTEGER NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
      used_at INTEGER, outcome TEXT
    );
    CREATE INDEX IF NOT EXISTS push_actions_session ON push_actions(session, used_at);
  `);
  const conf = loadApnsConfig(cfg);
  const apns = conf.configured || transport ? createApns(conf.configured ? conf : { topic: "test" }, { transport }) : null;
  const recent = new Map(); // device|session|category → last push time (cooldown)

  const devicesStmt = () => db.raw.prepare(`SELECT p.*, d.name FROM push_devices p JOIN devices d ON d.id = p.device_id
    WHERE d.revoked = 0 AND d.expires_at > ?`).all(Date.now());
  const prefsOf = (row) => { try { return mergePrefs(JSON.parse(row.prefs)); } catch { return mergePrefs({}); } };

  function mergePrefs(p = {}) {
    return {
      categories: { ...DEFAULT_PREFS.categories, ...(p.categories || {}) },
      sounds: { ...DEFAULT_PREFS.sounds, ...(p.sounds || {}) },
      mutedProjects: Array.isArray(p.mutedProjects) ? p.mutedProjects.map(String).slice(0, 200) : [],
      mutedAgents: Array.isArray(p.mutedAgents) ? p.mutedAgents.filter((a) => ["claude", "codex"].includes(a)) : [],
    };
  }

  function register(device, { token, environment, prefs }) {
    if (!/^[0-9a-f]{32,200}$/i.test(String(token || ""))) throw Object.assign(new Error("Invalid APNs device token"), { status: 400 });
    const env = environment === "sandbox" ? "sandbox" : "production";
    const existing = db.raw.prepare("SELECT prefs FROM push_devices WHERE device_id=?").get(device.id);
    const merged = mergePrefs(prefs || (existing ? JSON.parse(existing.prefs) : {}));
    // One token belongs to one device row (re-pairing the same iPad).
    db.raw.prepare("DELETE FROM push_devices WHERE apns_token=? AND device_id<>?").run(String(token).toLowerCase(), device.id);
    db.raw.prepare(`INSERT INTO push_devices(device_id,apns_token,environment,prefs,updated_at) VALUES(?,?,?,?,?)
      ON CONFLICT(device_id) DO UPDATE SET apns_token=excluded.apns_token, environment=excluded.environment, prefs=excluded.prefs, updated_at=excluded.updated_at, last_error=NULL`)
      .run(device.id, String(token).toLowerCase(), env, JSON.stringify(merged), Date.now());
    return status(device);
  }

  function unregister(device) { db.raw.prepare("DELETE FROM push_devices WHERE device_id=?").run(device.id); return status(device); }

  function setPrefs(device, prefs) {
    const row = db.raw.prepare("SELECT * FROM push_devices WHERE device_id=?").get(device.id);
    const merged = mergePrefs({ ...(row ? JSON.parse(row.prefs) : {}), ...prefs });
    if (row) db.raw.prepare("UPDATE push_devices SET prefs=?, updated_at=? WHERE device_id=?").run(JSON.stringify(merged), Date.now(), device.id);
    else db.set(`push-prefs:${device.id}`, merged); // kept until the device registers
    return status(device);
  }

  function status(device) {
    const row = db.raw.prepare("SELECT * FROM push_devices WHERE device_id=?").get(device.id);
    return {
      serverConfigured: Boolean(apns), reason: apns ? null : conf.reason,
      registered: Boolean(row), environment: row?.environment || null, lastSent: row?.last_sent || null, lastError: row?.last_error || null,
      prefs: row ? prefsOf(row) : mergePrefs(db.get(`push-prefs:${device.id}`, {})),
    };
  }

  // ---------- deciding what to push ----------
  function categoryOf(ev) {
    switch (ev.kind) {
      case "agent.approval": return "approvals";
      case "agent.done": return /\?\s*$/.test(String(ev.detail?.last || "").trim()) ? "input" : "completed";
      case "agent.error": return /retrying|reconnect|stream disconnected/i.test(ev.title) ? null : "failed";
      case "build.finished": case "ci.finished": return "builds";
      case "server.alert": return "server";
      default: return null;
    }
  }

  const agentName = (a) => (a === "claude" ? "Claude Code" : a === "codex" ? "Codex" : "Agent");
  const clip = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };

  function content(ev, cat) {
    const who = agentName(ev.detail?.agent);
    const proj = ev.project ? ` · ${ev.project}` : "";
    const task = ev.detail?.sessionTitle ? clip(ev.detail.sessionTitle, 80) : null;
    switch (cat) {
      case "approvals": return { title: `${who} needs approval${proj}`, subtitle: clip(ev.detail?.question || "", 140), body: clip(ev.detail?.command ? `$ ${ev.detail.command}` : ev.detail?.context || ev.title, 600) };
      case "input": return { title: `${who} is waiting for you${proj}`, subtitle: task || "", body: clip(ev.detail?.last, 400) };
      case "completed": return { title: `${who} finished${proj}`, subtitle: task || "", body: clip(ev.detail?.last || ev.title, 400) };
      case "failed": return { title: `${who} hit an error${proj}`, subtitle: task || "", body: clip(ev.title, 400) };
      case "builds": return { title: ev.kind === "ci.finished" ? `CI${proj}` : `Build${proj}`, subtitle: "", body: clip(ev.title, 300) };
      default: return { title: "Server alert", subtitle: "", body: clip(ev.title, 300) };
    }
  }

  async function onEvent(ev) {
    if (!apns) return;
    if (ev.kind === "agent.approval_answered" || ev.kind === "agent.approval_cleared") return clearApproval(ev);
    if (!ev.notify) return;
    const cat = categoryOf(ev);
    if (!cat) return;
    const devices = devicesStmt();
    for (const d of devices) {
      const prefs = prefsOf(d);
      if (!prefs.categories[cat]) continue;
      if (ev.project && prefs.mutedProjects.includes(ev.project)) continue;
      if (ev.detail?.agent && prefs.mutedAgents.includes(ev.detail.agent)) continue;
      const key = `${d.device_id}|${ev.session || ev.project || "-"}|${cat}`;
      if (cat !== "approvals" && Date.now() - (recent.get(key) || 0) < 45_000) continue; // no bursts
      recent.set(key, Date.now());
      const c = content(ev, cat);
      const mc = { kind: ev.kind, category: cat, eventId: ev.id, session: ev.session, project: ev.project, view: cat === "approvals" ? "approval" : "activity" };
      let category = `MC_${cat.toUpperCase()}`;
      if (cat === "approvals") {
        const risk = assessApproval(ev.detail);
        if (risk.reviewOnly) { category = "MC_APPROVAL_REVIEW"; mc.reviewReason = risk.reason; }
        else {
          const nonce = crypto.randomBytes(24).toString("base64url");
          db.raw.prepare("INSERT INTO push_actions(nonce_hash,device_id,session,signature,approve,reject,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?)")
            .run(sha(nonce), d.device_id, ev.session, ev.detail.signature, risk.approve, risk.reject, Date.now(), Date.now() + ACTION_TTL);
          category = "MC_APPROVAL";
          Object.assign(mc, { nonce, signature: ev.detail.signature, approveLabel: ev.detail.options[risk.approve]?.label, rejectLabel: ev.detail.options[risk.reject]?.label });
        }
      }
      const payload = {
        aps: { alert: c, category, "thread-id": ev.session || ev.project || cat, sound: prefs.sounds[cat] ? "default" : undefined,
          "interruption-level": cat === "approvals" || cat === "input" ? "time-sensitive" : "active", "relevance-score": cat === "approvals" ? 1 : 0.5 },
        mc,
      };
      await deliver(d, { payload, collapseId: cat === "approvals" ? `ap-${sha(ev.session + ev.detail.signature).slice(0, 20)}` : undefined,
        expiration: cat === "approvals" ? Date.now() + ACTION_TTL : Date.now() + 6 * 3600_000 });
    }
  }

  // An answered or vanished prompt: invalidate its action tokens and ask the
  // device (silently) to withdraw the notification.
  async function clearApproval(ev) {
    db.raw.prepare("UPDATE push_actions SET used_at=?, outcome=COALESCE(outcome,'superseded') WHERE session=? AND used_at IS NULL").run(Date.now(), ev.session);
    const sig = ev.detail?.signature;
    if (!sig) return;
    const collapse = `ap-${sha(ev.session + sig).slice(0, 20)}`;
    for (const d of devicesStmt()) {
      await deliver(d, { payload: { aps: { "content-available": 1 }, mc: { withdraw: collapse } }, pushType: "background", priority: 5, expiration: Date.now() + 3600_000 });
    }
  }

  async function deliver(d, { payload, collapseId, expiration, pushType = "alert", priority = 10 }) {
    const r = await apns.send({ deviceToken: d.apns_token, environment: d.environment, payload, collapseId, expiration, pushType, priority });
    if (r.status === 200) db.raw.prepare("UPDATE push_devices SET last_sent=?, last_error=NULL WHERE device_id=?").run(Date.now(), d.device_id);
    else {
      db.raw.prepare("UPDATE push_devices SET last_error=? WHERE device_id=?").run(`${r.status} ${r.reason || ""}`.trim(), d.device_id);
      // The token is dead (app deleted / environment mismatch): stop using it.
      if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") db.raw.prepare("DELETE FROM push_devices WHERE device_id=?").run(d.device_id);
      console.warn("apns", r.status, r.reason);
    }
    return r;
  }

  // ---------- acting from a notification ----------
  async function act(device, { nonce, action }) {
    if (!["approve", "reject"].includes(action)) throw Object.assign(new Error("action must be approve or reject"), { status: 400 });
    const row = db.raw.prepare("SELECT * FROM push_actions WHERE nonce_hash=?").get(sha(String(nonce || "")));
    if (!row || row.device_id !== device.id) throw Object.assign(new Error("Unknown approval token."), { status: 404 });
    if (row.used_at) throw Object.assign(new Error(row.outcome === "superseded" ? "That approval was already answered or closed." : "That approval was already used."), { status: 409 });
    if (row.expires_at < Date.now()) throw Object.assign(new Error("That approval request expired. Open Musa Control to review it."), { status: 410 });
    // Claim it first: a second tap (or a replay) can't press keys twice.
    const claimed = db.raw.prepare("UPDATE push_actions SET used_at=?, outcome=? WHERE nonce_hash=? AND used_at IS NULL").run(Date.now(), action, row.nonce_hash);
    if (!claimed.changes) throw Object.assign(new Error("That approval was already used."), { status: 409 });
    try {
      const r = await agents.answer(row.session, { signature: row.signature, option: action === "approve" ? row.approve : row.reject, via: `notification (${device.name})` });
      return { ok: true, answered: r.answered, action };
    } catch (e) {
      db.raw.prepare("UPDATE push_actions SET outcome=? WHERE nonce_hash=?").run(`failed: ${e.message}`.slice(0, 200), row.nonce_hash);
      throw e;
    }
  }

  async function test(device) {
    if (!apns) throw Object.assign(new Error(conf.reason), { status: 503 });
    const d = db.raw.prepare("SELECT * FROM push_devices WHERE device_id=?").get(device.id);
    if (!d) throw Object.assign(new Error("This device hasn't registered for push yet. Allow notifications first."), { status: 409 });
    const r = await deliver(d, { payload: { aps: { alert: { title: "Musa Control", body: "Push notifications are working." }, sound: "default", category: "MC_TEST" }, mc: { kind: "test" } } });
    if (r.status !== 200) throw Object.assign(new Error(`Apple refused the push: ${r.status} ${r.reason || ""}`), { status: 502 });
    return { ok: true };
  }

  const unsub = events.subscribe((ev) => { onEvent(ev).catch((e) => console.error("push", e.message)); });
  setInterval(() => db.raw.prepare("DELETE FROM push_actions WHERE expires_at < ?").run(Date.now() - 86400_000), 3600_000).unref();
  function close() { unsub(); apns?.close(); }
  return { register, unregister, setPrefs, status, act, test, close, _onEvent: onEvent, enabled: Boolean(apns) };
}
