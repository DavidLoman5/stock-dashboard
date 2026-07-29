"""ThreadingHTTPServer front end. Python standard library only - no pip, no venv, no lockfile.

Deliberately binds loopback by default: the only intended path in from the internet is a
Cloudflare Tunnel, which terminates TLS and forwards to 127.0.0.1. Nothing here should ever
listen on 0.0.0.0.

Run:  python3 -m server.server        (from the repo root)
"""

import http.cookies
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if __package__ in (None, ""):  # allow `python3 server/server.py` as well as `-m server.server`
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = "server"

from . import api, auth, config, db, pagedata, payload, validate  # noqa: E402

MAX_BODY = 64 * 1024
COOKIE_NAME = "sid"
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
ICON_PATH = "/apple-touch-icon.png"
_shell_cache = {"mtime": None, "html": None}
_shell_lock = threading.Lock()
# prune used to run only at startup, which under systemd means "once per boot, ever" -
# login_attempts/expired sessions/stale pending accounts then grow for months. Re-run it
# lazily, at most once a day, from whatever request happens to come in first.
PRUNE_INTERVAL = 86400
_prune_state = {"last": 0.0}
_prune_lock = threading.Lock()


def prune_if_due(conn, cfg):
    now = time.monotonic()
    with _prune_lock:
        if now - _prune_state["last"] < PRUNE_INTERVAL and _prune_state["last"] != 0.0:
            return
        _prune_state["last"] = now
    auth.prune(conn, cfg)


def build_shell(index_path):
    """index.html with every spliced data block emptied and CSP relaxed just enough to call our
    own API. This is the per-request template; the on-disk file stays the strict static demo.

    Emptying *every* block in the contract (rather than a list kept here) is the point: a block
    added to the pipeline is blank in the shell by default instead of shipping the static demo's
    copy - or one user's portfolio - to everybody until somebody remembers to extend the list."""
    with open(index_path, "r", encoding="utf-8") as fh:
        html = fh.read()
    for block_id in pagedata.block_ids():
        html = pagedata.splice(html, block_id, "")
    html = html.replace("connect-src 'none'", "connect-src 'self'")
    return html


def shell(index_path):
    with _shell_lock:
        mtime = os.path.getmtime(index_path)
        if _shell_cache["mtime"] != mtime:
            _shell_cache["html"] = build_shell(index_path)
            _shell_cache["mtime"] = mtime
        return _shell_cache["html"]


# block id -> the key its value lives under in payload.bootstrap()'s result. The window.* name
# is not repeated here; it comes from page-contract.json via pagedata.set_block.
BLOCK_SOURCES = (
    ("dashdata", "dash"),
    ("holdingsmeta", "holdingsMeta"),
    ("holdingsnotes", "holdingsNotes"),
    ("pkdata", "picks"),
    ("pkline", "picksKline"),
    ("pknotes", "picksNotes"),
    ("evaldata", "eval"),
    ("backtest", "backtest"),
    ("tokenusage", "tokenUsage"),
)

# Blocks render_page fills by hand rather than from a bootstrap key.
SPECIAL_BLOCKS = ("meta", "appuser")


def _assert_every_block_has_a_source():
    """A block declared in the contract but wired to nothing here renders blank, forever, with
    no error - build_shell() empties every block and then nobody refills this one. That is not
    hypothetical: tokenusage shipped exactly that way to every self-hosted user until 6fc268a.
    Checking at import turns the next occurrence into a startup failure."""
    covered = {block_id for block_id, _ in BLOCK_SOURCES} | set(SPECIAL_BLOCKS)
    declared = set(pagedata.block_ids())
    unwired = declared - covered
    if unwired:
        raise RuntimeError(
            "page-contract.json declares block(s) %s that server.py never fills; add them to "
            "BLOCK_SOURCES (and to payload.bootstrap) or the page ships them blank"
            % ", ".join(sorted(unwired))
        )
    unknown = covered - declared
    if unknown:
        raise RuntimeError(
            "server.py fills block(s) %s that page-contract.json does not declare"
            % ", ".join(sorted(unknown))
        )


_assert_every_block_has_a_source()


def render_page(template, boot):
    """Splice one user's payload into the template.

    Rendering server-side (rather than shipping an empty shell that fetches) keeps index.html's
    existing boot path untouched: it still derives HCODES/H/hydrate() from window.* at parse
    time, exactly as it does in the static build.
    """
    html = template
    for block_id, key in BLOCK_SOURCES:
        if key not in boot:
            raise KeyError(
                "payload.bootstrap() returned no %r key for block %r" % (key, block_id)
            )
        value = boot[key]
        if value is None:
            continue   # artifact legitimately absent today (no eval report, no backtest card)
        html = pagedata.set_block(html, block_id, value)
    meta = boot.get("meta") or {}
    html = pagedata.set_block(html, "meta", {
        "generated": meta.get("generated", ""), "lastTrade": meta.get("lastTrade", ""),
    })
    html = pagedata.set_block(html, "appuser", {
        **boot.get("user", {}),
        "pendingCodes": boot.get("pendingCodes", []),
    })
    return html


