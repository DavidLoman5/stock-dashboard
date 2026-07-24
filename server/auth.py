"""Authentication: password hashing, sessions, throttling, registration approval.

Each measure below maps to one concrete attack:
  scrypt + per-user salt        -> offline cracking of a leaked DB
  dummy hash on unknown user    -> account enumeration via response timing
  SHA-256 of token stored       -> replaying session tokens from a leaked DB
  token rotation on login       -> session fixation
  per-IP + per-username backoff -> credential brute force
  status re-checked per request -> a suspended user keeping access until their cookie expires
"""

import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

from . import db, validate

SCRYPT_N = 1 << 15
SCRYPT_R = 8
SCRYPT_P = 1
# 128 * N * r = 32MiB; OpenSSL's default maxmem is exactly 32MiB and would reject it, so
# ask for headroom explicitly rather than relying on the default.
SCRYPT_MAXMEM = 64 * 1024 * 1024
_DUMMY_SALT = bytes(16)


class AuthError(Exception):
    """Raised with a user-facing message and an HTTP status."""

    def __init__(self, message, status=401):
        super().__init__(message)
        self.message = message
        self.status = status


def _scrypt(password, salt):
    return hashlib.scrypt(
        password.encode("utf-8"), salt=salt,
        n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, maxmem=SCRYPT_MAXMEM, dklen=64,
    )


def hash_password(password):
    salt = secrets.token_bytes(16)
    return salt.hex(), _scrypt(password, salt).hex()


def verify_password(password, salt_hex, hash_hex):
    try:
        salt = bytes.fromhex(salt_hex)
    except ValueError:
        return False
    return hmac.compare_digest(_scrypt(password, salt).hex(), hash_hex)


def _burn_timing():
    """Spend the same work as a real verify so unknown accounts are indistinguishable."""
    _scrypt("x" * 16, _DUMMY_SALT)


# --------------------------------------------------------------------------- throttling

def _iso_ago(minutes=0, days=0):
    ts = datetime.now(timezone.utc) - timedelta(minutes=minutes, days=days)
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def record_attempt(conn, ip, username_, ok):
    conn.execute(
        "INSERT INTO login_attempts (ip, username, ts, ok) VALUES (?,?,?,?)",
        (ip, username_, db.now(), 1 if ok else 0),
    )


def is_locked_out(conn, cfg, ip, username_):
    """IP and username are counted separately, with a much higher username threshold.

    A single OR-ed threshold would let anyone lock an account they don't own out for
    lockoutMinutes with maxLoginFailures wrong passwords (a denial-of-service on the real
    user). The per-username limit exists only to bound a distributed brute force, so it can
    afford to be loose; the per-IP limit stays tight."""
    since = _iso_ago(minutes=cfg["lockoutMinutes"])
    row = conn.execute(
        "SELECT COUNT(CASE WHEN ip = ? THEN 1 END) AS by_ip, "
        "       COUNT(CASE WHEN username = ? THEN 1 END) AS by_user "
        "FROM login_attempts WHERE ok = 0 AND ts >= ?",
        (ip, username_, since),
    ).fetchone()
    return (row["by_ip"] >= cfg["maxLoginFailures"]
            or row["by_user"] >= cfg["maxLoginFailuresPerUser"])


def registrations_today(conn, ip):
    since = _iso_ago(days=1)
    row = conn.execute(
        "SELECT COUNT(*) AS n FROM users WHERE reg_ip = ? AND created_at >= ?", (ip, since)
    ).fetchone()
    return row["n"]


def prune(conn, cfg):
    """Housekeeping: drop expired sessions, stale attempt rows, abandoned pending accounts."""
    conn.execute("DELETE FROM sessions WHERE expires_at < ?", (db.now(),))
    conn.execute("DELETE FROM login_attempts WHERE ts < ?", (_iso_ago(days=7),))
    conn.execute(
        "DELETE FROM users WHERE status = 'pending' AND created_at < ?",
        (_iso_ago(days=cfg["pendingExpiryDays"]),),
    )
    conn.commit()


# --------------------------------------------------------------------------- users

def find_user(conn, username_):
    return conn.execute(
        "SELECT * FROM users WHERE username = ? COLLATE NOCASE", (username_,)
    ).fetchone()


def create_user(conn, username_, password_, tier="guest", status="pending", note="", ip=""):
    username_ = validate.username(username_)
    password_ = validate.password(password_)
    note = validate.text(note, validate.MAX_NOTE, "自我介紹")
    if find_user(conn, username_):
        raise AuthError("此帳號已被使用", 409)
    salt, pw_hash = hash_password(password_)
    cur = conn.execute(
        "INSERT INTO users (username, pw_hash, pw_salt, tier, status, note, reg_ip, created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (username_, pw_hash, salt, tier, status, note, ip, db.now()),
    )
    db.audit(conn, cur.lastrowid, "register", "tier=%s status=%s" % (tier, status))
    conn.commit()
    return cur.lastrowid


def set_password(conn, user_id, new_password, enforce_policy=True):
    """enforce_policy=False is reachable only from the local admin CLI's explicit --allow-weak.
    Every web-facing path (registration, self-service change) leaves it True."""
    if enforce_policy:
        new_password = validate.password(new_password)
    elif not new_password:
        raise AuthError("密碼不可為空", 400)
    salt, pw_hash = hash_password(new_password)
    conn.execute(
        "UPDATE users SET pw_hash = ?, pw_salt = ? WHERE id = ?", (pw_hash, salt, user_id)
    )
    # a password change must invalidate every other session (e.g. after a suspected leak)
    conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    db.audit(conn, user_id, "password_change")
    conn.commit()


