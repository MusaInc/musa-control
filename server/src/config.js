// Gateway configuration. Two profiles share the same code:
//
// * "personal" (the default, musa-control.service): the Musa Studios VPS,
//   paired with the workspace password, served by Caddy at /control.
//   Config ~/.config/musa-control/config.json, data ~/.local/share/musa-control.
// * "companion" (MUSA_CONTROL_PROFILE=companion, `bin/musa-companion`): the
//   same gateway on anyone's own machine. Generic project roots, no password
//   pairing (tokens come from the local CLI over SSH, a one-time pairing code,
//   or the owner's linked Musa Control account through the relay), loopback only.
//   Config ~/.config/musa-companion/config.json, data ~/.local/share/musa-companion.
//
// The two never share files, so both can run on one machine. Nothing secret
// lives in config: the workspace password is only ever read as a bcrypt hash.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = os.homedir();
export const expand = (p) => (p && p.startsWith("~") ? path.join(HOME, p.slice(1)) : p);

const defaults = {
  host: "127.0.0.1",
  port: 8160,
  // Public prefix Caddy strips before forwarding (used to build links for web views).
  publicBase: "https://musastudios.co.uk/control",
  dataDir: "~/.local/share/musa-control",
  // Same credential as the workspace sign-in (dashboard auth.js). Read-only.
  passwordHashFile: "/home/dev/caddy/dashboard-password.hash",
  deviceTokenDays: 90,
  // Directories that hold projects (the VPS adds its own, private ones in
  // ~/.config/musa-control/config.json). Every git repository at the given depth
  // becomes a project; `extra` adds non-repo or nested folders by hand.
  roots: [
    { path: "~/workspace/projects", depth: 1, requireGit: false },
    { path: "~", depth: 1, requireGit: true },
    { path: "~/musastudios", depth: 1, requireGit: true },
    { path: "~/firedev-demo", depth: 1, requireGit: true },
  ],
  extra: [
    { path: "~/workspace/platform/dashboard", name: "Musa Dashboard" },
    { path: "~/musa-control", name: "Musa Control" },
  ],
  exclude: [
    "~/workspace", "~/workspace/projects/World Cams", "~/workspace/projects/CitySwing-cleanup",
  ],
  // Public previews already served by Caddy (project directory basename → URLs).
  previews: {
    "CitySwing": [{ label: "Web build", url: "https://musastudios.co.uk/cityswing/" }],
    "NeverStop": [{ label: "Web build", url: "https://musastudios.co.uk/neverstop/" }],
    "Reso": [{ label: "Private beta", url: "https://musastudios.co.uk/reso/" }],
    "portfolio": [{ label: "Portfolio", url: "https://musastudios.co.uk/portfolio/" }],
    "FireDev": [{ label: "FireDev", url: "https://musastudios.co.uk/firedev/" }],
    "orrery-studio": [{ label: "Orrery Studio", url: "https://musastudios.co.uk/orrery/" }],
    "dashboard": [{ label: "Dashboard", url: "https://musastudios.co.uk/" }],
  },
  // Services whose health the Home screen shows.
  services: [
    "vps-dashboard", "caddy", "firedev", "reso-api", "reso-worker", "musa-portfolio", "orrery-api",
    "musa-live-work-xvfb", "musa-live-work-chromium", "musa-live-work-x11vnc", "musa-live-work-websockify",
    "vpn", "ssh", "postgresql@17-main", "docker", "musa-control",
  ],
  // VNC: displays that already have a VNC server (display → port). Other Xvfb
  // displays get an on-demand, localhost-only, view-only x11vnc.
  vnc: { known: { "99": { port: 5901, label: "Live Work browser" } }, spawnPortBase: 5950, idleStopSeconds: 90 },
  noVncDir: "/usr/share/novnc",
  claudeProjectsDir: "~/.claude/projects",
  codexSessionsDir: "~/.codex/sessions",
  claudeBinary: "claude",
  codexBinary: "codex",
  geminiBinary: "gemini",
  geminiDir: "~/.gemini",
  maxManagedAgents: 6,
  watch: { maxProjects: 6, maxDirsPerProject: 5000, textLimitBytes: 600_000, idleMinutes: 30 },
  ignoreDirs: [
    ".git", "node_modules", ".godot", ".import", "build", "dist", "dist-next", ".next", ".cache", "DerivedData",
    "__pycache__", ".venv", "venv", ".gradle", "Pods", "target", ".turbo", "coverage", ".expo", ".svelte-kit",
    "test-results", "playwright-report", ".pytest_cache", ".mypy_cache", "tmp",
  ],
  // Never served or written through the file API, whatever the project.
  secretPatterns: ["(^|/)\\.env($|\\.)", "\\.p8$", "\\.pem$", "\\.key$", "\\.keystore$", "\\.jks$", "id_(rsa|ed25519|ecdsa)$",
    "(^|/)\\.ssh/", "\\.mobileprovision$", "\\.p12$", "credentials\\.json$"],
  githubRepos: [],
  authorizedKeysFile: "~/.ssh/authorized_keys",
  eventsKeep: 100_000,
  revisionsKeep: 25_000,
  screenshotsKeep: 5_000,
};

