// AI providers on this machine: Claude Code (Anthropic), Codex (OpenAI) and
// Gemini CLI (Google).
//
// * Detection: is the CLI installed, which version, and is it signed in,
//   asked through each CLI's own status command (`claude auth status`,
//   `codex login status`) or, for Gemini, its settings file and the presence
//   (never the contents) of its credential file.
// * Sign-in: always the provider's own login flow, started in a tmux session
//   on this machine (`claude auth login`, `codex login --device-auth`,
//   `gemini`). The app shows that terminal, the sign-in link it prints and a
//   field for pasting the code back. Musa Control never asks for a provider
//   password and never reads, stores or forwards provider session tokens.
// * Optional API keys are kept only on this machine (0600 file in the data
//   dir) and passed to agents that Musa Control launches as environment
//   variables. They're never sent back to the app (only "set, ends in 1a2b").
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { run } from "./exec.js";
import * as tmux from "./tmux.js";
import { resolveBinary, expand } from "./config.js";
import { shq } from "./agents.js";

export const PROVIDERS = {
  claude: { id: "claude", name: "Claude Code", vendor: "Anthropic", plan: "Claude Pro or Max subscription, or an Anthropic API key", package: "@anthropic-ai/claude-code", keyEnv: "ANTHROPIC_API_KEY", keyPattern: /^sk-ant-[\w-]{20,}$/, docs: "https://docs.claude.com/en/docs/claude-code/setup" },
  codex: { id: "codex", name: "Codex", vendor: "OpenAI", plan: "ChatGPT Plus, Pro, Business or Enterprise, or an OpenAI API key", package: "@openai/codex", keyEnv: "OPENAI_API_KEY", keyPattern: /^sk-[\w-]{20,}$/, docs: "https://developers.openai.com/codex/cli" },
  gemini: { id: "gemini", name: "Gemini CLI", vendor: "Google", plan: "Google account (free tier, Google AI Pro/Ultra) or a Gemini API key", package: "@google/gemini-cli", keyEnv: "GEMINI_API_KEY", keyPattern: /^[\w-]{30,}$/, docs: "https://github.com/google-gemini/gemini-cli" },
};
const BIN_KEY = { claude: "claudeBinary", codex: "codexBinary", gemini: "geminiBinary" };
const LOGIN_NAME = /^mc-(login|install)-(claude|codex|gemini)-[0-9a-f]{4}$/;
const URL_RE = /https:\/\/[^\s"'<>│]+/g;

const bad = (msg, status = 400) => Object.assign(new Error(msg), { status });

export function createProviders(cfg, events) {
  const keysFile = path.join(cfg.dataDir, "provider-keys.json");
  let cache = { at: 0, list: null };

  function readKeys() {
    try { return JSON.parse(fs.readFileSync(keysFile, "utf8")); } catch { return {}; }
  }
  function writeKeys(k) {
    const tmp = keysFile + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(k), { mode: 0o600 });
    fs.renameSync(tmp, keysFile);
  }

  function binary(id) {
    // A configured absolute path wins; otherwise re-resolve each time, as the
    // user may have installed the CLI since the companion started.
    const set = cfg[BIN_KEY[id]];
    if (set && set.includes("/")) { try { fs.accessSync(set, fs.constants.X_OK); return set; } catch {} }
    const b = resolveBinary(path.basename(set || id));
    if (b.includes("/")) cfg[BIN_KEY[id]] = b;
    return b.includes("/") ? b : null;
  }

  async function version(bin) {
    const r = await run(bin, ["--version"], { timeout: 10_000 });
    return r.code === 0 ? (r.stdout.trim().split("\n")[0] || "").replace(/\s*\(.*\)$/, "").slice(0, 60) : null;
  }

  async function authOf(id, bin) {
    if (id === "claude") {
      const r = await run(bin, ["auth", "status"], { timeout: 15_000 });
      try {
        const j = JSON.parse(r.stdout);
        const method = j.authMethod === "claude.ai" ? "Claude subscription" : j.authMethod === "console" || j.apiProvider === "console" ? "Anthropic Console" : j.authMethod || null;
        return { signedIn: Boolean(j.loggedIn), method, detail: j.loggedIn ? null : "Not signed in" };
      } catch {
        return { signedIn: null, method: null, detail: (r.stderr || r.stdout || "Couldn't read sign-in status").trim().split("\n")[0].slice(0, 160) };
      }
    }
    if (id === "codex") {
      const r = await run(bin, ["login", "status"], { timeout: 15_000 });
      const text = `${r.stdout}\n${r.stderr}`.trim();
      const m = text.match(/Logged in using (.+)/i);
      return { signedIn: r.code === 0 && Boolean(m), method: m ? m[1].trim().replace(/^an? /i, "") : null, detail: m ? null : text.split("\n")[0]?.slice(0, 160) || "Not signed in" };
    }
    // Gemini: settings.json says which method was chosen; for Google sign-in
    // the credential file must exist (only its presence is checked).
    const dir = expand(cfg.geminiDir || "~/.gemini");
    let selected = null;
    try { const s = JSON.parse(fs.readFileSync(path.join(dir, "settings.json"), "utf8")); selected = s.security?.auth?.selectedType || s.selectedAuthType || null; } catch {}
    const hasOauth = fs.existsSync(path.join(dir, "oauth_creds.json"));
    const hasKey = Boolean(process.env.GEMINI_API_KEY || readKeys().gemini);
    if (selected === "oauth-personal" || (!selected && hasOauth)) return { signedIn: hasOauth, method: "Google account", detail: hasOauth ? null : "Google sign-in not finished" };
    if (selected === "gemini-api-key") return { signedIn: hasKey, method: "Gemini API key", detail: hasKey ? null : "No GEMINI_API_KEY on this machine" };
    if (selected === "vertex-ai") return { signedIn: null, method: "Vertex AI", detail: "Uses your Google Cloud configuration" };
    return { signedIn: false, method: null, detail: "Not signed in" };
  }

  async function detect(id) {
    const p = PROVIDERS[id];
    const bin = binary(id);
    const keys = readKeys();
    const key = keys[id] ? { set: true, last4: keys[id].slice(-4) } : { set: false };
    if (!bin) return { ...publicInfo(p), installed: false, version: null, auth: { signedIn: false, method: null, detail: "Not installed" }, apiKey: key };
    const [v, auth] = await Promise.all([version(bin), authOf(id, bin).catch((e) => ({ signedIn: null, detail: e.message }))]);
    if (!auth.signedIn && key.set) { auth.signedIn = true; auth.method = auth.method || "API key (saved here)"; }
    return { ...publicInfo(p), installed: true, path: bin, version: v, auth, apiKey: key };
  }

  const publicInfo = (p) => ({ id: p.id, name: p.name, vendor: p.vendor, plan: p.plan, docs: p.docs, package: p.package });

  async function list({ fresh = false } = {}) {
    if (!fresh && cache.list && Date.now() - cache.at < 30_000) return cache.list;
    const out = await Promise.all(Object.keys(PROVIDERS).map((id) => detect(id)));
    cache = { at: Date.now(), list: out };
    return out;
  }

  function need(id) {
    if (!PROVIDERS[id]) throw bad("Unknown provider");
    return PROVIDERS[id];
  }

  // Runs the provider's own sign-in in a tmux session the app can show.
  async function startLogin(id, { method } = {}) {
    need(id);
    const bin = binary(id);
    if (!bin) throw bad(`${PROVIDERS[id].name} isn't installed on this machine yet.`, 409);
    const name = `mc-login-${id}-${crypto.randomBytes(2).toString("hex")}`;
    const args = id === "claude" ? ["auth", "login", ...(method === "console" ? ["--console"] : ["--claudeai"])]
      : id === "codex" ? ["login", "--device-auth"] : [];
    const cmd = [bin, ...args].map((a, i) => (i ? shq(a) : a)).join(" ");
    const env = { NO_BROWSER: "true", BROWSER: "/bin/false" };
    await tmux.newSession(name, cfg.home, `bash -lc ${shq(`export PATH=${shq(path.dirname(bin))}:"$PATH"; ${cmd}; echo; echo '[sign-in finished — you can close this]'; sleep 600`)}`, { width: 160, height: 45, env });
    cache.at = 0;
    events.emit({ kind: "provider.login", title: `Started ${PROVIDERS[id].name} sign-in`, detail: { provider: id, tmux: name } });
    return { tmux: name };
  }

  async function install(id) {
    const p = need(id);
    const npm = resolveBinary("npm");
    if (!npm.includes("/")) throw bad("npm isn't installed on this machine. Install Node.js 22 first.", 409);
    const name = `mc-install-${id}-${crypto.randomBytes(2).toString("hex")}`;
    await tmux.newSession(name, cfg.home, `bash -lc ${shq(`export PATH=${shq(path.dirname(npm))}:"$PATH"; npm install -g ${shq(p.package)}; echo; echo '[install finished]'; sleep 600`)}`, { width: 160, height: 45 });
    cache.at = 0;
    events.emit({ kind: "provider.install", title: `Installing ${p.name}`, detail: { provider: id, tmux: name } });
    return { tmux: name };
  }

  function loginTarget(name) {
    if (!LOGIN_NAME.test(String(name))) throw bad("Not a sign-in session", 404);
    return String(name);
  }

  async function loginState(name) {
    const t = loginTarget(name);
    const screen = await tmux.capture(t, { lines: 80 });
    if (screen === null) return { exists: false };
    const flat = screen;
    const urls = [...new Set((flat.match(URL_RE) || []).map((u) => u.replace(/[.,)]+$/, "")))].slice(-4);
    const code = (flat.match(/\b[A-Z0-9]{4}-[A-Z0-9]{4,5}\b/g) || []).pop() || null;
    const lines = screen.split("\n").map((l) => l.trimEnd()).filter(Boolean);
    const last = lines.slice(-6).join("\n");
    return {
      exists: true, screen: lines.slice(-40).join("\n"), urls, deviceCode: code,
      wantsCode: /paste (the )?code|enter the authori[sz]ation code|authorization code:|code here/i.test(last),
      finished: /\[sign-in finished|\[install finished/.test(last),
    };
  }

  async function loginInput(name, text) {
    const t = loginTarget(name);
    const s = String(text || "").trim();
    if (!s || s.length > 4096 || /[\r\n]/.test(s)) throw bad("Paste just the code");
    await tmux.sendText(t, s);
    cache.at = 0;
    return { ok: true };
  }

  async function endLogin(name) { await tmux.kill(loginTarget(name)); cache.at = 0; return { ok: true }; }

  async function setKey(id, key) {
    const p = need(id);
    const k = String(key || "").trim();
    if (!p.keyPattern.test(k)) throw bad(`That doesn't look like a ${p.vendor} API key.`);
    if (id === "codex") {
      // Codex keeps API keys through its own login command.
      const bin = binary(id);
      if (bin) { const r = await run(bin, ["login", "--with-api-key"], { input: k + "\n", timeout: 30_000 }); if (r.code !== 0) throw bad(`codex login refused the key: ${(r.stderr || r.stdout).trim().slice(0, 200)}`, 422); }
    }
    const keys = readKeys(); keys[id] = k; writeKeys(keys);
    cache.at = 0;
    events.emit({ kind: "provider.key", title: `${p.name} API key saved on this machine`, detail: { provider: id } });
    return { ok: true, last4: k.slice(-4) };
  }

  function deleteKey(id) {
    need(id);
    const keys = readKeys(); delete keys[id]; writeKeys(keys);
    cache.at = 0;
    return { ok: true };
  }

  // Environment for an agent launched from the app: its saved API key, if any.
  function envFor(agent) {
    const p = PROVIDERS[agent];
    const k = p && readKeys()[agent];
    return k ? { [p.keyEnv]: k } : {};
  }

  return { list, startLogin, install, loginState, loginInput, endLogin, setKey, deleteKey, envFor };
}
