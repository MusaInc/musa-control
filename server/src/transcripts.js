// Pure parsers: one transcript line (Claude Code ~/.claude/projects/*.jsonl or
// Codex ~/.codex/sessions/**/*.jsonl) → normalized activity events.
//
// Each event: { kind, title, detail, follow?, key, ts, persist? }
//   follow = what a visual panel can genuinely show for it:
//     {view:"file", path} | {view:"diff", path} | {view:"screenshot", path}
//     {view:"vnc"} | {view:"preview", url?} | {view:"tests"} | {view:"activity"}
const IMAGE = /\.(png|jpe?g|webp|gif)$/i;
const TEST_CMD = /\b(npm (run )?test|pnpm test|yarn test|pytest|jest|vitest|playwright test|go test|cargo test|swift test|xcodebuild test|run_tests\.gd|node --test|npm run check|ctest)\b/;
const PREVIEW_CMD = /\b(http\.server|npm run (dev|start|preview|serve)|vite( |$)|next dev|serve -|python3? -m http|live-server|godot .*--export.*web)\b/;
const BROWSER_TOOL = /chrome|playwright|browser|computer|screenshot|puppeteer|cdp/i;
const SCREENSHOT_CMD = /(screenshot|--shot|capture|filmstrip|import -window|scrot|grim)/i;

