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


def init_schema(db_path):
    conn = get(db_path)
    with open(SCHEMA_PATH, "r", encoding="utf-8") as fh:
        conn.executescript(fh.read())
    for table, column, decl in MIGRATIONS:
        if column not in _columns(conn, table):
            conn.execute("ALTER TABLE %s ADD COLUMN %s %s" % (table, column, decl))
    lots_to_shares(conn)
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