class Ctx:
    """Per-request state plus the authorisation helpers the handlers call."""

    def __init__(self, handler, body, token):
        self.handler = handler
        self.cfg = handler.cfg
        self.conn = db.get(handler.cfg["dbPath"])
        self.body = body if isinstance(body, dict) else {}
        self.token = token
        self.ip = handler.client_ip()
        self.ua = handler.headers.get("User-Agent", "")
        self._user = None
        self._resolved = False

    @property
    def user(self):
        if not self._resolved:
            self._user = auth.resolve_session(self.conn, self.cfg, self.token)
            self._resolved = True
        return self._user

    def require_user(self, allow_pending=False):
        user = self.user
        if user is None:
            raise api.ApiError("請先登入", 401)
        if user["status"] != "active" and not allow_pending:
            raise api.ApiError("帳號尚待管理者核准", 403)
        return user

    def require_owner(self):
        user = self.require_user()
        if user["tier"] != "owner":
            raise api.ApiError("需要管理者權限", 403)
        return user

    def set_session_cookie(self, token):
        self.handler.pending_cookie = (token, self.cfg["sessionDays"] * 86400)

    def clear_session_cookie(self):
        self.handler.pending_cookie = ("", 0)


ROUTES = {
    ("POST", "/api/auth/register"): api.register,
    ("POST", "/api/auth/login"): api.login,
    ("POST", "/api/auth/logout"): api.logout,
    ("POST", "/api/auth/password"): api.change_password,
    ("GET", "/api/me"): api.me,
    ("GET", "/api/bootstrap"): api.bootstrap,
    ("GET", "/api/holdings"): api.get_holdings,
    ("POST", "/api/holdings"): api.post_holdings,
    ("GET", "/api/admin/users"): api.admin_users,
    ("POST", "/api/admin/users"): api.admin_action,
    ("POST", "/api/admin/invite"): api.admin_invite,
}
PAGES = {
    "/": ("index", None),
    "/login": ("static", "login.html"),
    "/admin": ("owner", "admin.html"),
}


