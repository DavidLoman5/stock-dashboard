"""Offline test suite for the server. No network, no fixtures outside a temp dir.

  python3 -m unittest discover -s server -t .

Mirrors tests.ps1's role for the pwsh engine: fast, offline, run before committing.
scrypt makes each password op ~50ms, so tests reuse accounts where they can.
"""

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from server import api, auth, config, db, payload, server, validate  # noqa: E402


def make_cfg(tmp):
    cfg = dict(config.DEFAULTS)
    cfg.update({
        "dbPath": os.path.join(tmp, "test.db"),
        "dataDir": os.path.join(tmp, "data"),
        "secureCookie": False,       # tests speak plain http
        "trustProxyHeader": False,
        "port": 0,
        "maxCodesPerUser": 3,
    })
    os.makedirs(cfg["dataDir"], exist_ok=True)
    return cfg


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="stockdash-test-")
        self.cfg = make_cfg(self.tmp)
        db.close_all()
        self.conn = db.init_schema(self.cfg["dbPath"])

    def tearDown(self):
        db.close_all()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def mkuser(self, name, tier="guest", status="active", password="correct-horse-1"):
        return auth.create_user(self.conn, name, password, tier=tier, status=status)


class TestPasswords(Base):
    def test_hash_roundtrip_and_rejection(self):
        salt, digest = auth.hash_password("correct-horse-1")
        self.assertTrue(auth.verify_password("correct-horse-1", salt, digest))
        self.assertFalse(auth.verify_password("correct-horse-2", salt, digest))

    def test_salts_differ_between_users(self):
        s1, h1 = auth.hash_password("same-password-x")
        s2, h2 = auth.hash_password("same-password-x")
        self.assertNotEqual(s1, s2)
        self.assertNotEqual(h1, h2)   # so a rainbow table cannot cover two users at once

    def test_short_password_rejected(self):
        with self.assertRaises(validate.Invalid):
            self.mkuser("shorty", password="abc")


class TestSessions(Base):
    def test_login_creates_session_and_wrong_password_does_not(self):
        self.mkuser("alice")
        token, user = auth.login(self.conn, self.cfg, "alice", "correct-horse-1", "1.1.1.1", "ua")
        self.assertEqual(user["username"], "alice")
        self.assertIsNotNone(auth.resolve_session(self.conn, self.cfg, token))
        with self.assertRaises(auth.AuthError):
            auth.login(self.conn, self.cfg, "alice", "wrong-password-9", "1.1.1.1", "ua")

    def test_raw_token_is_not_stored(self):
        self.mkuser("bob")
        token, _ = auth.login(self.conn, self.cfg, "bob", "correct-horse-1", "1.1.1.1", "ua")
        stored = [r["token_sha256"] for r in self.conn.execute("SELECT token_sha256 FROM sessions")]
        self.assertNotIn(token, stored)   # a DB leak must not yield replayable tokens

    def test_unknown_user_and_wrong_password_give_same_error(self):
        self.mkuser("carol")
        with self.assertRaises(auth.AuthError) as a:
            auth.login(self.conn, self.cfg, "carol", "wrong-password-9", "1.1.1.1", "ua")
        with self.assertRaises(auth.AuthError) as b:
            auth.login(self.conn, self.cfg, "nobody", "wrong-password-9", "1.1.1.1", "ua")
        self.assertEqual(a.exception.message, b.exception.message)

    def test_lockout_after_repeated_failures(self):
        self.cfg["maxLoginFailures"] = 3
        self.mkuser("dave")
        for _ in range(3):
            with self.assertRaises(auth.AuthError):
                auth.login(self.conn, self.cfg, "dave", "wrong-password-9", "9.9.9.9", "ua")
        with self.assertRaises(auth.AuthError) as ctx:
            auth.login(self.conn, self.cfg, "dave", "correct-horse-1", "9.9.9.9", "ua")
        self.assertEqual(ctx.exception.status, 429)   # correct password still locked out

    def test_password_change_invalidates_sessions(self):
        uid = self.mkuser("erin")
        token, _ = auth.login(self.conn, self.cfg, "erin", "correct-horse-1", "1.1.1.1", "ua")
        auth.set_password(self.conn, uid, "brand-new-password")
        self.assertIsNone(auth.resolve_session(self.conn, self.cfg, token))