const short = (s, n = 160) => { const t = String(s ?? "").replace(/<\/?pasted_content[^>]*>/g, " ").replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n - 1) + "…" : t; };
const imagePathsIn = (s) => [...String(s || "").matchAll(/(\/(?:home|tmp|srv)\/[^\s'"`<>|;]+?\.(?:png|jpe?g|webp))/gi)].map((m) => m[1]);

function commandEvent(command, extra, key, ts) {
  const isTest = TEST_CMD.test(command), isPreview = PREVIEW_CMD.test(command);
  return {
    kind: isTest ? "agent.test" : "agent.command", key, ts,
    title: (isTest ? "Running tests: " : "$ ") + short(command, 140),
    detail: { command: String(command).slice(0, 4000), ...extra },
    follow: isTest ? { view: "tests" } : isPreview ? { view: "preview" } : { view: "activity" },
  };
}

// ---------------- Claude Code ----------------
export function parseClaudeLine(line, state = {}) {
  let e;
  try { e = JSON.parse(line); } catch { return []; }
  const out = [];
  const ts = e.timestamp ? Date.parse(e.timestamp) : Date.now();
  if (e.cwd && !state.cwd) state.cwd = e.cwd;
  if (e.sessionId && !state.sessionId) state.sessionId = e.sessionId;
  if (e.gitBranch) state.branch = e.gitBranch;
  const sidechain = Boolean(e.isSidechain);
  if (e.type === "user" && e.message) {
    const c = e.message.content;
    if (typeof c === "string") {
      if (!e.isMeta && !c.startsWith("<") && c.trim()) {
        state.lastPrompt = c; state.title = state.title || short(c, 90); state.turn = "working";
        out.push({ kind: "agent.prompt", key: e.uuid, ts, title: short(c, 200), detail: { text: c.slice(0, 20000), sidechain } });
      }
    } else if (Array.isArray(c)) {
      for (const b of c) {
        if (b.type === "text" && !e.isMeta && b.text && !b.text.startsWith("<") && !sidechain) {
          state.lastPrompt = b.text; state.title = state.title || short(b.text, 90); state.turn = "working";
          out.push({ kind: "agent.prompt", key: e.uuid + ":t", ts, title: short(b.text, 200), detail: { text: b.text.slice(0, 20000) } });
        }
        if (b.type === "image" && !sidechain) out.push({ kind: "agent.prompt", key: e.uuid + ":img", ts, title: "Image attached to the prompt", detail: { image: true } });
        if (b.type === "tool_result" && state.pending?.[b.tool_use_id]) {
          const p = state.pending[b.tool_use_id]; delete state.pending[b.tool_use_id];
          let text = b.content; if (Array.isArray(text)) text = text.map((x) => x.text || "").join("\n");
          if (p.kind === "command") {
            out.push({ kind: b.is_error ? "agent.command_failed" : "agent.command_done", key: b.tool_use_id + ":r", ts, persist: Boolean(b.is_error) || p.test,
              title: `${b.is_error ? "Failed" : "Finished"}: ${short(p.command, 120)}`, detail: { command: p.command, output: String(text || "").slice(-6000), ok: !b.is_error, test: p.test },
              follow: p.test ? { view: "tests" } : { view: "activity" } });
            for (const img of imagePathsIn(text)) if (SCREENSHOT_CMD.test(p.command) || IMAGE.test(img)) out.push({ kind: "agent.image", key: b.tool_use_id + ":" + img, ts, title: `Captured ${img.split("/").pop()}`, detail: { path: img, via: "command" }, follow: { view: "screenshot", path: img } });
          }
        }
      }
    }
  } else if (e.type === "assistant" && e.message?.content) {
    if (e.isApiErrorMessage) out.push({ kind: "agent.error", key: e.uuid, ts, title: "API error", detail: { text: JSON.stringify(e.message.content).slice(0, 2000) } });
    if (e.message.model) state.model = e.message.model;
    for (const [i, b] of e.message.content.entries()) {
      const key = `${e.uuid}:${i}`;
      if (b.type === "text" && b.text?.trim()) {
        state.lastMessage = b.text;
        out.push({ kind: "agent.message", key, ts, title: short(b.text, 200), detail: { text: b.text.slice(0, 20000), sidechain } });
      } else if (b.type === "tool_use") {
        const name = b.name, inp = b.input || {};
        state.pending = state.pending || {};
        state.turn = "working";
        if (name === "Bash") {
          const ev = commandEvent(inp.command || "", { description: inp.description || null, tool: "Bash" }, b.id, ts);
          state.pending[b.id] = { kind: "command", command: inp.command || "", test: ev.kind === "agent.test" };
          out.push(ev);
        } else if (["Edit", "MultiEdit", "Write", "NotebookEdit"].includes(name) && (inp.file_path || inp.notebook_path)) {
          const p = inp.file_path || inp.notebook_path;
          const edits = name === "Edit" ? [{ old: inp.old_string, new: inp.new_string }] : name === "MultiEdit" ? (inp.edits || []).map((x) => ({ old: x.old_string, new: x.new_string })) : null;
          out.push({ kind: "agent.edit", key, ts, title: `${name === "Write" ? "Wrote" : "Edited"} ${p.split("/").pop()}`,
            detail: { path: p, tool: name, edits: edits?.slice(0, 20).map((x) => ({ old: String(x.old ?? "").slice(0, 6000), new: String(x.new ?? "").slice(0, 6000) })), bytes: name === "Write" ? String(inp.content || "").length : null },
            follow: { view: "diff", path: p } });
        } else if (name === "Read" && inp.file_path) {
          if (IMAGE.test(inp.file_path)) out.push({ kind: "agent.image", key, ts, title: `Viewed ${inp.file_path.split("/").pop()}`, detail: { path: inp.file_path, via: "read" }, follow: { view: "screenshot", path: inp.file_path } });
          else out.push({ kind: "agent.read", key, ts, persist: false, title: `Reading ${inp.file_path.split("/").pop()}`, detail: { path: inp.file_path }, follow: { view: "file", path: inp.file_path } });
        } else if (name === "TodoWrite") {
          out.push({ kind: "agent.plan", key, ts, title: "Updated plan", detail: { items: (inp.todos || []).map((t) => ({ text: t.content, status: t.status })) } });
        } else {
          const browser = BROWSER_TOOL.test(name);
          out.push({ kind: "agent.tool", key, ts, persist: !["Grep", "Glob", "LS", "ToolSearch"].includes(name),
            title: `${name}${inp.description ? ": " + short(inp.description, 100) : inp.pattern ? " " + short(inp.pattern, 80) : inp.url ? " " + short(inp.url, 100) : ""}`,
            detail: { tool: name, input: short(JSON.stringify(inp), 600) }, follow: browser ? { view: "vnc" } : { view: "activity" } });
        }
      }
    }
  } else if (e.type === "system" && e.subtype === "turn_duration") {
    state.turn = "idle";
    out.push({ kind: "agent.done", key: e.uuid, ts, title: `Turn finished (${Math.round((e.durationMs || 0) / 1000)} s)`, detail: { durationMs: e.durationMs, last: short(state.lastMessage, 400) } });
  } else if (e.type === "last-prompt" && e.lastPrompt) {
    state.lastPrompt = state.lastPrompt || e.lastPrompt;
  }
  return out;
}

// ---------------- Codex ----------------
const fileUrl = (p) => (String(p || "").startsWith("file://") ? decodeURIComponent(String(p).slice(7)) : String(p || ""));
const codexText = (content) => (Array.isArray(content) ? content.map((c) => c.text || "").join("\n") : String(content || ""));

export function parseCodexLine(line, state = {}) {
  let e;
  try { e = JSON.parse(line); } catch { return []; }
  const p = e.payload || {};
  const ts = e.timestamp ? Date.parse(e.timestamp) : Date.now();
  const key = `${e.ordinal ?? ""}:${p.id || p.item?.id || ""}:${p.type || e.type}`;
  const out = [];
  if (e.type === "session_meta") {
    state.cwd = p.cwd; state.sessionId = p.id || p.session_id; state.originator = p.originator; state.version = p.cli_version;
    return out;
  }
  if (e.type === "turn_context" && p.cwd) state.cwd = state.cwd || p.cwd;
  if (e.type === "event_msg" && p.type === "thread_settings_applied") state.model = p.thread_settings?.model || state.model;
  if (e.type !== "event_msg") return out;
  if (p.type === "task_started") { state.turn = "working"; return out; }
  if (p.type === "task_complete") {
    state.turn = "idle";
    out.push({ kind: "agent.done", key, ts, title: "Task complete", detail: { last: short(p.last_agent_message, 400) } });
    return out;
  }
  if (p.type === "turn_aborted") { state.turn = "idle"; out.push({ kind: "agent.stopped", key, ts, title: `Turn ${p.reason || "aborted"}`, detail: { reason: p.reason } }); return out; }
  if (p.type === "error" || p.type === "stream_error") { out.push({ kind: "agent.error", key, ts, title: short(p.message || "Codex error", 200), detail: { message: p.message } }); return out; }
  if (p.type !== "item_completed" || !p.item) return out;
  const it = p.item;
  switch (it.type) {
    case "UserMessage": {
      const t = codexText(it.content);
      if (t.trim()) { state.lastPrompt = t; state.title = state.title || short(t, 90); out.push({ kind: "agent.prompt", key, ts, title: short(t, 200), detail: { text: t.slice(0, 20000) } }); }
      break;
    }
    case "AgentMessage": {
      const t = codexText(it.content);
      if (t.trim()) { state.lastMessage = t; out.push({ kind: "agent.message", key, ts, title: short(t, 200), detail: { text: t.slice(0, 20000), phase: it.phase } }); }
      break;
    }
    case "CommandExecution": {
      const cmd = Array.isArray(it.command) ? (it.command[0]?.endsWith("bash") && it.command[1] === "-lc" ? it.command.slice(2).join(" ") : it.command.join(" ")) : String(it.command || "");
      const code = it.exit_code === undefined || it.exit_code === null ? null : Number(it.exit_code);
      const ev = commandEvent(cmd, { exitCode: code, output: String(it.aggregated_output || "").slice(-6000), cwd: fileUrl(it.cwd), ok: code === 0 }, key, ts);
      if (code !== null && code !== 0) { ev.title = `Failed (${code}): ${short(cmd, 120)}`; if (ev.kind === "agent.command") ev.kind = "agent.command_failed"; }
      out.push(ev);
      for (const img of imagePathsIn(it.aggregated_output)) if (SCREENSHOT_CMD.test(cmd)) out.push({ kind: "agent.image", key: key + ":" + img, ts, title: `Captured ${img.split("/").pop()}`, detail: { path: img, via: "command" }, follow: { view: "screenshot", path: img } });
      break;
    }
    case "FileChange": {
      for (const [path, ch] of Object.entries(it.changes || {})) {
        out.push({ kind: "agent.edit", key: key + ":" + path, ts, title: `${ch.type === "add" ? "Created" : ch.type === "delete" ? "Deleted" : "Edited"} ${path.split("/").pop()}`,
          detail: { path, change: ch.type, diff: ch.unified_diff ? String(ch.unified_diff).slice(0, 60000) : null, bytes: ch.content ? String(ch.content).length : null },
          follow: { view: "diff", path } });
      }
      break;
    }
    case "ImageView": {
      const path = fileUrl(it.path);
      out.push({ kind: "agent.image", key, ts, title: `Viewed ${path.split("/").pop()}`, detail: { path, via: "view" }, follow: { view: "screenshot", path } });
      break;
    }
    case "McpToolCall": {
      const name = `${it.server || "mcp"}.${it.tool || "tool"}`;
      out.push({ kind: "agent.tool", key, ts, title: `${name}`, detail: { tool: name, input: short(JSON.stringify(it.arguments || {}), 600) }, follow: BROWSER_TOOL.test(name) ? { view: "vnc" } : { view: "activity" } });
      break;
    }
    case "Extension": {
      if (it.kind === "clock.sleep") break;
      out.push({ kind: "agent.tool", key, ts, persist: it.kind !== "web.search" ? false : true, title: it.kind === "web.search" ? `Web search: ${short(it.query, 120)}` : String(it.kind), detail: { tool: it.kind } });
      break;
    }
    default: break;
  }
  return out;
}
