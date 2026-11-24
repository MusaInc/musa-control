import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { isImage } from "./files.js";

const idPattern = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const imagesPerScan = 12;
export const agyRoot = (cfg) => path.join(cfg.geminiDir.replace(/^~(?=\/|$)/, cfg.home), "antigravity-cli");

export function agyArgs({ resume, mode, model, prompt }) {
  const args = [];
  if (resume) {
    if (!idPattern.test(resume)) throw Object.assign(new Error("Invalid Antigravity conversation ID"), { status: 400 });
    args.push("--conversation", resume);
  }
  const modes = { acceptEdits: "accept-edits", plan: "plan", "read-only": "plan" };
  if (modes[mode]) args.push("--mode", modes[mode]);
  if (model) args.push("--model", model);
  if (prompt && !resume) args.push("--prompt-interactive", prompt);
  return args;
}

function query(file, sql, ...args) {
  if (!fs.existsSync(file)) return [];
  const db = new DatabaseSync(file, { readOnly: true });
  try { return db.prepare(sql).all(...args); } finally { db.close(); }
}

function time(value) {
  return Date.parse(String(value || "").replace(" ", "T")) || 0;
}

export function agyConversations(root, since) {
  const cachedWorkspaces = new Map(Object.entries(workspaceCache(root))
    .filter(([cwd, id]) => path.isAbsolute(cwd) && idPattern.test(id))
    .map(([cwd, id]) => [id, cwd]));
  return query(path.join(root, "conversation_summaries.db"), `
    SELECT conversation_id, title, workspace_uris, last_modified_time, status, not_fully_idle, parent_conversation_id
    FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 60
  `).flatMap((r) => {
    if (!idPattern.test(r.conversation_id) || r.parent_conversation_id || time(r.last_modified_time) < since) return [];
    try {
      const uri = r.workspace_uris && JSON.parse(r.workspace_uris)[0];
      const cwd = uri ? fileURLToPath(uri) : cachedWorkspaces.get(r.conversation_id);
      if (!cwd) return [];
      return [{ id: r.conversation_id, cwd, title: clean(r.title, 200), activity: time(r.last_modified_time),
        running: Boolean(r.not_fully_idle) && /RUNNING$/.test(r.status), failed: /ERROR|FAILED/.test(r.status) }];
    } catch { return []; }
  });
}

function workspaceCache(root) {
  try { return JSON.parse(fs.readFileSync(path.join(root, "cache/last_conversations.json"), "utf8")) || {}; }
  catch { return {}; }
}

export function agyWorkspaceConversation(root, cwd) {
  const id = workspaceCache(root)[cwd];
  return idPattern.test(id) ? id : null;
}

export function agyModel(root, pid, args) {
  const explicit = args.match(/--model[= ]([\w.-]+)/)?.[1];
  if (explicit) return explicit;
  // Read only a model label from the log attached to this process. Never send
  // the log itself or use the global cli.log symlink, which other commands rotate.
  try {
    const file = fs.readlinkSync(`/proc/${pid}/fd/1`);
    if (path.dirname(file) !== path.join(root, "log") || !/^cli-[\d_]+\.log$/.test(path.basename(file))) return null;
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const size = fs.fstatSync(fd).size;
      const buf = Buffer.alloc(Math.min(size, 256 * 1024));
      fs.readSync(fd, buf, 0, buf.length, size - buf.length);
      return [...buf.toString().matchAll(/Gemini [\d.]+ (?:Neon|Argon|Hydrogen|Flash) \((?:Low|Medium|High|XHigh|Max)\)/g)].at(-1)?.[0] || null;
    } finally { fs.closeSync(fd); }
  } catch { return null; }
}

