// Persistent gateway state: device tokens, the session timeline, file
// revisions and screenshots. One SQLite file, bounded by pruning.
import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import fs from "node:fs";

export function openDb(cfg) {
  const file = path.join(cfg.dataDir, "control.sqlite");
  const db = new DatabaseSync(file);
  fs.chmodSync(file, 0o600);
  db.exec(`
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL, last_seen INTEGER, expires_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL,
      project TEXT, session TEXT, title TEXT NOT NULL, detail TEXT, notify INTEGER NOT NULL DEFAULT 0,
      dedupe TEXT UNIQUE
    );
    CREATE INDEX IF NOT EXISTS events_project ON events(project, id);
    CREATE INDEX IF NOT EXISTS events_session ON events(session, id);
    CREATE INDEX IF NOT EXISTS events_notify ON events(notify, id);
    CREATE TABLE IF NOT EXISTS revisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT, project TEXT NOT NULL, path TEXT NOT NULL, ts INTEGER NOT NULL,
      sha TEXT NOT NULL, size INTEGER NOT NULL, content BLOB, source TEXT NOT NULL, session TEXT,
      added INTEGER, removed INTEGER
    );
    CREATE INDEX IF NOT EXISTS revisions_file ON revisions(project, path, id);
    CREATE TABLE IF NOT EXISTS screenshots (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, project TEXT, session TEXT,
      path TEXT NOT NULL UNIQUE, width INTEGER, height INTEGER, bytes INTEGER, source TEXT NOT NULL,
      note TEXT
    );
    CREATE INDEX IF NOT EXISTS screenshots_project ON screenshots(project, id);
    CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS managed_agents (
      id TEXT PRIMARY KEY, agent TEXT NOT NULL, project TEXT NOT NULL, cwd TEXT NOT NULL, tmux TEXT NOT NULL,
      session_id TEXT, created_at INTEGER NOT NULL, title TEXT, ended_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS builds (
      id TEXT PRIMARY KEY, project TEXT NOT NULL, command TEXT NOT NULL, label TEXT NOT NULL, tmux TEXT NOT NULL,
      log TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER, exit_code INTEGER
    );
  `);
  const kvGet = db.prepare("SELECT v FROM kv WHERE k=?");
  const kvSet = db.prepare("INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v");
  return {
    raw: db,
    get: (k, d = null) => { const r = kvGet.get(k); return r ? JSON.parse(r.v) : d; },
    set: (k, v) => kvSet.run(k, JSON.stringify(v)),
    prune() {
      db.prepare("DELETE FROM events WHERE id <= (SELECT MAX(id) FROM events) - ?").run(cfg.eventsKeep);
      db.prepare("DELETE FROM revisions WHERE id <= (SELECT MAX(id) FROM revisions) - ?").run(cfg.revisionsKeep);
      db.prepare("DELETE FROM screenshots WHERE id <= (SELECT MAX(id) FROM screenshots) - ?").run(cfg.screenshotsKeep);
    },
    close: () => db.close(),
  };
}