class TestApproval(Base):
    def test_registration_is_pending_and_blocked_until_approved(self):
        uid = auth.create_user(self.conn, "frank", "correct-horse-1", status="pending")
        token, _ = auth.login(self.conn, self.cfg, "frank", "correct-horse-1", "1.1.1.1", "ua")
        user = auth.resolve_session(self.conn, self.cfg, token)
        self.assertEqual(user["status"], "pending")

        ctx = FakeCtx(self.conn, self.cfg, user)
        with self.assertRaises(api.ApiError) as exc:
            api.bootstrap(ctx)
        self.assertEqual(exc.exception.status, 403)   # pending sees no data at all

        auth.set_status(self.conn, uid, "active")
        token, _ = auth.login(self.conn, self.cfg, "frank", "correct-horse-1", "1.1.1.1", "ua")
        user = auth.resolve_session(self.conn, self.cfg, token)
        status, _payload = api.bootstrap(FakeCtx(self.conn, self.cfg, user))
        self.assertEqual(status, 200)

    def test_suspend_kills_existing_session_immediately(self):
        uid = self.mkuser("gina")
        token, _ = auth.login(self.conn, self.cfg, "gina", "correct-horse-1", "1.1.1.1", "ua")
        self.assertIsNotNone(auth.resolve_session(self.conn, self.cfg, token))
        auth.set_status(self.conn, uid, "suspended")
        # the very next request, not "when the cookie expires"
        self.assertIsNone(auth.resolve_session(self.conn, self.cfg, token))
        with self.assertRaises(auth.AuthError) as exc:
            auth.login(self.conn, self.cfg, "gina", "correct-horse-1", "1.1.1.1", "ua")
        self.assertEqual(exc.exception.status, 403)

    def test_owner_cannot_be_suspended_or_deleted(self):
        uid = self.mkuser("owner1", tier="owner")
        with self.assertRaises(auth.AuthError):
            auth.set_status(self.conn, uid, "suspended")
        with self.assertRaises(auth.AuthError):
            auth.delete_user(self.conn, uid)

    def test_guest_cannot_reach_admin_routes(self):
        self.mkuser("henry")
        user = auth.find_user(self.conn, "henry")
        with self.assertRaises(api.ApiError) as exc:
            api.admin_users(FakeCtx(self.conn, self.cfg, user))
        self.assertEqual(exc.exception.status, 403)

    def test_deleting_user_removes_their_holdings(self):
        uid = self.mkuser("ivan")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
            (uid, "2330", "台積電", 1))
        self.conn.commit()
        auth.delete_user(self.conn, uid)
        left = self.conn.execute(
            "SELECT COUNT(*) AS n FROM holdings WHERE user_id = ?", (uid,)).fetchone()["n"]
        self.assertEqual(left, 0)


class TestTiers(Base):
    NOTES = {
        "_market": {"mood": "偏多", "windLead": "大盤收紅",
                    "wind": "投組今日明顯分化：00990A(+0.96%)與00981A(+0.67%)靠外資續買收紅"},
        "0050": {"sigFund": ["neu", "中性"], "tech": "站上月線", "chip": "外資買超",
                 "fund": "追蹤大盤", "rec": "建議續抱兩成部位", "news": [{"t": "x", "u": "http://a"}]},
    }

    def test_guest_gets_factual_fields_but_not_owner_advice(self):
        got = payload.notes_for("guest", ["0050"], self.NOTES)
        self.assertEqual(got["0050"]["tech"], "站上月線")
        self.assertNotIn("rec", got["0050"])    # portfolio-level advice is owner-only
        self.assertNotIn("news", got["0050"])
        self.assertIn("_market", got)           # market view is genuinely shared

    def test_market_commentary_naming_owner_holdings_is_not_shared(self):
        got = payload.notes_for("guest", ["0050"], self.NOTES)
        # `wind` is written about the owner's portfolio and names real holdings
        self.assertNotIn("wind", got["_market"])
        self.assertNotIn("00990A", json.dumps(got, ensure_ascii=False))
        self.assertEqual(got["_market"]["windLead"], "大盤收紅")   # the market-level part survives
        self.assertIn("wind", payload.notes_for("owner", [], self.NOTES)["_market"])

    def test_note_naming_another_owner_holding_is_dropped(self):
        notes = {"0050": {
            "tech": "站上月線",                                   # clean - kept
            "fund": "成分股與 00947/00981A 高度重疊",              # names other holdings - dropped
        }}
        got = payload.notes_for("guest", ["0050"], notes, private_codes={"0050", "00947", "00981A"})
        self.assertIn("tech", got["0050"])
        self.assertNotIn("fund", got["0050"])

    def test_filter_does_not_trip_on_prices_or_the_notes_own_code(self):
        notes = {"0050": {"tech": "0050 收 44,850.81 點、成交 9,306 億、融資 5,637 張"}}
        got = payload.notes_for("guest", ["0050"], notes, private_codes={"0050", "00947"})
        self.assertIn("tech", got["0050"])   # numbers are not codes; own code is allowed

    def test_market_allowlist_keeps_new_fields_private_by_default(self):
        notes = {"_market": {"mood": "偏多", "somethingNew": "未來新增的欄位"}}
        got = payload.notes_for("guest", [], notes)
        self.assertNotIn("somethingNew", got["_market"])

    def test_owner_gets_everything(self):
        got = payload.notes_for("owner", ["0050"], self.NOTES)
        self.assertIn("rec", got["0050"])
        self.assertIn("news", got["0050"])

    def test_uncovered_code_yields_no_note_not_an_error(self):
        got = payload.notes_for("guest", ["9999"], self.NOTES)
        self.assertNotIn("9999", got)   # page falls back to '（尚無分析…）'


