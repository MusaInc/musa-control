// musa-companion: the gateway on someone's own machine (see config.js,
// profile "companion"). Run `musa-companion help`.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { execFileSync } from "node:child_process";
import { loadConfig, configFile } from "./config.js";
import { openDb } from "./db.js";
import { createAuth } from "./auth.js";

process.env.MUSA_CONTROL_PROFILE = process.env.MUSA_CONTROL_PROFILE || "companion";
const APP_DIR = path.resolve(new URL("..", import.meta.url).pathname);
const [cmd, ...rest] = process.argv.slice(2);
const flag = (name, d = null) => { const i = rest.indexOf(`--${name}`); return i >= 0 ? rest[i + 1] : d; };
const has = (name) => rest.includes(`--${name}`);
const out = (o) => console.log(has("json") ? JSON.stringify(o) : typeof o === "string" ? o : JSON.stringify(o, null, 2));

function readCfgFile() { const f = configFile("companion"); try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return {}; } }
function writeCfgFile(obj) {
  const f = configFile("companion");
  fs.mkdirSync(path.dirname(f), { recursive: true, mode: 0o700 });
  fs.writeFileSync(f + ".tmp", JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.renameSync(f + ".tmp", f);
}
function portFree(port) {
  return new Promise((r) => { const s = net.createServer().once("error", () => r(false)).once("listening", () => s.close(() => r(true))); s.listen(port, "127.0.0.1"); });
}
async function running(cfg) {
  try { const r = await fetch(`http://127.0.0.1:${cfg.port}/api/ping`, { signal: AbortSignal.timeout(2000) }); const j = await r.json(); return j.service === "musa-control" ? j : null; } catch { return null; }
}

const help = `musa-companion — connects this machine to Musa Control

  start                         run the companion in the foreground
  install-service               run it in the background at login (systemd --user or launchd)
  uninstall-service             stop and remove the background service
  info [--json]                 version, port, data folder, link state
  token --name <device> [--json]  issue a device token (the app runs this over SSH)
  pair                          print a one-time pairing code (10 minutes)
  link <code> [--relay URL] [--name NAME]  link to your Musa Control account (relay)
  unlink                        remove the account link
  devices | revoke <id>         paired devices
  doctor                        check what this machine supports`;

async function main() {
  if (!cmd || cmd === "help" || cmd === "--help") return console.log(help);
  if (cmd === "start") {
    if (os.userInfo().uid === 0 && !has("allow-root")) { console.error("Refusing to run as root: run the companion as your normal user (agents, files and terminals run as that user)."); process.exit(2); }
    await import("./main.js");
    return;
  }
  // Keep stdout for results only (the app parses --json output over SSH).
  console.info = (...a) => console.error(...a);
  const cfg = loadConfig({ profile: "companion" });
  if (cmd === "info") {
    const live = await running(cfg);
    return out({ service: "musa-companion", version: live?.version || null, running: Boolean(live), port: cfg.port, dataDir: cfg.dataDir, configFile: cfg.configFile,
      user: os.userInfo().username, home: os.homedir(), hostname: os.hostname(), platform: process.platform, node: process.version, appDir: APP_DIR,
      linked: Boolean(cfg.relay?.url), relay: cfg.relay?.url || null, machineId: cfg.relay?.machineId || null });
  }
  if (cmd === "doctor") {
    const which = (c) => { try { return execFileSync("/bin/sh", ["-c", `command -v ${c}`], { encoding: "utf8" }).trim(); } catch { return null; } };
    const [maj, min] = process.versions.node.split(".").map(Number);
    return out({ node: process.version, nodeOk: maj > 22 || (maj === 22 && min >= 5), tmux: which("tmux"), python3: which("python3"), git: which("git"), gh: which("gh"),
      claude: which("claude"), codex: which("codex"), gemini: which("gemini"), platform: process.platform, wsl: /microsoft/i.test(os.release()) });
  }
  const db = openDb(cfg); const auth = createAuth(cfg, db);
  if (cmd === "token") {
    const t = auth.issue(flag("name", "iPad"), "cli");
    return out({ ...t, port: cfg.port, user: os.userInfo().username, hostname: os.hostname(), platform: process.platform });
  }
  if (cmd === "pair") { const c = auth.createPairCode(); return out(has("json") ? c : `Pairing code: ${c.code}  (valid 10 minutes, single use)`); }
  if (cmd === "devices") { for (const d of auth.listDevices()) console.log(`${d.id}  ${d.revoked ? "REVOKED" : "active "}  ${d.name}  last seen ${d.last_seen ? new Date(d.last_seen).toISOString() : "never"}`); return; }
  if (cmd === "revoke" && rest[0]) { auth.revoke(rest[0]); return out("revoked " + rest[0]); }
  if (cmd === "link") {
    const code = rest.find((a) => !a.startsWith("--") && rest[rest.indexOf(a) - 1]?.startsWith("--") !== true);
    if (!code) { console.error("usage: musa-companion link <code> [--relay https://…]"); process.exit(2); }
    const relayUrl = (flag("relay") || process.env.MUSA_CONTROL_RELAY || "https://musastudios.co.uk/control-cloud").replace(/\/+$/, "");
    const r = await fetch(`${relayUrl}/v1/machines/claim`, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, name: flag("name", os.hostname()), platform: process.platform, hostname: os.hostname(), user: os.userInfo().username }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { console.error(`Link refused: ${j.error || r.status}`); process.exit(1); }
    const file = readCfgFile();
    file.relay = { url: relayUrl, machineId: j.machineId, machineSecret: j.machineSecret, owner: j.owner, linkedAt: Date.now() };
    file.machineName = flag("name", file.machineName || os.hostname());
    writeCfgFile(file);
    return out(has("json") ? { ok: true, machineId: j.machineId } : `Linked as "${file.machineName}". Restart the companion (musa-companion install-service) to connect.`);
  }
  if (cmd === "unlink") {
    const file = readCfgFile();
    if (file.relay?.url) await fetch(`${file.relay.url}/v1/relay/self`, { method: "DELETE", headers: { Authorization: `Bearer ${file.relay.machineSecret}` } }).catch(() => {});
    delete file.relay; writeCfgFile(file);
    return out("Unlinked. Restart the companion to drop the connection.");
  }
  if (cmd === "install-service") return installService(cfg);
  if (cmd === "uninstall-service") return uninstallService();
  console.log(help); process.exit(2);
}

async function installService(cfg) {
  // Pick a free loopback port the first time (several users can share a VPS).
  const file = readCfgFile();
  if (!file.port) {
    let port = 8170;
    while (!(await portFree(port)) && port < 8270) port++;
    file.port = port; writeCfgFile(file);
  }
  const node = process.execPath, entry = path.join(APP_DIR, "bin", "musa-companion.js");
  const PATH = [path.dirname(node), path.join(os.homedir(), ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].join(":");
  if (process.platform === "darwin") {
    const plist = path.join(os.homedir(), "Library/LaunchAgents/uk.co.musastudios.companion.plist");
    fs.mkdirSync(path.dirname(plist), { recursive: true });
    const logDir = path.join(os.homedir(), "Library/Logs");
    fs.writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>uk.co.musastudios.companion</string>
<key>ProgramArguments</key><array><string>${node}</string><string>${entry}</string><string>start</string></array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${PATH}</string><key>MUSA_CONTROL_PROFILE</key><string>companion</string></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>${logDir}/musa-companion.log</string><key>StandardErrorPath</key><string>${logDir}/musa-companion.log</string>
<key>AbandonProcessGroup</key><true/>
</dict></plist>
`);
    try { execFileSync("launchctl", ["unload", plist], { stdio: "ignore" }); } catch {}
    execFileSync("launchctl", ["load", "-w", plist]);
    return out(has("json") ? { ok: true, manager: "launchd", port: file.port } : `Installed (launchd). Listening on 127.0.0.1:${file.port}.`);
  }
  // MUSA_COMPANION_NO_SERVICE=1: containers / tests — a plain background process.
  const noService = process.env.MUSA_COMPANION_NO_SERVICE === "1";
  const unitDir = path.join(os.homedir(), ".config/systemd/user");
  if (!noService) fs.mkdirSync(unitDir, { recursive: true });
  if (!noService) fs.writeFileSync(path.join(unitDir, "musa-companion.service"), `[Unit]
Description=Musa Control companion (loopback only)
After=network-online.target

[Service]
Type=simple
Environment=PATH=${PATH}
Environment=MUSA_CONTROL_PROFILE=companion
ExecStart=${node} --no-warnings ${entry} start
Restart=on-failure
RestartSec=3
# tmux sessions it starts (agents, terminals) must outlive restarts.
KillMode=process

[Install]
WantedBy=default.target
`);
  try {
    if (noService) throw new Error("no service manager requested");
    execFileSync("systemctl", ["--user", "daemon-reload"]);
    execFileSync("systemctl", ["--user", "enable", "--now", "musa-companion.service"]);
    execFileSync("systemctl", ["--user", "restart", "musa-companion.service"]);
    // Keep running after logout (needs lingering; harmless if not permitted).
    try { execFileSync("loginctl", ["enable-linger", os.userInfo().username], { stdio: "ignore" }); } catch {}
    return out(has("json") ? { ok: true, manager: "systemd", port: file.port } : `Installed (systemd --user). Listening on 127.0.0.1:${file.port}.`);
  } catch {
    // No user systemd (containers, WSL without systemd): plain background process.
    const { spawn } = await import("node:child_process");
    const log = fs.openSync(path.join(cfg.dataDir, "companion.log"), "a");
    const child = spawn(node, [entry, "start"], { detached: true, stdio: ["ignore", log, log], env: { ...process.env, MUSA_CONTROL_PROFILE: "companion" } });
    child.unref();
    return out(has("json") ? { ok: true, manager: "nohup", port: file.port, pid: child.pid } : `Started in the background (pid ${child.pid}); it won't restart after a reboot on this system.`);
  }
}

function uninstallService() {
  if (process.platform === "darwin") {
    const plist = path.join(os.homedir(), "Library/LaunchAgents/uk.co.musastudios.companion.plist");
    try { execFileSync("launchctl", ["unload", plist]); } catch {}
    fs.rmSync(plist, { force: true });
  } else {
    try { execFileSync("systemctl", ["--user", "disable", "--now", "musa-companion.service"]); } catch {}
    fs.rmSync(path.join(os.homedir(), ".config/systemd/user/musa-companion.service"), { force: true });
  }
  return out("Service removed. Your data folder was kept.");
}

main().catch((e) => { console.error(e.message); process.exit(1); });
