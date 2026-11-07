// Device management from the VPS shell:
//   node src/cli.js devices          list paired devices
//   node src/cli.js revoke <id>      revoke one
import { loadConfig } from "./config.js";
import { openDb } from "./db.js";
import { createAuth } from "./auth.js";
const cfg = loadConfig(); const db = openDb(cfg); const auth = createAuth(cfg, db);
const [cmd, arg] = process.argv.slice(2);
if (cmd === "devices") for (const d of auth.listDevices()) console.log(`${d.id}  ${d.revoked ? "REVOKED" : "active "}  ${d.name}  paired ${new Date(d.created_at).toISOString()}  last seen ${d.last_seen ? new Date(d.last_seen).toISOString() : "never"}`);
else if (cmd === "revoke" && arg) { auth.revoke(arg); console.log("revoked", arg); }
else console.log("usage: cli.js devices | revoke <id>");