def set_status(conn, user_id, status, actor_id=None):
    if status not in ("pending", "active", "suspended"):
        raise AuthError("狀態值不合法", 400)
    row = conn.execute("SELECT tier, status FROM users WHERE id = ?", (user_id,)).fetchone()
    if row is None:
        raise AuthError("帳號不存在", 404)
    # locking the only owner out of the admin panel would be unrecoverable from the web UI
    if row["tier"] == "owner" and status != "active":
        raise AuthError("不能停用 owner 帳號", 400)
    if status == "active":
        conn.execute(
            "UPDATE users SET status = 'active', approved_at = ?, approved_by = ? WHERE id = ?",
            (db.now(), actor_id, user_id),
        )
    else:
        conn.execute("UPDATE users SET status = ? WHERE id = ?", (status, user_id))
    if status != "active":
        # take effect now, not when the cookie happens to expire
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    db.audit(conn, actor_id, "set_status", "user=%d status=%s" % (user_id, status))
    conn.commit()


def delete_user(conn, user_id, actor_id=None):
    row = conn.execute("SELECT tier FROM users WHERE id = ?", (user_id,)).fetchone()
    if row is None:
        raise AuthError("帳號不存在", 404)
    if row["tier"] == "owner":
        raise AuthError("不能刪除 owner 帳號", 400)
    # holdings/trades/sessions cascade via FK; audit rows are kept deliberately
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
    db.audit(conn, actor_id, "delete_user", "user=%d" % user_id)
    conn.commit()


# --------------------------------------------------------------------------- invites

def create_invite(conn, cfg, created_by=None):
    code = secrets.token_urlsafe(12)
    expires = (datetime.now(timezone.utc) + timedelta(days=cfg["inviteDays"])).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    conn.execute(
        "INSERT INTO invites (code_sha256, created_by, created_at, expires_at) VALUES (?,?,?,?)",
        (hashlib.sha256(code.encode()).hexdigest(), created_by, db.now(), expires),
    )
    conn.commit()
    return code


def consume_invite(conn, code, user_id):
    digest = hashlib.sha256((code or "").encode()).hexdigest()
    row = conn.execute(
        "SELECT * FROM invites WHERE code_sha256 = ? AND used_by IS NULL AND expires_at > ?",
        (digest, db.now()),
    ).fetchone()
    if row is None:
        raise AuthError("邀請碼無效或已過期", 403)
    conn.execute(
        "UPDATE invites SET used_by = ?, used_at = ? WHERE code_sha256 = ?",
        (user_id, db.now(), digest),
    )
    conn.commit()


# --------------------------------------------------------------------------- sessions

def create_session(conn, cfg, user_id, ip, ua):
    token = secrets.token_urlsafe(32)
    expires = (datetime.now(timezone.utc) + timedelta(days=cfg["sessionDays"])).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    ts = db.now()
    conn.execute(
        "INSERT INTO sessions (token_sha256, user_id, created_at, last_seen_at, expires_at, ip, ua) "
        "VALUES (?,?,?,?,?,?,?)",
        (hashlib.sha256(token.encode()).hexdigest(), user_id, ts, ts, expires, ip, ua[:200]),
    )
    conn.commit()
    return token


def resolve_session(conn, cfg, token):
    """Return the user row for a valid session, or None. Re-reads users.status every call."""
    if not token:
        return None
    digest = hashlib.sha256(token.encode()).hexdigest()
    row = conn.execute(
        "SELECT s.token_sha256, s.last_seen_at, s.expires_at, u.* "
        "FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_sha256 = ?",
        (digest,),
    ).fetchone()
    if row is None:
        return None
    now_iso = db.now()
    if row["expires_at"] <= now_iso:
        conn.execute("DELETE FROM sessions WHERE token_sha256 = ?", (digest,))
        conn.commit()
        return None
    idle_cutoff = _iso_ago(days=cfg["idleDays"])
    if row["last_seen_at"] < idle_cutoff:
        conn.execute("DELETE FROM sessions WHERE token_sha256 = ?", (digest,))
        conn.commit()
        return None
    if row["status"] == "suspended":
        # belt and braces: set_status already cleared their sessions
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (row["id"],))
        conn.commit()
        return None
    conn.execute(
        "UPDATE sessions SET last_seen_at = ? WHERE token_sha256 = ?", (now_iso, digest)
    )
    conn.commit()
    return row


def destroy_session(conn, token):
    if not token:
        return
    conn.execute(
        "DELETE FROM sessions WHERE token_sha256 = ?",
        (hashlib.sha256(token.encode()).hexdigest(),),
    )
    conn.commit()


def login(conn, cfg, username_, password_, ip, ua):
    username_ = (username_ or "").strip()
    if is_locked_out(conn, cfg, ip, username_):
        raise AuthError("嘗試次數過多，請稍後再試", 429)
    user = find_user(conn, username_)
    if user is None:
        _burn_timing()
        record_attempt(conn, ip, username_, False)
        conn.commit()
        raise AuthError("帳號或密碼錯誤")
    if not verify_password(password_ or "", user["pw_salt"], user["pw_hash"]):
        record_attempt(conn, ip, username_, False)
        conn.commit()
        raise AuthError("帳號或密碼錯誤")
    if user["status"] == "suspended":
        record_attempt(conn, ip, username_, False)
        conn.commit()
        raise AuthError("此帳號已被停用", 403)
    record_attempt(conn, ip, username_, True)
    # rotate: never keep a pre-login token valid (session fixation)
    conn.execute("DELETE FROM sessions WHERE user_id = ? AND ip = ?", (user["id"], ip))
    conn.execute("UPDATE users SET last_login_at = ? WHERE id = ?", (db.now(), user["id"]))
    conn.commit()
    token = create_session(conn, cfg, user["id"], ip, ua)
    return token, user
