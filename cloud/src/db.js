// Cloud state: accounts, sessions, machines and their links, push devices
// and the audit log. One SQLite file (0600). Every query that touches a
// user's resources is scoped by user_id here, in one place.
import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import fs from "node:fs";

export function openDb(cfg) {
  const file = path.join(cfg.dataDir, "cloud.sqlite");
  const db = new DatabaseSync(file);
  fs.chmodSync(file, 0o600);
  db.exec(`
    PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY, email TEXT UNIQUE, email_verified INTEGER NOT NULL DEFAULT 0, name TEXT,
      password_hash TEXT, apple_sub TEXT UNIQUE, apple_refresh TEXT,
      created_at INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, token_hash TEXT NOT NULL UNIQUE,
      device_name TEXT, platform TEXT, created_at INTEGER NOT NULL, last_seen INTEGER, last_ip TEXT,
      expires_at INTEGER NOT NULL, revoked_at INTEGER
    );
    CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
    CREATE TABLE IF NOT EXISTS machines (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, name TEXT NOT NULL,
      platform TEXT, hostname TEXT, os_user TEXT, secret_hash TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL, last_seen INTEGER, info TEXT, revoked_at INTEGER
    );
    CREATE INDEX IF NOT EXISTS machines_user ON machines(user_id);
    CREATE TABLE IF NOT EXISTS link_codes (
      code_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, used_at INTEGER, machine_id TEXT
    );
    CREATE TABLE IF NOT EXISTS push_devices (
      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      apns_token TEXT NOT NULL, environment TEXT NOT NULL, prefs TEXT NOT NULL, updated_at INTEGER NOT NULL, last_error TEXT
    );
    CREATE TABLE IF NOT EXISTS audit (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, user_id TEXT, action TEXT NOT NULL,
      ip TEXT, session_id TEXT, machine_id TEXT, detail TEXT
    );
    CREATE INDEX IF NOT EXISTS audit_user ON audit(user_id, id);
  `);
  return {
    raw: db,
    get: (sql, ...a) => db.prepare(sql).get(...a),
    all: (sql, ...a) => db.prepare(sql).all(...a),
    run: (sql, ...a) => db.prepare(sql).run(...a),
    close: () => db.close(),
  };
}