class TestTokenIsolation(Base):
    """The hard rule: a guest's activity must never cost the owner Claude tokens.

    Concretely, the only input to the daily AI step is holdings-context.json, which
    update-holdings.ps1 builds from -HoldingsFile = the OWNER's portfolio. So what we assert
    is that the owner export is unaffected by guests, and that serving a guest a code nobody
    analysed produces a plain empty note rather than any kind of work item."""

    def test_owner_export_contains_only_owner_holdings(self):
        owner_id = self.mkuser("owner1", tier="owner")
        guest_id = self.mkuser("guest1")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
            (owner_id, "0050", "元大台灣50", 1))
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
            (guest_id, "2330", "台積電", 5))
        self.conn.commit()

        exported = payload.owner_portfolio(self.conn)
        codes = [h["code"] for h in exported["holdings"]]
        self.assertEqual(codes, ["0050"])
        self.assertNotIn("2330", codes)   # guest codes never enter the AI's input

    def test_guest_codes_still_join_the_shared_quote_fetch(self):
        owner_id = self.mkuser("owner1", tier="owner")
        guest_id = self.mkuser("guest1")
        for uid, code in ((owner_id, "0050"), (guest_id, "2330")):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
                (uid, code, "x", 1))
        self.conn.commit()
        codes = payload.active_codes(self.conn, self.cfg)
        # free TWSE fetch: yes. AI input: no (previous test).
        self.assertIn("2330", codes)
        self.assertIn("0050", codes)

    def test_suspended_users_drop_out_of_the_daily_fetch(self):
        guest_id = self.mkuser("guest1")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
            (guest_id, "2330", "台積電", 1))
        self.conn.commit()
        auth.set_status(self.conn, guest_id, "suspended")
        self.assertNotIn("2330", payload.active_codes(self.conn, self.cfg))

    def test_distinct_code_cap_is_enforced(self):
        self.cfg["maxDistinctCodes"] = 2
        uid = self.mkuser("guest1")
        for code in ("1101", "1102", "1103", "1104"):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
                (uid, code, "x", 1))
        self.conn.commit()
        self.assertEqual(len(payload.active_codes(self.conn, self.cfg)), 2)