// The local Antigravity 1.5 store has protobuf steps, not Gemini CLI JSONL.
// Read only the small known envelopes. Unknown layouts are ignored.
function fields(bytes) {
  const result = new Map();
  if (!bytes?.length) return result;
  let i = 0;
  function varint() {
    let n = 0;
    for (let factor = 1; i < bytes.length && factor < 2 ** 56; factor *= 128) {
      const b = bytes[i++]; n += (b & 127) * factor;
      if (b < 128) return n;
    }
    throw new Error("Invalid protobuf");
  }
  while (i < bytes.length) {
    const tag = varint(), number = Math.floor(tag / 8), wire = tag % 8;
    if (!number) throw new Error("Invalid protobuf field");
    if (wire === 0) { varint(); continue; }
    const length = wire === 2 ? varint() : wire === 1 ? 8 : wire === 5 ? 4 : -1;
    if (length < 0 || i + length > bytes.length) throw new Error("Invalid protobuf length");
    if (wire === 2 && !result.has(number)) result.set(number, Buffer.from(bytes.subarray(i, i + length)));
    i += length;
  }
  return result;
}

export function clean(value, limit = 4000) {
  return String(value || "").slice(0, Math.max(limit * 2, 512))
    .replace(/\x1b\][^\x07]*(?:\x07|$)|\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "")
    .split("\n").map((line) => /\b(?:authorization|bearer|(?:api|access|refresh|oauth)[_-]?(?:key|token|creds)|credential|password|secret|private.key)\b/i.test(line) ||
      /(?:sk-(?:ant-)?[\w-]{12,}|AIza[\w-]{30,}|ya29\.[\w-]{12,}|gh[pousr]_[\w]{20,})/.test(line) ? "[sensitive line omitted]" : line).join("\n").slice(0, limit);
}

export function agySteps(root, id, after) {
  if (!idPattern.test(id)) return [];
  const rows = query(path.join(root, "conversations", id + ".db"), `
    SELECT idx, status, metadata, substr(step_payload,1,2097152) AS payload
    FROM steps WHERE idx>? AND step_type=132 ORDER BY idx DESC LIMIT 80
  `, after).reverse();
  return rows.flatMap((r) => {
    if (!r.status) return [];
    try {
      const meta = fields(r.metadata);
      const call = fields(meta.get(4));
      const tool = call.get(2)?.toString();
      if (!/^[a-zA-Z0-9_]{2,64}$/.test(tool || "")) return [];
      const args = JSON.parse(call.get(3)?.toString() || "{}");
      if (!(args && typeof args === "object")) return [];
      let out;
      try { out = fields(fields(fields(r.payload).get(140)).get(2)).get(1)?.toString(); } catch {}
      const output = clean(out, 2800);
      return [{ index: r.idx, tool, command: clean(args.CommandLine), cwd: args.Cwd,
        file: args.TargetFile || args.AbsolutePath || args.FilePath || args.Path,
        description: clean(args.Description || args.toolSummary, 200), output,
        failed: /\b(?:exit code|exit status):?\s+[1-9]\d*/i.test(output) }];
    } catch { return []; }
  });
}

export function createAgyImages(root, screenshots) {
  const seen = new Map();
  return async function scan(session) {
    if (!screenshots || !idPattern.test(session.sessionId)) return;
    const dir = path.join(root, "brain", session.sessionId, "scratch");
    if (fs.realpathSync(dir, { throwIfNoEntry: false }) !== dir) return;
    const pending = [];
    let visited = 0;
    function walk(folder, depth) {
      if (depth > 8 || visited >= 3000) return;
      for (const e of fs.readdirSync(folder, { withFileTypes: true })) {
        if (++visited >= 3000) break;
        if (e.name.startsWith(".")) continue;
        const f = path.join(folder, e.name);
        if (e.isDirectory()) { walk(f, depth + 1); continue; }
        if (!e.isFile() || !isImage(f)) continue;
        const st = fs.statSync(f, { throwIfNoEntry: false });
        if (st && st.size >= 2000 && Date.now() - st.mtimeMs > 700 && seen.get(f) !== st.mtimeMs)
          pending.push({ f, mtime: st.mtimeMs });
      }
    }
    walk(dir, 0);
    for (const { f, mtime } of pending.sort((a,b) => b.mtime - a.mtime).slice(0, imagesPerScan)) {
      const row = await screenshots.consider(f, { project: session.project, session: session.key, source: "antigravity", ts: mtime, requireDimensions: true });
      if (row) seen.set(f, mtime);
    }
    if (seen.size > 6000) seen.delete(seen.keys().next().value);
  };
}
