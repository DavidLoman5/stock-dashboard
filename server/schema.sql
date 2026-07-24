-- Multi-user schema for the dashboard server.
-- Design notes that matter for security:
--   * sessions store only the SHA-256 of the token, so a DB leak cannot be replayed as a login
--   * users.status defaults to 'pending': a fresh registration can see nothing until the owner
--     approves it, and every request re-checks this column so suspension is immediate
--   * invites store only the SHA-256 of the code, same reasoning as sessions

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  username      TEXT NOT NULL UNIQUE,
  -- what the page greets you with. username stays the login id (no spaces, no case games);
  -- this one is free text so it can be a real name. Empty = fall back to username.
  display_name  TEXT NOT NULL DEFAULT '',
  pw_hash       TEXT NOT NULL,
  pw_salt       TEXT NOT NULL,
  tier          TEXT NOT NULL DEFAULT 'guest' CHECK (tier IN ('owner','guest')),
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','suspended')),
  note          TEXT NOT NULL DEFAULT '',
  reg_ip        TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  approved_at   TEXT,
  approved_by   INTEGER REFERENCES users(id) ON DELETE SET NULL,
  last_login_at TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
  token_sha256 TEXT PRIMARY KEY,
  user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  expires_at   TEXT NOT NULL,
  ip           TEXT NOT NULL DEFAULT '',
  ua           TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS invites (
  code_sha256 TEXT PRIMARY KEY,
  created_by  INTEGER REFERENCES users(id) ON DELETE SET NULL,
  created_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  used_by     INTEGER REFERENCES users(id) ON DELETE SET NULL,
  used_at     TEXT
);

-- 1 lot = 1000 shares, matching holdings.json. lots is the personal part; quotes for `code`
-- are shared across all users and live in data/quotes.json.
CREATE TABLE IF NOT EXISTS holdings (
  user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code      TEXT NOT NULL,
  name      TEXT NOT NULL DEFAULT '',
  lots      INTEGER NOT NULL DEFAULT 1,
  type      TEXT NOT NULL DEFAULT '',
  theme     TEXT NOT NULL DEFAULT '',
  tech_like INTEGER NOT NULL DEFAULT 0,
  color     TEXT,
  PRIMARY KEY (user_id, code)
);

CREATE TABLE IF NOT EXISTS trades (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  d       TEXT NOT NULL,
  side    TEXT NOT NULL CHECK (side IN ('buy','sell')),
  code    TEXT NOT NULL,
  lots    REAL NOT NULL,
  price   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trades_user ON trades(user_id, d);

-- login throttling and registration flood control both read this table
CREATE TABLE IF NOT EXISTS login_attempts (
  ip       TEXT NOT NULL,
  username TEXT NOT NULL DEFAULT '',
  ts       TEXT NOT NULL,
  ok       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_attempts_ts ON login_attempts(ts);

CREATE TABLE IF NOT EXISTS audit (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts      TEXT NOT NULL,
  user_id INTEGER,
  action  TEXT NOT NULL,
  detail  TEXT NOT NULL DEFAULT ''
);
