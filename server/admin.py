"""Command-line administration - the same operations the /admin page offers, for when there is
no browser handy, plus the two exports the daily pipeline consumes.

  python3 -m server.admin init                 create DB + first owner account
  python3 -m server.admin users                list accounts (pending first)
  python3 -m server.admin approve <user>       let a pending account in
  python3 -m server.admin reject <user>        delete a pending registration
  python3 -m server.admin suspend <user>       block immediately (kills their sessions)
  python3 -m server.admin resume <user>
  python3 -m server.admin delete <user>
  python3 -m server.admin passwd <user>
  python3 -m server.admin rename <user> "顯示名稱"   頁面上顯示的名字（登入帳號不變）
  python3 -m server.admin invite               one-time registration code
  python3 -m server.admin import-holdings <holdings.json> <user>
  python3 -m server.admin export-codes         -> data/active-codes.json   (for screen/update)
  python3 -m server.admin export-owner         -> data/owner-holdings.json (owner only)
"""

import getpass
import json
import os
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = "server"

from . import auth, config, db, payload, validate  # noqa: E402


def _conn(cfg):
    return db.init_schema(cfg["dbPath"])


def _resolve(conn, ident):
    row = conn.execute(
        "SELECT * FROM users WHERE username = ? COLLATE NOCASE OR CAST(id AS TEXT) = ?",
        (ident, ident),
    ).fetchone()
    if row is None:
        sys.exit("找不到帳號: %s" % ident)
    return row


def _ask_password(prompt="密碼", allow_weak=False):
    pw = getpass.getpass("%s: " % prompt)
    if pw != getpass.getpass("再輸入一次: "):
        sys.exit("兩次輸入不一致")
    return _check_password(pw, allow_weak)


def _check_password(pw, allow_weak=False):
    """The web sign-up path always enforces validate.password(). This local CLI lets the
    machine's owner opt out for their own account with --allow-weak - deliberately explicit,
    never silent, and it does not change the minimum for anyone registering through the site."""
    if allow_weak:
        if not pw:
            sys.exit("密碼不可為空")
        if len(pw) < validate.MIN_PASSWORD:
            sys.stderr.write(
                "WARNING: 密碼只有 %d 個字元（站台標準是 %d）。這個帳號是管理者，可以核准/停用\n"
                "         帳號並看到完整資料。對外開放（Cloudflare Tunnel）之前請換成長密碼。\n"
                % (len(pw), validate.MIN_PASSWORD)
            )
        return pw
    try:
        return validate.password(pw)
    except validate.Invalid as exc:
        sys.exit("%s（若確定要用短密碼，加上 --allow-weak）" % exc)


def cmd_init(cfg, conn, args):
    existing = conn.execute("SELECT COUNT(*) AS n FROM users WHERE tier = 'owner'").fetchone()
    if existing["n"]:
        sys.exit("已經有 owner 帳號了，不需要再 init")
    username = args[0] if args else input("owner 帳號名稱: ").strip()
    password = _ask_password()
    user_id = auth.create_user(
        conn, username, password, tier="owner", status="active", note="owner"
    )
    print("建立 owner 帳號 %s (id=%d)" % (username, user_id))
    print("DB: %s" % cfg["dbPath"])
    print("接著可執行: python3 -m server.server")


def cmd_users(cfg, conn, args):
    rows = conn.execute(
        "SELECT u.id, u.username, u.tier, u.status, u.created_at, u.last_login_at, u.note, "
        "  (SELECT COUNT(*) FROM holdings h WHERE h.user_id = u.id) AS codes "
        "FROM users u ORDER BY (u.status = 'pending') DESC, u.created_at DESC"
    ).fetchall()
    if not rows:
        print("(沒有帳號)")
        return
    print("%-4s %-20s %-6s %-10s %-5s %s" % ("id", "username", "tier", "status", "檔數", "建立"))
    for r in rows:
        print("%-4d %-20s %-6s %-10s %-5d %s  %s" % (
            r["id"], r["username"], r["tier"], r["status"], r["codes"],
            r["created_at"], (r["note"] or "")[:40],
        ))


def _status_cmd(status):
    def run(cfg, conn, args):
        if not args:
            sys.exit("需要帳號名稱或 id")
        user = _resolve(conn, args[0])
        auth.set_status(conn, user["id"], status)
        print("%s -> %s" % (user["username"], status))
    return run


def cmd_reject(cfg, conn, args):
    if not args:
        sys.exit("需要帳號名稱或 id")
    user = _resolve(conn, args[0])
    if user["status"] != "pending":
        sys.exit("只能 reject 待核准帳號（此帳號為 %s，請用 delete）" % user["status"])
    auth.delete_user(conn, user["id"])
    print("已拒絕並刪除 %s" % user["username"])


def cmd_delete(cfg, conn, args):
    if not args:
        sys.exit("需要帳號名稱或 id")
    user = _resolve(conn, args[0])
    if input("確定刪除 %s 及其所有持股/交易？(yes) " % user["username"]) != "yes":
        sys.exit("已取消")
    auth.delete_user(conn, user["id"])
    print("已刪除 %s" % user["username"])


