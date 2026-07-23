"""Request handlers. Each returns (status, payload_dict); raising AuthError or validate.Invalid
is turned into an error response by the server layer.

Authorisation rules, in one place so they are easy to audit:
  * every /api/* route except register/login/logout requires an active session
  * a 'pending' user can reach /api/me only - never any market or portfolio data
  * /api/admin/* additionally requires tier == 'owner'
"""

from . import auth, db, payload, validate


class ApiError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status


def _user_public(user):
    return {
        "username": user["username"],
        "tier": user["tier"],
        "status": user["status"],
        "note": user["note"],
    }


# --------------------------------------------------------------------------- auth routes

def register(ctx):
    cfg = ctx.cfg
    if not cfg["registrationOpen"]:
        raise ApiError("目前未開放註冊", 403)
    if auth.registrations_today(ctx.conn, ctx.ip) >= cfg["maxRegistrationsPerIpPerDay"]:
        raise ApiError("此 IP 今日註冊次數已達上限", 429)
    body = ctx.body
    user_id = auth.create_user(
        ctx.conn,
        body.get("username"),
        body.get("password"),
        tier="guest",
        status="pending",          # the owner must approve before this account sees anything
        note=body.get("note", ""),
        ip=ctx.ip,
    )
    if cfg["requireInvite"]:
        try:
            auth.consume_invite(ctx.conn, body.get("invite"), user_id)
        except auth.AuthError:
            # do not leave a half-registered account behind when the invite is rejected
            ctx.conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
            ctx.conn.commit()
            raise
    return 201, {"ok": True, "status": "pending",
                 "message": "註冊完成，等待管理者核准後即可使用。"}


def login(ctx):
    token, user = auth.login(
        ctx.conn, ctx.cfg, ctx.body.get("username"), ctx.body.get("password"), ctx.ip, ctx.ua
    )
    ctx.set_session_cookie(token)
    return 200, {"ok": True, "user": _user_public(user)}


def logout(ctx):
    auth.destroy_session(ctx.conn, ctx.token)
    ctx.clear_session_cookie()
    return 200, {"ok": True}


def change_password(ctx):
    user = ctx.require_user(allow_pending=True)
    if not auth.verify_password(
        ctx.body.get("current") or "", user["pw_salt"], user["pw_hash"]
    ):
        raise ApiError("目前密碼不正確", 403)
    auth.set_password(ctx.conn, user["id"], ctx.body.get("new"))
    ctx.clear_session_cookie()   # set_password drops all sessions, including this one
    return 200, {"ok": True, "message": "密碼已更新，請重新登入。"}


def me(ctx):
    user = ctx.require_user(allow_pending=True)
    return 200, {"ok": True, "user": _user_public(user)}


# --------------------------------------------------------------------------- data routes

def bootstrap(ctx):
    user = ctx.require_user()
    return 200, payload.bootstrap(ctx.conn, ctx.cfg, user)


def get_holdings(ctx):
    user = ctx.require_user()
    return 200, {
        "ok": True,
        "holdings": [dict(h) for h in payload.user_holdings(ctx.conn, user["id"])],
        "trades": [dict(t) for t in payload.user_trades(ctx.conn, user["id"])],
    }