class TestValidation(Base):
    def test_stock_codes(self):
        for good in ("2330", "0050", "00935", "00990A", "00990a"):
            self.assertTrue(validate.code(good))
        for bad in ("", "12", "ABCD", "2330; DROP TABLE users", "<script>", "1234567"):
            with self.assertRaises(validate.Invalid):
                validate.code(bad)

    def test_names_strip_control_characters(self):
        self.assertEqual(validate.text("台積\x00電\x1f", 30), "台積電")
        with self.assertRaises(validate.Invalid):
            validate.text("x" * 31, 30)

    def test_lots_and_prices(self):
        self.assertEqual(validate.lots("3"), 3)
        for bad in ("0", "-1", "abc", None):
            with self.assertRaises(validate.Invalid):
                validate.lots(bad)
        self.assertAlmostEqual(validate.price("100.55"), 100.55)
        for bad in ("0", "-5", "nope"):
            with self.assertRaises(validate.Invalid):
                validate.price(bad)

    def test_only_the_configured_proxy_header_is_trusted(self):
        """Every rate limit is per-IP, so a client-settable IP disables all of them.
        Tailscale Funnel overwrites X-Forwarded-For but passes CF-Connecting-IP straight
        through from the client - pointing proxyHeader at the wrong one is a real hole,
        not a cosmetic mismatch."""
        class FakeReq:
            def __init__(self, cfg, headers):
                self.cfg = cfg
                self.headers = headers
                self.client_address = ("127.0.0.1", 1234)

        cfg = dict(self.cfg, trustProxyHeader=True, proxyHeader="X-Forwarded-For")
        spoofed = {"CF-Connecting-IP": "9.9.9.9", "X-Forwarded-For": "203.0.113.7"}
        self.assertEqual(server.Handler.client_ip(FakeReq(cfg, spoofed)), "203.0.113.7")
        # header the tunnel does not set at all -> fall back to the peer, never to a guess
        self.assertEqual(
            server.Handler.client_ip(FakeReq(cfg, {"CF-Connecting-IP": "9.9.9.9"})),
            "127.0.0.1",
        )
        off = dict(cfg, trustProxyHeader=False)
        self.assertEqual(server.Handler.client_ip(FakeReq(off, spoofed)), "127.0.0.1")

    def test_display_name_allows_spaces_that_a_username_may_not(self):
        # the whole reason display_name exists: "Felix Chen" is not a legal login id
        with self.assertRaises(validate.Invalid):
            validate.username("Felix Chen")
        self.assertEqual(validate.display_name("Felix Chen"), "Felix Chen")
        self.assertEqual(validate.display_name("陳\x00小明"), "陳小明")
        with self.assertRaises(validate.Invalid):
            validate.display_name("x" * 31)

    def test_display_name_falls_back_to_username_and_is_migrated_in(self):
        self.mkuser("felixc")
        user = auth.find_user(self.conn, "felixc")
        # column exists on an already-created DB (init_schema ran the migration) and is empty
        self.assertIn("display_name", user.keys())
        self.assertEqual(payload._display_name(user), "felixc")
        self.conn.execute("UPDATE users SET display_name = ? WHERE id = ?",
                          ("Felix Chen", user["id"]))
        self.conn.commit()
        self.assertEqual(payload._display_name(auth.find_user(self.conn, "felixc")),
                         "Felix Chen")

    def test_sql_injection_in_username_lookup_is_inert(self):
        self.mkuser("jane")
        # parameterized query: this is looked up as a literal, not executed
        self.assertIsNone(auth.find_user(self.conn, "jane' OR '1'='1"))
        still_there = self.conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]
        self.assertEqual(still_there, 1)


class TestHoldingsApi(Base):
    def test_upsert_remove_and_cap(self):
        uid = self.mkuser("kate")
        user = auth.find_user(self.conn, "kate")
        for code in ("1101", "1102", "1103"):
            api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                      {"action": "upsert", "code": code, "lots": 1}))
        with self.assertRaises(api.ApiError) as exc:
            api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                      {"action": "upsert", "code": "1104", "lots": 1}))
        self.assertEqual(exc.exception.status, 409)   # maxCodesPerUser = 3 in test cfg

        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "upsert", "code": "1101", "lots": 7}))
        row = self.conn.execute(
            "SELECT lots FROM holdings WHERE user_id = ? AND code = '1101'", (uid,)).fetchone()
        self.assertEqual(row["lots"], 7)              # upsert updates, not duplicates

        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "remove", "code": "1101"}))
        self.assertEqual(len(payload.user_holdings(self.conn, uid)), 2)

    def test_user_cannot_delete_another_users_trade(self):
        victim = self.mkuser("liam")
        attacker = self.mkuser("mallory")
        cur = self.conn.execute(
            "INSERT INTO trades (user_id, d, side, code, lots, price) VALUES (?,?,?,?,?,?)",
            (victim, "2026-07-01", "buy", "2330", 1, 1000.0))
        self.conn.commit()
        trade_id = cur.lastrowid
        api.post_holdings(FakeCtx(self.conn, self.cfg, auth.find_user(self.conn, "mallory"),
                                  {"action": "untrade", "id": trade_id}))
        # the DELETE is scoped by user_id, so the victim's row survives
        self.assertEqual(len(payload.user_trades(self.conn, victim)), 1)
        self.assertEqual(attacker, auth.find_user(self.conn, "mallory")["id"])

    def test_bootstrap_omits_codes_with_no_quotes_yet(self):
        uid = self.mkuser("nina")
        user = auth.find_user(self.conn, "nina")
        with open(os.path.join(self.cfg["dataDir"], "quotes.json"), "w", encoding="utf-8") as fh:
            json.dump({"TAIEX": [{"d": "7/1", "c": 1.0}], "0050": {"series": []}}, fh)
        for code in ("0050", "2330"):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
                (uid, code, "x", 1))
        self.conn.commit()
        _status, out = api.bootstrap(FakeCtx(self.conn, self.cfg, user))
        self.assertIn("0050", out["holdingsMeta"])
        self.assertNotIn("2330", out["holdingsMeta"])  # would crash DASH[code].series
        self.assertEqual(out["pendingCodes"], ["2330"])