def cmd_passwd(cfg, conn, args):
    args = list(args)
    allow_weak = "--allow-weak" in args
    args = [a for a in args if a != "--allow-weak"]
    if not args:
        sys.exit("需要帳號名稱或 id")
    user = _resolve(conn, args[0])
    if not sys.stdin.isatty():
        # non-interactive: read the password from stdin so this can be scripted
        pw = _check_password(sys.stdin.readline().rstrip("\n"), allow_weak)
    else:
        pw = _ask_password("%s 的新密碼" % user["username"], allow_weak)
    auth.set_password(conn, user["id"], pw, enforce_policy=not allow_weak)
    print("已更新密碼（該帳號所有登入階段已失效）")


def cmd_rename(cfg, conn, args):
    """Set the display name. The login username is deliberately left alone - changing a
    login id breaks the account's own muscle memory for no gain."""
    if len(args) < 2:
        sys.exit('用法: rename <帳號> "顯示名稱"（用 "" 清掉，改回顯示帳號名）')
    user = _resolve(conn, args[0])
    name = validate.display_name(" ".join(args[1:]))
    conn.execute("UPDATE users SET display_name = ? WHERE id = ?", (name, user["id"]))
    db.audit(conn, user["id"], "rename", "display_name=%s" % (name or "(cleared)"))
    conn.commit()
    print("%s 的顯示名稱 -> %s" % (user["username"], name or "（改回顯示帳號名）"))


def cmd_invite(cfg, conn, args):
    code = auth.create_invite(conn, cfg)
    print("邀請碼（%d 天內有效，只能用一次）: %s" % (cfg["inviteDays"], code))


def cmd_import_holdings(cfg, conn, args):
    """Seed an account from a holdings.json - how the owner moves off the in-repo file."""
    if len(args) < 2:
        sys.exit("用法: import-holdings <holdings.json> <帳號>")
    path, ident = args[0], args[1]
    user = _resolve(conn, ident)
    with open(path, "r", encoding="utf-8-sig") as fh:
        data = json.load(fh)
    n_h = n_t = 0
    for h in data.get("holdings", []):
        conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots, type, theme, tech_like, color) "
            "VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(user_id, code) DO UPDATE SET "
            "lots = excluded.lots, name = excluded.name",
            (user["id"], validate.code(h["code"]),
             validate.text(h.get("name"), validate.MAX_NAME, "名稱"),
             validate.lots(h.get("lots", 1)),
             validate.text(h.get("type"), validate.MAX_NAME, "類型"),
             validate.text(h.get("theme"), validate.MAX_NAME, "主題"),
             1 if h.get("techLike") else 0, h.get("color")),
        )
        n_h += 1
    for t in data.get("trades", []):
        conn.execute(
            "INSERT INTO trades (user_id, d, side, code, lots, price) VALUES (?,?,?,?,?,?)",
            (user["id"], validate.date(t["d"]), validate.side(t["side"]),
             validate.code(t["code"]), validate.lots(t["lots"]), validate.price(t["price"])),
        )
        n_t += 1
    conn.commit()
    print("匯入 %s: %d 檔持股, %d 筆交易" % (user["username"], n_h, n_t))


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False)
    os.replace(tmp, path)   # atomic: the pwsh run must never read a half-written file
    print("wrote %s" % path)


def cmd_export_codes(cfg, conn, args):
    codes = payload.active_codes(conn, cfg)
    _write_json(os.path.join(cfg["dataDir"], "active-codes.json"),
                {"generated": db.now(), "codes": codes})
    print("  %d codes: %s" % (len(codes), ", ".join(codes)))


def cmd_export_owner(cfg, conn, args):
    data = payload.owner_portfolio(conn)
    if data is None:
        sys.exit("沒有 owner 帳號，先跑 init")
    path = os.path.join(cfg["dataDir"], "owner-holdings.json")
    _write_json(path, data)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    print("  %d holdings, %d trades" % (len(data["holdings"]), len(data["trades"])))


COMMANDS = {
    "init": cmd_init,
    "users": cmd_users,
    "approve": _status_cmd("active"),
    "resume": _status_cmd("active"),
    "suspend": _status_cmd("suspended"),
    "reject": cmd_reject,
    "delete": cmd_delete,
    "passwd": cmd_passwd,
    "rename": cmd_rename,
    "invite": cmd_invite,
    "import-holdings": cmd_import_holdings,
    "export-codes": cmd_export_codes,
    "export-owner": cmd_export_owner,
}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd not in COMMANDS:
        sys.exit("未知指令: %s（--help 看用法）" % cmd)
    cfg = config.load()
    conn = _conn(cfg)
    try:
        COMMANDS[cmd](cfg, conn, argv[1:])
    except (auth.AuthError, validate.Invalid) as exc:
        sys.exit(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
