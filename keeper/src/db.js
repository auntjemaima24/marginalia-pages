// SQLite state via node:sqlite (DatabaseSync). One file, a handful of tables, no ORM.
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export function openDb(path) {
  mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY,
      author TEXT NOT NULL,
      x TEXT NOT NULL,
      side INTEGER NOT NULL,
      target_bps INTEGER NOT NULL,
      horizon_days INTEGER NOT NULL,
      class INTEGER NOT NULL,
      parent_id TEXT,
      posted_at INTEGER NOT NULL,
      posted_block INTEGER NOT NULL,
      is_thesis INTEGER NOT NULL,
      status INTEGER NOT NULL DEFAULT 0,
      horizon_end INTEGER,
      obs_count INTEGER NOT NULL DEFAULT 0,
      obs_first_ts INTEGER,
      obs_last_block INTEGER,
      settled_at INTEGER,
      last_error TEXT
    );
    CREATE INDEX IF NOT EXISTS notes_status ON notes(status, horizon_end);
    CREATE TABLE IF NOT EXISTS txs (
      hash TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      ref TEXT,
      sent_at INTEGER NOT NULL,
      ok INTEGER,
      gas_used INTEGER,
      note TEXT
    );
    CREATE TABLE IF NOT EXISTS venues (
      id TEXT PRIMARY KEY,
      label TEXT,
      params_json TEXT NOT NULL,
      v4key_json TEXT NOT NULL,
      added_at INTEGER NOT NULL,
      last_checkpoint_at INTEGER,
      last_error TEXT
    );
    CREATE TABLE IF NOT EXISTS weeks (
      week INTEGER PRIMARY KEY,
      requested_at INTEGER,
      request_id TEXT,
      judged INTEGER NOT NULL DEFAULT 0,
      paid INTEGER NOT NULL DEFAULT 0,
      swept INTEGER NOT NULL DEFAULT 0,
      last_error TEXT
    );
    CREATE TABLE IF NOT EXISTS days (
      day INTEGER PRIMARY KEY,
      swept INTEGER NOT NULL DEFAULT 0,
      last_error TEXT
    );
  `);
  return db;
}

export function getMeta(db, k, dflt = null) {
  const r = db.prepare('SELECT v FROM meta WHERE k = ?').get(k);
  return r ? r.v : dflt;
}

export function setMeta(db, k, v) {
  db.prepare('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v').run(k, String(v));
}
