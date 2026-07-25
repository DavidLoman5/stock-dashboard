"""sqlite3 access layer. Every query here is parameterized - no string interpolation of
user input into SQL, ever.

Connections are thread-local because ThreadingHTTPServer serves each request on its own
thread and sqlite3 connections are not shareable across threads by default.
"""

import os
import sqlite3
import threading
from datetime import datetime, timezone

_local = threading.local()
SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def now():
    """UTC ISO-8601 with second precision. Stored as TEXT so it sorts lexicographically."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(db_path):
    parent = os.path.dirname(db_path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def get(db_path):
    """Thread-local connection, opened on first use in each thread."""
    cache = getattr(_local, "conns", None)
    if cache is None:
        cache = _local.conns = {}
    conn = cache.get(db_path)
    if conn is None:
        conn = cache[db_path] = connect(db_path)
    return conn


def close_all():
    for conn in getattr(_local, "conns", {}).values():
        conn.close()
    _local.conns = {}


# Columns added to an existing table after first release. CREATE TABLE IF NOT EXISTS does
# nothing to a DB that already exists, so new columns have to be applied by hand. Each entry
# must be nullable or carry a default, and adding one twice is a no-op.
MIGRATIONS = [
    ("users", "display_name", "TEXT NOT NULL DEFAULT ''"),
]


def _columns(conn, table):
    return {r["name"] for r in conn.execute("PRAGMA table_info(%s)" % table)}


def lots_to_shares(conn):
    """Quantities used to be lots (1 lot = 1000 shares); they are now shares, so odd-lot
    positions are representable. CREATE TABLE IF NOT EXISTS does nothing to an existing DB and
    the MIGRATIONS table above only adds columns, so this one has to move the data itself.

    Idempotent: it keys off `lots` still existing, and drops it once the values are carried over,
    which leaves migrated and freshly-created DBs with the identical shape.
    """
    for table in ("holdings", "trades"):
        cols = _columns(conn, table)
        if "lots" not in cols:
            continue
        if "shares" not in cols:
            conn.execute("ALTER TABLE %s ADD COLUMN shares INTEGER NOT NULL DEFAULT 0" % table)
        conn.execute("UPDATE %s SET shares = CAST(lots * 1000 AS INTEGER)" % table)
        conn.execute("ALTER TABLE %s DROP COLUMN lots" % table)


def migrate_tier_check(conn):
    """CHECK constraints are baked into the table at CREATE time, so CREATE TABLE IF NOT EXISTS
    (in schema.sql) does nothing to add 'guest_plus' to an existing DB's tier CHECK - the whole
    table has to be rebuilt. Explicit ids are copied over (not re-assigned), so every foreign
    key elsewhere (sessions/holdings/trades/audit) keeps pointing at the same account; the
    autoincrement counter is repaired afterwards since explicit-id inserts do not advance it.
    """
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'users'"
    ).fetchone()
    if row is None or "guest_plus" in row["sql"]:
        return
    conn.execute("PRAGMA foreign_keys = OFF")
    conn.executescript(
        "ALTER TABLE users RENAME TO users_pre_guest_plus;"
        "CREATE TABLE users ("
        "  id            INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  username      TEXT NOT NULL UNIQUE,"
        "  display_name  TEXT NOT NULL DEFAULT '',"
        "  pw_hash       TEXT NOT NULL,"
        "  pw_salt       TEXT NOT NULL,"
        "  tier          TEXT NOT NULL DEFAULT 'guest' CHECK (tier IN ('owner','guest','guest_plus')),"
        "  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','suspended')),"
        "  note          TEXT NOT NULL DEFAULT '',"
        "  reg_ip        TEXT NOT NULL DEFAULT '',"
        "  created_at    TEXT NOT NULL,"
        "  approved_at   TEXT,"
        "  approved_by   INTEGER REFERENCES users(id) ON DELETE SET NULL,"
        "  last_login_at TEXT"
        ");"
        "INSERT INTO users (id, username, display_name, pw_hash, pw_salt, tier, status, note,"
        "  reg_ip, created_at, approved_at, approved_by, last_login_at)"
        " SELECT id, username, display_name, pw_hash, pw_salt, tier, status, note,"
        "  reg_ip, created_at, approved_at, approved_by, last_login_at FROM users_pre_guest_plus;"
        "DROP TABLE users_pre_guest_plus;"
    )
    conn.execute("DELETE FROM sqlite_sequence WHERE name IN ('users', 'users_pre_guest_plus')")
    max_id = conn.execute("SELECT COALESCE(MAX(id), 0) AS m FROM users").fetchone()["m"]
    if max_id:
        conn.execute(
            "INSERT INTO sqlite_sequence (name, seq) VALUES ('users', ?)", (max_id,)
        )
    conn.execute("PRAGMA foreign_keys = ON")


def init_schema(db_path):
    conn = get(db_path)
    with open(SCHEMA_PATH, "r", encoding="utf-8") as fh:
        conn.executescript(fh.read())
    for table, column, decl in MIGRATIONS:
        if column not in _columns(conn, table):
            conn.execute("ALTER TABLE %s ADD COLUMN %s %s" % (table, column, decl))
    lots_to_shares(conn)
    migrate_tier_check(conn)
    conn.commit()
    # the DB holds other people's portfolios - keep it owner-readable only
    try:
        os.chmod(db_path, 0o600)
    except OSError:
        pass
    return conn


def audit(conn, user_id, action, detail=""):
    conn.execute(
        "INSERT INTO audit (ts, user_id, action, detail) VALUES (?,?,?,?)",
        (now(), user_id, action, detail),
    )