class TestShell(Base):
    def test_data_blocks_are_emptied_and_csp_relaxed(self):
        index = os.path.join(self.tmp, "index.html")
        with open(index, "w", encoding="utf-8") as fh:
            fh.write(
                "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
                "connect-src 'none'\">\n"
                '<script id="dashdata">window.DASH={"secret":1};</script>\n'
                '<script id="holdingsmeta">window.HOLDINGS_META={"2330":{}};</script>\n'
                '<script id="app">console.log(1)</script>\n'
            )
        html = server.build_shell(index)
        self.assertNotIn("secret", html)          # never ship one portfolio to everyone
        self.assertNotIn("2330", html)
        self.assertIn("console.log(1)", html)     # app code untouched
        self.assertIn("connect-src 'self'", html)

    def test_render_injects_this_users_data_only(self):
        template = (
            '<script id="dashdata"></script><script id="holdingsmeta"></script>'
            '<script id="appuser"></script>'
            "window.META={generated:'x',lastTrade:'y'};報告日期：<b>x</b>"
        )
        html = server.render_page(template, {
            "dash": {"TAIEX": [1]},
            "holdingsMeta": {"2330": {"lots": 4}},
            "meta": {"generated": "2026/07/23", "lastTrade": "2026-07-23"},
            "user": {"username": "nina", "tier": "guest"},
            "pendingCodes": [],
        })
        self.assertIn('window.DASH={"TAIEX":[1]}', html)
        self.assertIn('"lots":4', html)
        self.assertIn('"username":"nina"', html)
        self.assertIn('"lastTrade":"2026-07-23"', html)
        self.assertIn("報告日期：<b>2026/07/23</b>", html)

    def test_script_close_sequence_in_data_cannot_break_out(self):
        template = '<script id="holdingsmeta"></script>'
        html = server.render_page(template, {
            "holdingsMeta": {"2330": {"name": "</script><img src=x onerror=alert(1)>"}},
        })
        # the only </script> in the output is the block's own closing tag
        self.assertEqual(html.count("</script>"), 1)
        self.assertIn("<\\/script>", html)

    def test_missing_artifacts_leave_blocks_empty_rather_than_crash(self):
        template = '<script id="pkdata"></script><script id="evaldata"></script>'
        html = server.render_page(template, {"picks": None, "eval": None})
        self.assertNotIn("window.PICKS_DATA", html)   # page's own fallbacks take over
        self.assertNotIn("window.EVAL", html)