def post_holdings(ctx):
    """Actions: upsert (add/change lots), remove, trade (append a fill), untrade."""
    user = ctx.require_user()
    action = (ctx.body.get("action") or "").strip()
    conn = ctx.conn

    if action == "upsert":
        code = validate.code(ctx.body.get("code"))
        lots = validate.lots(ctx.body.get("lots"))
        existing = conn.execute(
            "SELECT 1 FROM holdings WHERE user_id = ? AND code = ?", (user["id"], code)
        ).fetchone()
        if existing is None:
            count = conn.execute(
                "SELECT COUNT(*) AS n FROM holdings WHERE user_id = ?", (user["id"],)
            ).fetchone()["n"]
            if count >= ctx.cfg["maxCodesPerUser"]:
                raise ApiError("持股檔數已達上限（%d）" % ctx.cfg["maxCodesPerUser"], 409)
        conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots, type, theme, tech_like, color) "
            "VALUES (?,?,?,?,?,?,?,?) "
            "ON CONFLICT(user_id, code) DO UPDATE SET "
            "  lots = excluded.lots, name = excluded.name, type = excluded.type, "
            "  theme = excluded.theme, tech_like = excluded.tech_like",
            (
                user["id"], code,
                validate.text(ctx.body.get("name"), validate.MAX_NAME, "名稱") or code,
                lots,
                validate.text(ctx.body.get("type"), validate.MAX_NAME, "類型"),
                validate.text(ctx.body.get("theme"), validate.MAX_NAME, "主題"),
                1 if ctx.body.get("techLike") else 0,
                None,
            ),
        )
        db.audit(conn, user["id"], "holding_upsert", "%s x%d" % (code, lots))
        conn.commit()
        return 200, {"ok": True}

    if action == "remove":
        code = validate.code(ctx.body.get("code"))
        conn.execute("DELETE FROM holdings WHERE user_id = ? AND code = ?", (user["id"], code))
        db.audit(conn, user["id"], "holding_remove", code)
        conn.commit()
        return 200, {"ok": True}

    if action == "trade":
        code = validate.code(ctx.body.get("code"))
        cur = conn.execute(
            "INSERT INTO trades (user_id, d, side, code, lots, price) VALUES (?,?,?,?,?,?)",
            (
                user["id"],
                validate.date(ctx.body.get("d")),
                validate.side(ctx.body.get("side")),
                code,
                validate.lots(ctx.body.get("lots")),
                validate.price(ctx.body.get("price")),
            ),
        )
        db.audit(conn, user["id"], "trade_add", code)
        conn.commit()
        return 200, {"ok": True, "id": cur.lastrowid}

    if action == "untrade":
        try:
            trade_id = int(ctx.body.get("id"))
        except (TypeError, ValueError):
            raise ApiError("交易 id 不正確", 400)
        conn.execute("DELETE FROM trades WHERE id = ? AND user_id = ?", (trade_id, user["id"]))
        db.audit(conn, user["id"], "trade_remove", str(trade_id))
        conn.commit()
        return 200, {"ok": True}

    raise ApiError("不支援的操作", 400)


# --------------------------------------------------------------------------- admin routes

def admin_users(ctx):
    ctx.require_owner()
    rows = ctx.conn.execute(
        "SELECT u.id, u.username, u.tier, u.status, u.note, u.reg_ip, u.created_at, "
        "       u.approved_at, u.last_login_at, "
        "       (SELECT COUNT(*) FROM holdings h WHERE h.user_id = u.id) AS codes "
        "FROM users u ORDER BY (u.status = 'pending') DESC, u.created_at DESC"
    ).fetchall()
    return 200, {"ok": True, "users": [dict(r) for r in rows]}


def admin_action(ctx):
    actor = ctx.require_owner()
    action = (ctx.body.get("action") or "").strip()
    try:
        target = int(ctx.body.get("id"))
    except (TypeError, ValueError):
        raise ApiError("使用者 id 不正確", 400)
    if action in ("approve", "resume"):
        auth.set_status(ctx.conn, target, "active", actor["id"])
    elif action == "suspend":
        auth.set_status(ctx.conn, target, "suspended", actor["id"])
    elif action == "reject":
        # a rejected registration is removed outright; nothing of theirs exists yet
        auth.delete_user(ctx.conn, target, actor["id"])
    elif action == "delete":
        auth.delete_user(ctx.conn, target, actor["id"])
    else:
        raise ApiError("不支援的操作", 400)
    return 200, {"ok": True}


def admin_invite(ctx):
    actor = ctx.require_owner()
    return 200, {"ok": True, "code": auth.create_invite(ctx.conn, ctx.cfg, actor["id"])}
