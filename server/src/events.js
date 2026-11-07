// Event bus + persistent timeline. Every observable change (agent prompt,
// command, file edit, screenshot, build, approval, error) becomes one row,
// streamed live over Server-Sent Events and replayable by id.
//
// kinds: agent.prompt agent.message agent.command agent.edit agent.image
//        agent.tool agent.done agent.error agent.approval agent.started
//        agent.stopped file.changed screenshot.new build.started
//        build.finished git.commit git.push server.alert preview.ready
export function createEvents(db) {
  const insert = db.raw.prepare(
    "INSERT OR IGNORE INTO events(ts,kind,project,session,title,detail,notify,dedupe) VALUES(?,?,?,?,?,?,?,?)");
  const listeners = new Set();

  function emit(ev) {
    const row = {
      ts: ev.ts || Date.now(), kind: ev.kind, project: ev.project || null, session: ev.session || null,
      title: String(ev.title || ev.kind).slice(0, 500), detail: ev.detail || {}, notify: ev.notify ? 1 : 0,
    };
    let id = null;
    if (ev.persist !== false) {
      const r = insert.run(row.ts, row.kind, row.project, row.session, row.title, JSON.stringify(row.detail), row.notify, ev.dedupe || null);
      if (!r.changes) return null; // duplicate (already recorded)
      id = Number(r.lastInsertRowid);
    }
    const out = { id, ...row };
    for (const l of listeners) { try { l(out); } catch (e) { console.error("event listener failed", e); } }
    return out;
  }

  function query({ project, session, kinds, after, before, limit = 200, notify } = {}) {
    const where = [], args = [];
    if (project) { where.push("project=?"); args.push(project); }
    if (session) { where.push("session=?"); args.push(session); }
    if (after) { where.push("id>?"); args.push(Number(after)); }
    if (before) { where.push("id<?"); args.push(Number(before)); }
    if (notify) where.push("notify=1");
    if (kinds?.length) { where.push(`kind IN (${kinds.map(() => "?").join(",")})`); args.push(...kinds); }
    const sql = `SELECT * FROM events ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY id ${after ? "ASC" : "DESC"} LIMIT ?`;
    args.push(Math.min(Number(limit) || 200, 1000));
    const rows = db.raw.prepare(sql).all(...args).map((r) => ({ ...r, detail: JSON.parse(r.detail || "{}") }));
    return after ? rows : rows.reverse();
  }

  function subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); }
  return { emit, query, subscribe };
}
