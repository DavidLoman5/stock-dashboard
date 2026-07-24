"""One-off migration for THIS deployment's DB: lots -> shares.

Why this exists instead of just letting db.lots_to_shares() run:

The `lots` column meant lots for the owner (1, 1, 1, 1, 2 - real 張數), but the guest account
had typed share counts into the field the UI labelled 張數 (0050:2000, 2330:15, 2337:1000 - a
plain ×1000 would have turned that into two million shares of 0050). So the conversion factor
is per-user and cannot be inferred from the data. It is recorded here, applied once, and after
that db.lots_to_shares() finds no `lots` column and does nothing.

    python3 -m server.migrate_shares            dry run, prints the plan
    python3 -m server.migrate_shares --apply    do it

Stop the service first: the running process queries `lots` and this drops that column.
"""

import os
import shutil
import sqlite3
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = "server"

from . import config, db  # noqa: E402

# usernames whose numbers are already share counts and must be carried over untouched
ALREADY_SHARES = ("yianchen960630",)


def plan(conn):
    rows = conn.execute(
        "SELECT u.username, u.tier, h.code, h.lots FROM holdings h JOIN users u ON u.id = h.user_id "
        "ORDER BY u.username, h.code"
    ).fetchall()
    out = []
    for r in rows:
        factor = 1 if r["username"] in ALREADY_SHARES else 1000
        out.append((r["username"], r["code"], r["lots"], r["lots"] * factor, factor))
    return out


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    apply_it = "--apply" in argv
    cfg = config.load()
    path = cfg["dbPath"]
    conn = db.connect(path)
    conn.row_factory = sqlite3.Row

    if "lots" not in {r["name"] for r in conn.execute("PRAGMA table_info(holdings)")}:
        print("holdings 已經沒有 lots 欄位——這個 DB 早就 migrate 過了，不用再跑")
        return 0

    for username, code, lots, shares, factor in plan(conn):
        print("  %-16s %-7s %8s -> %10s  (x%d)" % (username, code, lots, shares, factor))
    n_trades = conn.execute("SELECT COUNT(*) AS n FROM trades").fetchone()["n"]
    print("  trades: %d 筆" % n_trades)

    if not apply_it:
        print("\n[dry run] 加 --apply 才會真的改。先確認上面每一列的數字。")
        return 0

    backup = path + ".pre-shares"
    with sqlite3.connect(backup) as dst:      # sqlite backup API: WAL-safe, unlike cp
        conn.backup(dst)
    shutil.copystat(path, backup) if os.path.exists(path) else None
    os.chmod(backup, 0o600)
    print("\n備份: %s" % backup)

    placeholders = ",".join("?" * len(ALREADY_SHARES))
    for table in ("holdings", "trades"):
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(%s)" % table)}
        if "lots" not in cols:
            continue
        if "shares" not in cols:
            conn.execute("ALTER TABLE %s ADD COLUMN shares INTEGER NOT NULL DEFAULT 0" % table)
        conn.execute(
            "UPDATE {t} SET shares = CAST(lots * 1000 AS INTEGER) "
            "WHERE user_id NOT IN (SELECT id FROM users WHERE username IN ({p}))".format(
                t=table, p=placeholders),
            ALREADY_SHARES)
        conn.execute(
            "UPDATE {t} SET shares = CAST(lots AS INTEGER) "
            "WHERE user_id IN (SELECT id FROM users WHERE username IN ({p}))".format(
                t=table, p=placeholders),
            ALREADY_SHARES)
        conn.execute("ALTER TABLE %s DROP COLUMN lots" % table)
    conn.commit()

    print("\n完成。migrate 後：")
    for r in conn.execute(
        "SELECT u.username, h.code, h.shares FROM holdings h JOIN users u ON u.id = h.user_id "
        "ORDER BY u.username, h.code"
    ):
        print("  %-16s %-7s %10s 股" % (r["username"], r["code"], r["shares"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
