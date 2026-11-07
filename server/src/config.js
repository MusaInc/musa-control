// Gateway configuration. Defaults describe the Musa Studios VPS; an optional
// JSON file (MUSA_CONTROL_CONFIG or ~/.config/musa-control/config.json)
// overrides any key. Nothing secret lives here: the workspace password is
// only ever read as the existing bcrypt hash file.
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
  // Directories that hold projects. Every git repository at the given depth
  // becomes a project; `extra` adds non-repo or nested folders by hand.
  roots: [
    { path: "~/workspace/projects", depth: 1, requireGit: false },
    { path: "~", depth: 1, requireGit: true },
    { path: "/srv/projects", depth: 1, requireGit: true },
    { path: "~/musastudios", depth: 1, requireGit: true },
    { path: "~/firedev-demo", depth: 1, requireGit: true },
  ],
  extra: [
    { path: "~/workspace/platform/dashboard", name: "Musa Dashboard" },
    { path: "~/musa-control", name: "Musa Control" },
  ],
  exclude: [
    "~/workspace", "~/workspace/projects/World Cams", "~/workspace/projects/CitySwing-cleanup",
    "~/sample-push", "~/sample-ready",
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

export function loadConfig(overrides = {}) {
  const file = expand(process.env.MUSA_CONTROL_CONFIG || "~/.config/musa-control/config.json");
  let fromFile = {};
  if (fs.existsSync(file)) fromFile = JSON.parse(fs.readFileSync(file, "utf8"));
  const cfg = merge(merge(defaults, fromFile), overrides);
  if (process.env.MUSA_CONTROL_PORT) cfg.port = Number(process.env.MUSA_CONTROL_PORT);
  if (process.env.MUSA_CONTROL_DATA) cfg.dataDir = process.env.MUSA_CONTROL_DATA;
  cfg.dataDir = expand(cfg.dataDir);
  cfg.authorizedKeysFile = expand(cfg.authorizedKeysFile);
  cfg.home = HOME;
  fs.mkdirSync(cfg.dataDir, { recursive: true, mode: 0o700 });
  cfg.secretRegexps = cfg.secretPatterns.map((p) => new RegExp(p, "i"));
  cfg.claudeBinary = resolveBinary(cfg.claudeBinary);
  cfg.codexBinary = resolveBinary(cfg.codexBinary);
  return cfg;
}
