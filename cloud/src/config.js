// Musa Control Cloud configuration. Defaults are safe for local testing;
// production values come from ~/.config/musa-control-cloud/config.json
// (or MUSA_CLOUD_CONFIG). Secrets are referenced by file path only.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = os.homedir();
export const expand = (p) => (p && p.startsWith("~") ? path.join(HOME, p.slice(1)) : p);

const defaults = {
  host: "127.0.0.1",
  port: 8180,
  // Public URL the app and companions use (TLS terminated by a reverse proxy).
  publicUrl: "http://127.0.0.1:8180",
  dataDir: "~/.local/share/musa-control-cloud",
  sessionDays: 60,
  // Sign in with Apple: the app's bundle id is the token audience.
  apple: { audiences: ["uk.co.musastudios.musacontrol"], jwksUrl: "https://appleid.apple.com/auth/keys",
    // Optional, for revoking Apple tokens when an account is deleted:
    // {"teamId","keyId","keyFile" (Sign in with Apple .p8), "clientId"}
    revoke: null },
  apnsConfigFile: "~/.config/musa-control-cloud/apns.json",
  // Abuse limits.
  limits: { authFailuresPerIp: 10, authWindowMinutes: 15, requestsPerMinutePerIp: 600, streamsPerMachine: 96, pushesPerMachinePerHour: 240,
    machinesPerUser: 20, relayBodyBytes: 210 * 1024 * 1024, registrationsPerIpPerDay: 10 },
  passwordMinLength: 10,
  auditDays: 180,
  // Registration can be closed (invite-only beta) without code changes.
  registration: "open", // "open" | "closed"
  trustProxy: true,
  // The companion bundle served at /companion/musa-companion.tgz.
  companionBundle: null,
};

function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over || {})) out[k] = v && typeof v === "object" && !Array.isArray(v) && base[k] && typeof base[k] === "object" && !Array.isArray(base[k]) ? merge(base[k], v) : v;
  return out;
}

export function loadConfig(overrides = {}) {
  const file = expand(process.env.MUSA_CLOUD_CONFIG || "~/.config/musa-control-cloud/config.json");
  let fromFile = {};
  if (fs.existsSync(file)) fromFile = JSON.parse(fs.readFileSync(file, "utf8"));
  const cfg = merge(merge(defaults, fromFile), overrides);
  if (process.env.MUSA_CLOUD_PORT) cfg.port = Number(process.env.MUSA_CLOUD_PORT);
  cfg.dataDir = expand(process.env.MUSA_CLOUD_DATA || cfg.dataDir);
  fs.mkdirSync(cfg.dataDir, { recursive: true, mode: 0o700 });
  cfg.publicUrl = String(cfg.publicUrl).replace(/\/+$/, "");
  return cfg;
}