// Companion defaults: nothing about the Musa Studios VPS. Projects are git
// repositories in the usual places; more can be added in its config file.
const companionDefaults = {
  profile: "companion",
  port: 8170,
  publicBase: null,
  dataDir: "~/.local/share/musa-companion",
  passwordHashFile: null,
  roots: ["~", "~/projects", "~/Projects", "~/code", "~/Code", "~/dev", "~/src", "~/Developer", "~/workspace", "~/repos", "~/git", "~/Documents/GitHub", "~/Documents/Projects"]
    .map((p) => ({ path: p, depth: 1, requireGit: true })),
  extra: [], exclude: [], previews: {}, services: [],
  vnc: { known: {}, spawnPortBase: 5950, idleStopSeconds: 90 },
  // The relay link (optional): set by `musa-companion link <code>`.
  relay: null,
  sshHost: null,
};

// Agents are started through `bash -lc`, whose PATH comes from the login
// profile and does not include nvm (only interactive shells load it), so a
// bare "claude" can be "command not found" there even though it works in a
// terminal. Resolve each binary to an absolute path once, searching the
// gateway's own PATH and the usual install locations.
export function resolveBinary(name) {
  if (!name || name.includes("/")) return expand(name);
  const dirs = [...String(process.env.PATH || "").split(":"), path.join(HOME, ".local/bin"), "/usr/local/bin", "/usr/bin"];
  try {
    const nvm = path.join(HOME, ".nvm/versions/node");
    for (const v of fs.readdirSync(nvm).sort().reverse()) dirs.push(path.join(nvm, v, "bin"));
  } catch {}
  for (const d of dirs) {
    if (!d) continue;
    const f = path.join(d, name);
    try { fs.accessSync(f, fs.constants.X_OK); if (fs.statSync(f).isFile()) return f; } catch {}
  }
  return name;
}

function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over || {})) {
    out[k] = v && typeof v === "object" && !Array.isArray(v) && base[k] && typeof base[k] === "object" && !Array.isArray(base[k]) ? merge(base[k], v) : v;
  }
  return out;
}

export function profileOf(overrides = {}) {
  return overrides.profile || process.env.MUSA_CONTROL_PROFILE || "personal";
}

export function configFile(profile) {
  return expand(process.env.MUSA_CONTROL_CONFIG || (profile === "companion" ? "~/.config/musa-companion/config.json" : "~/.config/musa-control/config.json"));
}

export function loadConfig(overrides = {}) {
  const profile = profileOf(overrides);
  const file = configFile(profile);
  let fromFile = {};
  if (fs.existsSync(file)) fromFile = JSON.parse(fs.readFileSync(file, "utf8"));
  const base = profile === "companion" ? { ...defaults, ...companionDefaults } : { ...defaults, profile: "personal" };
  const cfg = merge(merge(base, fromFile), overrides);
  cfg.profile = profile;
  cfg.configFile = file;
  if (process.env.MUSA_CONTROL_PORT) cfg.port = Number(process.env.MUSA_CONTROL_PORT);
  if (process.env.MUSA_CONTROL_DATA) cfg.dataDir = process.env.MUSA_CONTROL_DATA;
  cfg.dataDir = expand(cfg.dataDir);
  cfg.authorizedKeysFile = expand(cfg.authorizedKeysFile);
  cfg.home = HOME;
  fs.mkdirSync(cfg.dataDir, { recursive: true, mode: 0o700 });
  cfg.secretRegexps = cfg.secretPatterns.map((p) => new RegExp(p, "i"));
  cfg.claudeBinary = resolveBinary(cfg.claudeBinary);
  cfg.codexBinary = resolveBinary(cfg.codexBinary);
  cfg.geminiBinary = resolveBinary(cfg.geminiBinary);
  cfg.platform = process.platform;
  return cfg;
}
