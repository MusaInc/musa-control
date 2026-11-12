// Local administration (there is deliberately no admin HTTP API):
//   node src/cli.js stats | users | disable <email> | enable <email> | machines <email>
import { loadConfig } from "./config.js";
import { openDb } from "./db.js";
const db = openDb(loadConfig());
const [cmd, arg] = process.argv.slice(2);
const user = (e) => db.get("SELECT * FROM users WHERE email=?", String(e || "").toLowerCase());
if (cmd === "stats") console.log({ users: db.get("SELECT COUNT(*) n FROM users").n, machines: db.get("SELECT COUNT(*) n FROM machines WHERE revoked_at IS NULL").n, sessions: db.get("SELECT COUNT(*) n FROM sessions WHERE revoked_at IS NULL AND expires_at>?", Date.now()).n });
else if (cmd === "users") for (const u of db.all("SELECT id,email,created_at,disabled,apple_sub IS NOT NULL apple FROM users ORDER BY created_at")) console.log(u.id, u.email || "(apple private)", new Date(u.created_at).toISOString(), u.apple ? "apple" : "", u.disabled ? "DISABLED" : "");
else if ((cmd === "disable" || cmd === "enable") && user(arg)) { db.run("UPDATE users SET disabled=? WHERE id=?", cmd === "disable" ? 1 : 0, user(arg).id); console.log(cmd + "d", arg, "(restart not needed; sessions stop working at once)"); }
else if (cmd === "machines" && user(arg)) for (const m of db.all("SELECT id,name,platform,last_seen FROM machines WHERE user_id=? AND revoked_at IS NULL", user(arg).id)) console.log(m.id, m.name, m.platform, m.last_seen ? new Date(m.last_seen).toISOString() : "");
else console.log("usage: cli.js stats | users | disable <email> | enable <email> | machines <email>");