class TestHttp(Base):
    """End-to-end over a real socket: cookies, headers, status codes."""

    def setUp(self):
        super().setUp()
        index = os.path.join(self.tmp, "index.html")
        with open(index, "w", encoding="utf-8") as fh:
            fh.write(
                '<script id="dashdata">window.DASH={"x":1};</script>'
                '<script id="holdingsmeta">window.HOLDINGS_META={"9999":{}};</script>'
                '<script id="appuser"></script><p>頁面</p>'
            )
        self.cfg["host"] = "127.0.0.1"
        self.srv = server.make_server(self.cfg, index_path=index)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def request(self, path, data=None, cookie=None, method=None, origin=None):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(self.url(path), data=body, method=method)
        req.add_header("Content-Type", "application/json")
        if cookie:
            req.add_header("Cookie", "sid=%s" % cookie)
        if origin:
            req.add_header("Origin", origin)
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, json.loads(resp.read().decode()), resp.headers
        except urllib.error.HTTPError as exc:
            with exc:
                raw = exc.read().decode()
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = {"raw": raw}
            return exc.code, parsed, exc.headers

    def test_healthz(self):
        status, body, _ = self.request("/healthz")
        self.assertEqual((status, body["ok"]), (200, True))

    def test_bootstrap_requires_login(self):
        status, body, _ = self.request("/api/bootstrap")
        self.assertEqual(status, 401)
        self.assertFalse(body["ok"])

    def test_login_sets_hardened_cookie(self):
        self.mkuser("olive")
        status, body, headers = self.request(
            "/api/auth/login", {"username": "olive", "password": "correct-horse-1"})
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Strict", cookie)
        self.assertEqual(body["user"]["username"], "olive")

    def test_security_headers_present(self):
        _status, _body, headers = self.request("/healthz")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_cross_origin_post_is_rejected(self):
        status, body, _ = self.request(
            "/api/auth/login", {"username": "x", "password": "y"},
            origin="https://evil.example")
        self.assertEqual(status, 403)
        self.assertIn("來源", body["error"])

    def test_oversized_body_rejected(self):
        req = urllib.request.Request(self.url("/api/auth/login"), data=b"x" * (70 * 1024),
                                     method="POST")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as resp:
                self.fail("expected rejection, got %d" % resp.status)
        except urllib.error.HTTPError as exc:
            with exc:
                self.assertIn(exc.code, (400, 413))

    def _login(self, name):
        _s, _b, headers = self.request(
            "/api/auth/login", {"username": name, "password": "correct-horse-1"})
        return headers["Set-Cookie"].split(";")[0].split("=", 1)[1]

    def test_anonymous_index_redirects_to_login_without_following(self):
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **kw):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(self.url("/")) as resp:
                self.fail("expected a redirect, got %d" % resp.status)
        except urllib.error.HTTPError as exc:
            with exc:
                self.assertEqual(exc.code, 302)
                self.assertEqual(exc.headers["Location"], "/login")

    def test_pending_user_gets_the_waiting_page_not_the_dashboard(self):
        auth.create_user(self.conn, "pat", "correct-horse-1", status="pending")
        cookie = self._login("pat")
        req = urllib.request.Request(self.url("/"))
        req.add_header("Cookie", "sid=%s" % cookie)
        with urllib.request.urlopen(req) as resp:
            html = resp.read().decode()
        self.assertIn("等待核准", html)
        self.assertNotIn("window.DASH", html)   # no market data before approval

    def test_active_user_gets_their_own_data_spliced_in(self):
        uid = self.mkuser("quinn")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, lots) VALUES (?,?,?,?)",
            (uid, "0050", "元大台灣50", 3))
        self.conn.commit()
        with open(os.path.join(self.cfg["dataDir"], "quotes.json"), "w", encoding="utf-8") as fh:
            json.dump({"TAIEX": [{"d": "7/1", "c": 1.0}], "0050": {"series": []}}, fh)
        cookie = self._login("quinn")
        req = urllib.request.Request(self.url("/"))
        req.add_header("Cookie", "sid=%s" % cookie)
        with urllib.request.urlopen(req) as resp:
            html = resp.read().decode()
        self.assertIn('window.HOLDINGS_META=', html)
        self.assertIn('"lots":3', html)
        self.assertIn('"username":"quinn"', html)
        self.assertIn("頁面", html)             # the template's own markup survived

    def test_admin_page_is_owner_only(self):
        self.mkuser("rita")
        cookie = self._login("rita")
        req = urllib.request.Request(self.url("/admin"))
        req.add_header("Cookie", "sid=%s" % cookie)
        try:
            with urllib.request.urlopen(req) as resp:
                self.fail("expected 403, got %d" % resp.status)
        except urllib.error.HTTPError as exc:
            with exc:
                self.assertEqual(exc.code, 403)

    def test_unknown_path_404(self):
        status, _body, _ = self.request("/api/does-not-exist")
        self.assertEqual(status, 404)


class FakeCtx:
    """Stands in for server.Ctx so handler logic can be tested without a socket."""

    def __init__(self, conn, cfg, user=None, body=None, ip="127.0.0.1"):
        self.conn = conn
        self.cfg = cfg
        self.user = user
        self.body = body or {}
        self.ip = ip
        self.ua = "test"
        self.token = None
        self.cookie_set = None

    def require_user(self, allow_pending=False):
        if self.user is None:
            raise api.ApiError("請先登入", 401)
        if self.user["status"] != "active" and not allow_pending:
            raise api.ApiError("帳號尚待管理者核准", 403)
        return self.user

    def require_owner(self):
        user = self.require_user()
        if user["tier"] != "owner":
            raise api.ApiError("需要管理者權限", 403)
        return user

    def set_session_cookie(self, token):
        self.cookie_set = token

    def clear_session_cookie(self):
        self.cookie_set = ""


if __name__ == "__main__":
    unittest.main()