class Handler(BaseHTTPRequestHandler):
    server_version = "stockdash"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    cfg = None
    index_path = None

    # ------------------------------------------------------------------ helpers

    def client_ip(self):
        """The throttles are per-IP, so a forgeable IP means no throttle at all.

        proxyHeader must name a header the tunnel in front of us *overwrites* on every
        request - verified for both supported tunnels: Cloudflare sets CF-Connecting-IP,
        Tailscale Funnel sets X-Forwarded-For. Naming the wrong one is not a no-op, it is
        a hole: any header the tunnel does not touch arrives exactly as the client typed
        it (a Tailscale deployment left on CF-Connecting-IP lets anyone pick their own IP).
        """
        if self.cfg["trustProxyHeader"]:
            forwarded = self.headers.get(self.cfg["proxyHeader"])
            if forwarded:
                return forwarded.split(",")[0].strip()[:64]
        return self.client_address[0]

    def cookie_token(self):
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        try:
            jar = http.cookies.SimpleCookie(raw)
        except http.cookies.CookieError:
            return None
        morsel = jar.get(COOKIE_NAME)
        return morsel.value if morsel else None

    def origin_ok(self):
        """CSRF defence #2 (SameSite=Strict is #1). A state-changing request must either carry
        no Origin (non-browser client) or an Origin we recognise."""
        origin = self.headers.get("Origin")
        if not origin:
            return True
        allowed = list(self.cfg["allowedOrigins"])
        host = self.headers.get("Host")
        if host:
            allowed += ["http://" + host, "https://" + host]
        return origin in allowed

    def send_common_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        cookie = getattr(self, "pending_cookie", None)
        if cookie is not None:
            value, max_age = cookie
            parts = [
                "%s=%s" % (COOKIE_NAME, value),
                "Path=/",
                "HttpOnly",
                "SameSite=Strict",
                "Max-Age=%d" % max_age,
            ]
            if self.cfg["secureCookie"]:
                parts.append("Secure")
            self.send_header("Set-Cookie", "; ".join(parts))

    def respond(self, status, body, content_type="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_common_headers()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(raw)

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise api.ApiError("Content-Length 不正確", 400)
        if length > MAX_BODY:
            raise api.ApiError("請求內容過大", 413)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise api.ApiError("請求格式需為 JSON", 400)
        if not isinstance(parsed, dict):
            raise api.ApiError("請求格式需為 JSON 物件", 400)
        return parsed

    # ------------------------------------------------------------------ routing

    def do_GET(self):
        self.route("GET")

    def do_HEAD(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        self.pending_cookie = None
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path == "/healthz":
            return self.respond(200, {"ok": True})

        if method == "GET" and path == ICON_PATH:
            return self.serve_icon()

        try:
            prune_if_due(db.get(self.cfg["dbPath"]), self.cfg)
        except Exception:                      # noqa: BLE001 - housekeeping must never 500 a request
            self.log_error("prune failed")

        handler = ROUTES.get((method, path))
        if handler is not None:
            return self.handle_api(handler, method)

        if method == "GET" and path in PAGES:
            return self.serve_page(path)

        self.respond(404, {"ok": False, "error": "not found"})

    def handle_api(self, handler, method):
        try:
            if method == "POST" and not self.origin_ok():
                raise api.ApiError("來源不被允許", 403)
            body = self.read_body() if method == "POST" else {}
            ctx = Ctx(self, body, self.cookie_token())
            status, payload_out = handler(ctx)
        except api.ApiError as exc:
            return self.respond(exc.status, {"ok": False, "error": exc.message})
        except auth.AuthError as exc:
            return self.respond(exc.status, {"ok": False, "error": exc.message})
        except validate.Invalid as exc:
            return self.respond(400, {"ok": False, "error": str(exc)})
        except Exception:                      # noqa: BLE001 - never leak a traceback
            self.log_error("unhandled error on %s", self.path)
            import traceback
            traceback.print_exc()
            return self.respond(500, {"ok": False, "error": "伺服器發生錯誤"})
        self.respond(status, payload_out)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_common_headers()
        self.end_headers()

    def serve_page(self, path):
        kind, name = PAGES[path]
        if kind == "static":
            return self.serve_static(name)

        ctx = Ctx(self, {}, self.cookie_token())
        user = ctx.user
        if user is None:
            return self.redirect("/login")

        if kind == "owner":
            # the API enforces this too; gating the page as well keeps the panel out of sight
            if user["tier"] != "owner":
                return self.respond(403, {"ok": False, "error": "需要管理者權限"})
            return self.serve_static(name)

        if user["status"] != "active":
            return self.serve_static("pending.html")
        try:
            template = shell(self.index_path)
        except OSError:
            return self.respond(500, {"ok": False, "error": "index.html 不存在"})
        boot = payload.bootstrap(ctx.conn, self.cfg, user)
        self.respond(200, render_page(template, boot), "text/html; charset=utf-8")

    def serve_icon(self):
        """The iOS home-screen icon - the one asset here that is bytes, not text.

        It sits next to index.html (same file GitHub Pages serves), so the static and
        server modes ship the same icon from one copy. No auth: it is on every page's
        <link>, including /login, and it discloses nothing.
        """
        target = os.path.join(os.path.dirname(self.index_path), "apple-touch-icon.png")
        try:
            with open(target, "rb") as fh:
                blob = fh.read()
        except OSError:
            return self.respond(404, {"ok": False, "error": "not found"})
        self.respond(200, blob, "image/png")

    def serve_static(self, name):
        target = os.path.normpath(os.path.join(STATIC_DIR, name))
        if not target.startswith(STATIC_DIR + os.sep):
            return self.respond(404, {"ok": False, "error": "not found"})
        try:
            with open(target, "r", encoding="utf-8") as fh:
                html = fh.read()
        except OSError:
            return self.respond(404, {"ok": False, "error": "not found"})
        self.respond(200, html, "text/html; charset=utf-8")

    def log_message(self, fmt, *args):
        # default logs the full path; keep it but drop query strings just in case
        sys.stderr.write(
            "%s - %s\n" % (self.client_ip(), (fmt % args).split("?")[0])
        )


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(cfg, index_path=None):
    index_path = index_path or os.path.join(config.ROOT, "index.html")
    handler = type("BoundHandler", (Handler,), {"cfg": cfg, "index_path": index_path})
    return Server((cfg["host"], cfg["port"]), handler)


def main():
    cfg = config.load()
    if cfg["host"] not in ("127.0.0.1", "::1", "localhost"):
        sys.stderr.write(
            "WARNING: host is %s - this exposes the app directly. The intended setup is "
            "loopback + Cloudflare Tunnel.\n" % cfg["host"]
        )
    conn = db.init_schema(cfg["dbPath"])
    auth.prune(conn, cfg)
    srv = make_server(cfg)
    sys.stderr.write("serving on http://%s:%d (db: %s)\n" % (cfg["host"], cfg["port"], cfg["dbPath"]))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
