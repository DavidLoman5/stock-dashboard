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

from server import (  # noqa: E402
    admin, api, auth, config, db, gnotes, pagedata, payload, server, validate,
)


def make_cfg(tmp):
    cfg = dict(config.DEFAULTS)
    cfg.update({
        "dbPath": os.path.join(tmp, "test.db"),
        "dataDir": os.path.join(tmp, "data"),
        # keep bootstrap() off the real repo-root artifacts; this suite promises no fixtures
        # outside a temp dir, and holdings-notes.json is the owner's actual analysis
        "notesDir": tmp,
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


class TestSchemaMigration(Base):
    def test_lots_become_shares_and_the_old_column_goes_away(self):
        """A DB created before the shares change still holds lots. init_schema() has to carry the
        values over (x1000) and drop `lots`, or every quantity on the page silently reads 0."""
        path = os.path.join(self.tmp, "legacy.db")
        conn = db.connect(path)
        conn.executescript(
            "CREATE TABLE holdings (user_id INTEGER, code TEXT, name TEXT DEFAULT '',"
            " lots INTEGER NOT NULL DEFAULT 1, type TEXT DEFAULT '', theme TEXT DEFAULT '',"
            " tech_like INTEGER DEFAULT 0, color TEXT, PRIMARY KEY (user_id, code));"
            "CREATE TABLE trades (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER,"
            " d TEXT, side TEXT, code TEXT, lots REAL NOT NULL, price REAL);"
        )
        conn.execute("INSERT INTO holdings (user_id, code, lots) VALUES (1,'0050',3)")
        conn.execute(
            "INSERT INTO trades (user_id, d, side, code, lots, price) VALUES (1,'2026-07-01','buy','0050',2,100.0)")
        conn.commit()
        conn.close()
        db.close_all()

        conn = db.init_schema(path)
        self.assertEqual(
            conn.execute("SELECT shares FROM holdings").fetchone()["shares"], 3000)
        self.assertEqual(
            conn.execute("SELECT shares FROM trades").fetchone()["shares"], 2000)
        for table in ("holdings", "trades"):
            self.assertNotIn("lots", db._columns(conn, table))

        db.lots_to_shares(conn)   # idempotent: a second run must not re-multiply
        self.assertEqual(
            conn.execute("SELECT shares FROM holdings").fetchone()["shares"], 3000)


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

    def test_username_failures_from_other_ips_cannot_lock_the_real_user_out(self):
        # 5 wrong passwords against someone's username used to lock the account for
        # everyone - a one-line denial-of-service on the real user. Only the (much higher)
        # per-username threshold may lock by name; the per-IP one must not transfer.
        self.cfg["maxLoginFailures"] = 3
        self.cfg["maxLoginFailuresPerUser"] = 10
        self.mkuser("frank")
        for i in range(9):   # 9 failures spread over distinct attacker IPs
            auth.record_attempt(self.conn, "6.6.6.%d" % i, "frank", False)
        self.conn.commit()
        self.assertFalse(auth.is_locked_out(self.conn, self.cfg, "1.2.3.4", "frank"))
        token, _ = auth.login(self.conn, self.cfg, "frank", "correct-horse-1", "1.2.3.4", "ua")
        self.assertIsNotNone(auth.resolve_session(self.conn, self.cfg, token))
        # ...but the distributed-brute-force bound still exists
        auth.record_attempt(self.conn, "6.6.6.99", "frank", False)
        self.conn.commit()
        self.assertTrue(auth.is_locked_out(self.conn, self.cfg, "1.2.3.4", "frank"))

    def test_ip_failures_lock_regardless_of_username(self):
        self.cfg["maxLoginFailures"] = 3
        self.cfg["maxLoginFailuresPerUser"] = 10
        for i in range(3):   # one IP hammering different usernames
            auth.record_attempt(self.conn, "7.7.7.7", "guess-%d" % i, False)
        self.conn.commit()
        self.assertTrue(auth.is_locked_out(self.conn, self.cfg, "7.7.7.7", "anything"))
        self.assertFalse(auth.is_locked_out(self.conn, self.cfg, "8.8.8.8", "anything"))

    def test_password_change_invalidates_sessions(self):
        uid = self.mkuser("erin")
        token, _ = auth.login(self.conn, self.cfg, "erin", "correct-horse-1", "1.1.1.1", "ua")
        auth.set_password(self.conn, uid, "brand-new-password")
        self.assertIsNone(auth.resolve_session(self.conn, self.cfg, token))

    def test_changing_password_is_throttled_like_login(self):
        # an authenticated session used to be an unlimited oracle for the current password:
        # change_password verified inline, recorded no attempt and consulted no lockout
        self.cfg["maxLoginFailures"] = 3
        uid = self.mkuser("gus")
        user = self.conn.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
        for _ in range(3):
            with self.assertRaises(auth.AuthError) as ctx:
                api.change_password(FakeCtx(
                    self.conn, self.cfg, user,
                    {"current": "wrong-password-9", "new": "another-good-password"},
                    ip="5.5.5.5"))
            self.assertEqual(ctx.exception.status, 403)
        with self.assertRaises(auth.AuthError) as ctx:
            api.change_password(FakeCtx(
                self.conn, self.cfg, user,
                {"current": "correct-horse-1", "new": "another-good-password"},
                ip="5.5.5.5"))
        self.assertEqual(ctx.exception.status, 429)   # right password, still throttled

    def test_registration_rollback_refuses_a_live_account(self):
        # the rollback path is a raw delete on `users`; it must not become a way to remove a
        # real account (least of all the owner's) if it is ever called with the wrong id
        owner = self.mkuser("boss", tier="owner")
        active = self.mkuser("hana")
        for uid in (owner, active):
            with self.assertRaises(auth.AuthError):
                auth.rollback_registration(self.conn, uid)
            self.assertIsNotNone(
                self.conn.execute("SELECT 1 FROM users WHERE id = ?", (uid,)).fetchone())
        pending = self.mkuser("iris", status="pending")
        auth.rollback_registration(self.conn, pending)
        self.assertIsNone(
            self.conn.execute("SELECT 1 FROM users WHERE id = ?", (pending,)).fetchone())


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
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (uid, "2330", "台積電", 1))
        self.conn.commit()
        auth.delete_user(self.conn, uid)
        left = self.conn.execute(
            "SELECT COUNT(*) AS n FROM holdings WHERE user_id = ?", (uid,)).fetchone()["n"]
        self.assertEqual(left, 0)


class TestGuestPlusTier(Base):
    """guest_plus grants a per-account upgrade to Claude-quality, portfolio-blind analysis for
    that account's own codes, capped in aggregate (cfg['guestPlusCodeBudget']) so the owner can
    grant it freely without an unbounded Claude-cost blowup."""

    def test_grant_and_revoke_round_trip(self):
        uid = self.mkuser("kate")
        auth.set_tier(self.conn, self.cfg, uid, "guest_plus", actor_id=1)
        self.assertEqual(auth.find_user(self.conn, "kate")["tier"], "guest_plus")
        auth.set_tier(self.conn, self.cfg, uid, "guest", actor_id=1)
        self.assertEqual(auth.find_user(self.conn, "kate")["tier"], "guest")

    def test_owner_tier_is_immutable(self):
        uid = self.mkuser("owner1", tier="owner")
        with self.assertRaises(auth.AuthError):
            auth.set_tier(self.conn, self.cfg, uid, "guest_plus")

    def test_only_guest_and_guest_plus_are_settable(self):
        uid = self.mkuser("leo")
        with self.assertRaises(auth.AuthError):
            auth.set_tier(self.conn, self.cfg, uid, "owner")   # no self-promotion to owner
        with self.assertRaises(auth.AuthError):
            auth.set_tier(self.conn, self.cfg, uid, "bogus")

    def test_grant_refused_once_budget_is_full(self):
        self.cfg["guestPlusCodeBudget"] = 1
        a = self.mkuser("alice")
        b = self.mkuser("bob")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (a, "2330", "x", 1))
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (b, "2454", "x", 1))
        self.conn.commit()
        auth.set_tier(self.conn, self.cfg, a, "guest_plus")
        with self.assertRaises(auth.AuthError) as ctx:
            auth.set_tier(self.conn, self.cfg, b, "guest_plus")
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(auth.find_user(self.conn, "bob")["tier"], "guest")   # refusal, not partial grant

    def test_code_the_owner_already_holds_does_not_use_up_budget(self):
        owner_id = self.mkuser("owner1", tier="owner")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (owner_id, "0050", "x", 1))
        self.cfg["guestPlusCodeBudget"] = 0
        a = self.mkuser("alice")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (a, "0050", "x", 1))
        self.conn.commit()
        auth.set_tier(self.conn, self.cfg, a, "guest_plus")   # adds nothing new -> must not be refused
        self.assertEqual(auth.find_user(self.conn, "alice")["tier"], "guest_plus")

    def test_holding_added_after_grant_can_silently_miss_the_budget_rather_than_error(self):
        """set_tier only gates the grant itself. A guest_plus adding a holding afterward is a
        normal holdings-edit call with no budget check in its path - payload.py's daily
        selection is what actually enforces the cap, by just not promoting the overflow code."""
        self.cfg["guestPlusCodeBudget"] = 1
        a = self.mkuser("alice")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (a, "2330", "x", 1))
        self.conn.commit()
        auth.set_tier(self.conn, self.cfg, a, "guest_plus")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (a, "2454", "x", 1))
        self.conn.commit()
        in_budget = payload.guest_plus_codes_in_budget(self.conn, self.cfg["guestPlusCodeBudget"])
        self.assertEqual(len(in_budget), 1)   # the cap held...
        self.assertEqual(len(payload.guest_plus_codes_ranked(self.conn)), 2)   # ...only by dropping one

    def test_migration_preserves_ids_and_autoincrement_does_not_collide(self):
        path = os.path.join(self.tmp, "legacy_tier.db")
        conn = db.connect(path)
        conn.executescript(
            "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE,"
            " display_name TEXT NOT NULL DEFAULT '', pw_hash TEXT NOT NULL, pw_salt TEXT NOT NULL,"
            " tier TEXT NOT NULL DEFAULT 'guest' CHECK (tier IN ('owner','guest')),"
            " status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','suspended')),"
            " note TEXT NOT NULL DEFAULT '', reg_ip TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,"
            " approved_at TEXT, approved_by INTEGER, last_login_at TEXT);"
        )
        conn.execute(
            "INSERT INTO users (id, username, pw_hash, pw_salt, tier, status, created_at) "
            "VALUES (5, 'legacy', 'h', 's', 'guest', 'active', '2026-01-01T00:00:00Z')"
        )
        conn.commit()
        conn.close()
        db.close_all()

        conn = db.init_schema(path)
        row = conn.execute("SELECT id FROM users WHERE username = 'legacy'").fetchone()
        self.assertEqual(row["id"], 5)   # sessions/holdings pointing at id=5 must still resolve
        conn.execute("UPDATE users SET tier = 'guest_plus' WHERE id = 5")   # CHECK now allows it
        conn.commit()
        new_id = auth.create_user(conn, "fresh", "correct-horse-1")
        self.assertGreater(new_id, 5)   # autoincrement did not reset and collide with id 5

    def test_migration_is_a_no_op_on_an_already_migrated_db(self):
        db.migrate_tier_check(self.conn)   # setUp already ran init_schema once
        self.conn.execute("SELECT 1 FROM users")   # table still usable, nothing corrupted

    def test_admin_api_grants_tier_and_reports_budget(self):
        owner_id = self.mkuser("owner1", tier="owner")
        owner = auth.find_user(self.conn, "owner1")
        target_id = self.mkuser("mia")

        status, body = api.admin_action(
            FakeCtx(self.conn, self.cfg, owner, body={"action": "set_tier", "id": target_id, "tier": "guest_plus"})
        )
        self.assertEqual(status, 200)
        self.assertEqual(auth.find_user(self.conn, "mia")["tier"], "guest_plus")

        status, body = api.admin_users(FakeCtx(self.conn, self.cfg, owner))
        self.assertEqual(body["guestPlusBudget"], {"used": 0, "cap": self.cfg["guestPlusCodeBudget"]})

    def test_admin_api_non_owner_cannot_set_tier(self):
        self.mkuser("owner1", tier="owner")
        target_id = self.mkuser("nina")
        target = auth.find_user(self.conn, "nina")
        with self.assertRaises(api.ApiError) as ctx:
            api.admin_action(
                FakeCtx(self.conn, self.cfg, target, body={"action": "set_tier", "id": target_id, "tier": "guest_plus"})
            )
        self.assertEqual(ctx.exception.status, 403)


class TestGuestPlusCodeBudget(Base):
    def test_ranked_excludes_owner_codes_and_orders_earliest_grant_first(self):
        owner_id = self.mkuser("owner1", tier="owner")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (owner_id, "0050", "x", 1))
        a = self.mkuser("alice", tier="guest_plus")
        b = self.mkuser("bob", tier="guest_plus")
        for uid, code in ((a, "0050"), (a, "9999"), (b, "1101")):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (uid, code, "x", 1))
        # explicit timestamps: bob granted before alice, regardless of wall-clock test speed
        self.conn.execute(
            "INSERT INTO audit (ts, user_id, action, detail) VALUES (?,?,?,?)",
            ("2026-01-01T00:00:00Z", b, "set_tier", "tier=guest_plus by=1"))
        self.conn.execute(
            "INSERT INTO audit (ts, user_id, action, detail) VALUES (?,?,?,?)",
            ("2026-01-02T00:00:00Z", a, "set_tier", "tier=guest_plus by=1"))
        self.conn.commit()

        ranked = payload.guest_plus_codes_ranked(self.conn)
        self.assertNotIn("0050", ranked)             # the owner already covers it
        self.assertEqual(ranked, ["1101", "9999"])    # bob's earlier grant outranks alice's

    def test_budget_caps_the_ranked_list(self):
        a = self.mkuser("alice", tier="guest_plus")
        for code in ("1101", "2330", "9999"):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)", (a, code, "x", 1))
        self.conn.execute(
            "INSERT INTO audit (ts, user_id, action, detail) VALUES (?,?,?,?)",
            ("2026-01-01T00:00:00Z", a, "set_tier", "tier=guest_plus by=1"))
        self.conn.commit()
        self.assertEqual(payload.guest_plus_codes_in_budget(self.conn, 2), ["1101", "2330"])

    def test_plain_guest_codes_never_enter_the_ranking(self):
        self.mkuser("owner1", tier="owner")
        guest_id = self.mkuser("plain_guest")   # tier stays 'guest', never granted
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (guest_id, "2330", "x", 1))
        self.conn.commit()
        self.assertEqual(payload.guest_plus_codes_ranked(self.conn), [])


class TestTiers(Base):
    NOTES = {
        "_market": {"mood": "偏多", "windLead": "大盤收紅",
                    "wind": "投組今日明顯分化：00990A(+0.96%)與00981A(+0.67%)靠外資續買收紅"},
        "0050": {"sigFund": ["neu", "中性"], "tech": "站上月線", "chip": "外資買超",
                 "fund": "追蹤大盤", "rec": "建議續抱兩成部位", "news": [{"t": "x", "u": "http://a"}]},
    }

    def test_guest_gets_factual_fields_but_not_owner_advice(self):
        # private_codes={"0050"}: this is the owner's own holding, same as a real bootstrap()
        # call would pass - without it there is nothing to distinguish "0050" from a
        # guest_plus-budgeted code, whose rec IS meant to be shared (see TestGuestPlusTier).
        got = payload.notes_for("guest", ["0050"], self.NOTES, private_codes={"0050"})
        self.assertEqual(got["0050"]["tech"], "站上月線")
        self.assertNotIn("rec", got["0050"])    # portfolio-level advice is owner-only
        self.assertNotIn("news", got["0050"])
        self.assertIn("_market", got)           # market view is genuinely shared

    def test_market_commentary_naming_owner_holdings_is_not_shared(self):
        got = payload.notes_for("guest", ["0050"], self.NOTES, private_codes={"0050"})
        # `wind` is written about the owner's portfolio and names real holdings
        self.assertNotIn("wind", got["_market"])
        self.assertNotIn("00990A", json.dumps(got, ensure_ascii=False))
        self.assertEqual(got["_market"]["windLead"], "大盤收紅")   # the market-level part survives
        self.assertIn("wind", payload.notes_for("owner", [], self.NOTES, ())["_market"])

    def test_note_naming_another_owner_holding_is_dropped(self):
        notes = {"0050": {
            "tech": "站上月線",                                   # clean - kept
            "fund": "成分股與 00947/00981A 高度重疊",              # names other holdings - dropped
        }}
        got = payload.notes_for("guest", ["0050"], notes, private_codes={"0050", "00947", "00981A"})
        self.assertIn("tech", got["0050"])
        self.assertNotIn("fund", got["0050"])

    def test_guest_plus_budgeted_code_rec_is_shared_but_owners_own_rec_is_not(self):
        notes = {
            "0050": {"tech": "站上月線", "rec": "owner 專屬建議"},                          # owner's own
            "2603": {"tech": "散裝景氣回升", "rec": "若站回月線則觀察轉多。"},   # guest_plus code
        }
        got = payload.notes_for("guest", ["0050", "2603"], notes, private_codes={"0050"})
        self.assertNotIn("rec", got["0050"])
        self.assertEqual(got["2603"]["rec"], "若站回月線則觀察轉多。")

    def test_guest_plus_code_rec_still_respects_the_other_holding_filter(self):
        notes = {"2603": {"rec": "與 0050 同步操作。"}}
        got = payload.notes_for("guest", ["2603"], notes, private_codes={"0050"})
        self.assertNotIn("rec", got.get("2603", {}))

    def test_filter_does_not_trip_on_prices_or_the_notes_own_code(self):
        notes = {"0050": {"tech": "0050 收 44,850.81 點、成交 9,306 億、融資 5,637 張"}}
        got = payload.notes_for("guest", ["0050"], notes, private_codes={"0050", "00947"})
        self.assertIn("tech", got["0050"])   # numbers are not codes; own code is allowed

    def test_market_allowlist_keeps_new_fields_private_by_default(self):
        notes = {"_market": {"mood": "偏多", "somethingNew": "未來新增的欄位"}}
        got = payload.notes_for("guest", [], notes, private_codes={"0050"})
        self.assertNotIn("somethingNew", got["_market"])

    def test_owner_gets_everything(self):
        got = payload.notes_for("owner", ["0050"], self.NOTES, ())
        self.assertIn("rec", got["0050"])
        self.assertIn("news", got["0050"])

    def test_uncovered_code_yields_no_note_not_an_error(self):
        got = payload.notes_for("guest", ["9999"], self.NOTES, private_codes={"0050"})
        self.assertNotIn("9999", got)   # page falls back to '（尚無分析…）'


class TestGuestNoteMerge(Base):
    """Guests read Claude's factual fields where they exist and Gemini's everywhere else.
    `rec` always comes from Gemini: the owner's is written against the owner's portfolio."""

    CLAUDE = {"0050": {"sigFund": ["neu", "中性"], "tech": "Claude 技術", "chip": "Claude 籌碼",
                       "fund": "Claude 基本", "rec": "owner 專屬建議", "news": [{"t": "x"}]}}
    GEMINI = {
        "0050": {"sigFund": ["bull", "偏多"], "tech": "Gemini 技術", "chip": "Gemini 籌碼",
                 "fund": "Gemini 基本", "rec": "若跌破季線則減碼。"},
        "2330": {"sigFund": ["bear", "偏空"], "tech": "Gemini 技術", "chip": "Gemini 籌碼",
                 "fund": "Gemini 基本", "rec": "若站回月線則加碼。"},
    }

    def test_claude_wins_where_it_exists_and_rec_always_comes_from_gemini(self):
        # 0050 is the owner's own holding here (see test_rec_for_a_guest_plus_budgeted_code
        # above for the code NOT in private_codes, where Claude's rec is meant to win too).
        got = payload.notes_for("guest", ["0050"], self.CLAUDE, private_codes={"0050"}, guest_notes=self.GEMINI)
        self.assertEqual(got["0050"]["tech"], "Claude 技術")
        self.assertEqual(got["0050"]["sigFund"], ["neu", "中性"])
        self.assertEqual(got["0050"]["rec"], "若跌破季線則減碼。")
        self.assertNotIn("owner 專屬建議", json.dumps(got, ensure_ascii=False))
        self.assertNotIn("news", got["0050"])

    def test_code_the_owner_does_not_hold_is_fully_covered_by_gemini(self):
        got = payload.notes_for("guest", ["2330"], self.CLAUDE, private_codes={"0050"}, guest_notes=self.GEMINI)
        self.assertEqual(got["2330"]["tech"], "Gemini 技術")
        self.assertEqual(got["2330"]["rec"], "若站回月線則加碼。")

    def test_gemini_fills_a_field_that_the_privacy_filter_dropped(self):
        claude = {"0050": {"tech": "站上月線", "fund": "成分股與 00947 高度重疊"}}
        got = payload.notes_for("guest", ["0050"], claude,
                                private_codes={"0050", "00947"}, guest_notes=self.GEMINI)
        self.assertEqual(got["0050"]["tech"], "站上月線")       # clean Claude field kept
        self.assertEqual(got["0050"]["fund"], "Gemini 基本")    # dropped one filled, not blank
        self.assertNotIn("00947", json.dumps(got, ensure_ascii=False))

    def test_owner_never_sees_gemini_notes(self):
        got = payload.notes_for("owner", ["0050"], self.CLAUDE, private_codes=(), guest_notes=self.GEMINI)
        self.assertEqual(got["0050"]["tech"], "Claude 技術")
        self.assertEqual(got["0050"]["rec"], "owner 專屬建議")


class TestBootstrapPrivacyWiring(Base):
    """The gap this class exists to close: every test above calls notes_for() directly, so all of
    them verified the filter and none of them verified that bootstrap() *uses* it. `holdingsNotes`
    appeared nowhere in this file, and payload.bootstrap() resolved holdings-notes.json against
    the repo root, so there was no way to hand it a fixture. Passing () for private_codes there
    would have leaked every owner rec to every guest with the whole suite green."""

    NOTES = {
        "_market": {"mood": "偏多", "windLead": "大盤收紅",
                    "wind": "投組今日分化：00990A 靠外資續買收紅"},
        "0050": {"tech": "站上月線", "chip": "外資買超", "fund": "追蹤大盤",
                 "rec": "建議續抱兩成部位", "news": [{"t": "x", "u": "http://a"}]},
        "2330": {"tech": "季線之上", "fund": "成分股與 0050 高度重疊"},
    }

    def setUp(self):
        super().setUp()
        self.cfg["notesDir"] = self.tmp
        with open(os.path.join(self.tmp, "holdings-notes.json"), "w", encoding="utf-8") as fh:
            json.dump(self.NOTES, fh, ensure_ascii=False)
        with open(os.path.join(self.cfg["dataDir"], "quotes.json"), "w", encoding="utf-8") as fh:
            json.dump({"TAIEX": [], "0050": {"series": []}, "2330": {"series": []}}, fh)
        owner = self.mkuser("owner_acct", tier="owner")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (owner, "0050", "x", 1000))
        self.conn.commit()

    def _boot_for(self, name, tier):
        uid = self.mkuser(name, tier=tier)
        for code in ("0050", "2330"):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
                (uid, code, "x", 1000))
        self.conn.commit()
        user = self.conn.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
        return payload.bootstrap(self.conn, self.cfg, user)

    def test_guest_bootstrap_never_carries_owner_advice(self):
        notes = self._boot_for("gwen", "guest")["holdingsNotes"]
        blob = json.dumps(notes, ensure_ascii=False)
        self.assertEqual(notes["0050"]["tech"], "站上月線")   # factual fields still arrive
        self.assertNotIn("rec", notes["0050"])
        self.assertNotIn("news", notes["0050"])
        self.assertNotIn("建議續抱兩成部位", blob)
        self.assertNotIn("wind", notes.get("_market", {}))
        self.assertNotIn("00990A", blob)
        # 2330's fund text names the owner's 0050, so the whole field goes
        self.assertNotIn("0050 高度重疊", blob)

    def test_owner_bootstrap_still_gets_the_unfiltered_analysis(self):
        uid = self.conn.execute(
            "SELECT id FROM users WHERE tier = 'owner'").fetchone()["id"]
        user = self.conn.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
        notes = payload.bootstrap(self.conn, self.cfg, user)["holdingsNotes"]
        self.assertEqual(notes["0050"]["rec"], "建議續抱兩成部位")
        self.assertIn("wind", notes["_market"])

    def test_notes_for_cannot_be_called_without_a_privacy_set(self):
        # the omission that used to mean "publish everything"
        with self.assertRaises(TypeError):
            payload.notes_for("guest", ["0050"], self.NOTES)


class TestGeminiResponseParsing(Base):
    """Model output is untrusted: only asked-for codes, only known fields, capped and cleaned."""

    def _reply(self, notes):
        return json.dumps({"notes": notes}, ensure_ascii=False)

    def test_good_reply_is_accepted(self):
        got = gnotes.parse_response(self._reply([{
            "code": "2330", "sigFund": ["bull", "偏多"], "tech": "t", "chip": "c", "fund": "f",
            "rec": "若跌破月線則減碼。"}]), ["2330"])
        self.assertEqual(got["2330"]["sigFund"], ["bull", "偏多"])
        self.assertEqual(got["2330"]["rec"], "若跌破月線則減碼。")

    def test_a_code_we_did_not_ask_about_is_refused(self):
        got = gnotes.parse_response(self._reply([{
            "code": "9999", "sigFund": ["bull", "x"], "tech": "t", "chip": "c", "fund": "f",
            "rec": "r"}]), ["2330"])
        self.assertEqual(got, {})

    def test_fields_are_cleaned_and_capped(self):
        got = gnotes.parse_response(self._reply([{
            "code": "2330", "sigFund": ["nonsense", "x"], "tech": "台積\x00電\x1f",
            "chip": "c" * 999, "fund": "", "rec": "沒有結尾"}]), ["2330"])
        note = got["2330"]
        self.assertEqual(note["tech"], "台積電")                    # control chars stripped
        self.assertEqual(len(note["chip"]), gnotes.MAX_FIELD)       # capped
        self.assertNotIn("fund", note)                             # empty dropped
        self.assertNotIn("sigFund", note)                          # bad direction dropped
        self.assertEqual(note["rec"], "沒有結尾")                   # rec passes through verbatim

    def test_garbage_reply_yields_nothing_rather_than_throwing(self):
        for bad in ("not json at all", "{}", '{"notes": "wrong type"}', '{"notes":[1,2]}'):
            self.assertEqual(gnotes.parse_response(bad, ["2330"]), {})

    def test_prompt_data_section_is_exactly_what_we_passed_in(self):
        """The prompt's data half must be the exchange numbers and nothing else - no holder,
        no portfolio, and above all nothing a user typed."""
        rows = [{"code": "2330", "name": "台積電", "price": 1000.0}]
        data = gnotes.build_prompt(rows).split("分析下列")[1]
        self.assertEqual(json.loads(data[data.index("["):]), rows)


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
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (owner_id, "0050", "元大台灣50", 1))
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
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
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
                (uid, code, "x", 1))
        self.conn.commit()
        codes = payload.active_codes(self.conn, self.cfg)
        # free TWSE fetch: yes. AI input: no (previous test).
        self.assertIn("2330", codes)
        self.assertIn("0050", codes)

    def test_suspended_users_drop_out_of_the_daily_fetch(self):
        guest_id = self.mkuser("guest1")
        self.conn.execute(
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (guest_id, "2330", "台積電", 1))
        self.conn.commit()
        auth.set_status(self.conn, guest_id, "suspended")
        self.assertNotIn("2330", payload.active_codes(self.conn, self.cfg))

    def test_distinct_code_cap_is_enforced(self):
        self.cfg["maxDistinctCodes"] = 2
        uid = self.mkuser("guest1")
        for code in ("1101", "1102", "1103", "1104"):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
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

    def test_shares_and_prices(self):
        self.assertEqual(validate.shares("3"), 3)
        self.assertEqual(validate.shares("1500"), 1500)   # odd lots are the point of shares
        for bad in ("0", "-1", "abc", None, str(validate.MAX_SHARES + 1)):
            with self.assertRaises(validate.Invalid):
                validate.shares(bad)
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


class TestOfficialNames(Base):
    def _write_names(self, mapping):
        with open(os.path.join(self.cfg["dataDir"], "names.json"), "w", encoding="utf-8") as fh:
            json.dump(mapping, fh, ensure_ascii=False)
        payload._NAMES_CACHE["mtime"] = None   # same-second rewrites in tests

    def test_upsert_fills_in_the_official_name_but_never_overrides_a_typed_one(self):
        self._write_names({"2330": "台積電", "1101": "台泥"})
        user = auth.find_user(self.conn, self.mkuser("nora") and "nora")
        # no name typed -> exchange name, not a bare code
        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "upsert", "code": "2330", "shares": 1000}))
        # the front-end sends name=code when the field is left blank; that is not a real name
        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "upsert", "code": "1101", "name": "1101", "shares": 1000}))
        # a genuinely typed name wins
        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "upsert", "code": "1102", "name": "我的亞泥", "shares": 1000}))
        got = {r["code"]: r["name"] for r in payload.user_holdings(self.conn, user["id"])}
        self.assertEqual(got, {"2330": "台積電", "1101": "台泥", "1102": "我的亞泥"})

    def test_missing_names_file_is_not_an_error(self):
        user = auth.find_user(self.conn, self.mkuser("olga") and "olga")
        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "upsert", "code": "2330", "shares": 1000}))
        got = {r["code"]: r["name"] for r in payload.user_holdings(self.conn, user["id"])}
        self.assertEqual(got, {"2330": "2330"})   # falls back to the code, no crash

    def test_backfill_only_touches_rows_that_never_got_a_name(self):
        uid = self.mkuser("pete")
        for code, name in (("2330", "2330"), ("1101", ""), ("1102", "我的亞泥")):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
                (uid, code, name, 1000))
        self.conn.commit()
        self._write_names({"2330": "台積電", "1101": "台泥", "1102": "亞泥"})
        admin.cmd_backfill_names(self.cfg, self.conn, [])
        got = {r["code"]: r["name"] for r in payload.user_holdings(self.conn, uid)}
        self.assertEqual(got, {"2330": "台積電", "1101": "台泥", "1102": "我的亞泥"})


class TestHoldingsApi(Base):
    def test_upsert_remove_and_cap(self):
        uid = self.mkuser("kate")
        user = auth.find_user(self.conn, "kate")
        for code in ("1101", "1102", "1103"):
            api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                      {"action": "upsert", "code": code, "shares": 1000}))
        with self.assertRaises(api.ApiError) as exc:
            api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                      {"action": "upsert", "code": "1104", "shares": 1000}))
        self.assertEqual(exc.exception.status, 409)   # maxCodesPerUser = 3 in test cfg

        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "upsert", "code": "1101", "shares": 7500}))
        row = self.conn.execute(
            "SELECT shares FROM holdings WHERE user_id = ? AND code = '1101'", (uid,)).fetchone()
        self.assertEqual(row["shares"], 7500)         # upsert updates, not duplicates

        api.post_holdings(FakeCtx(self.conn, self.cfg, user,
                                  {"action": "remove", "code": "1101"}))
        self.assertEqual(len(payload.user_holdings(self.conn, uid)), 2)

    def test_user_cannot_delete_another_users_trade(self):
        victim = self.mkuser("liam")
        attacker = self.mkuser("mallory")
        cur = self.conn.execute(
            "INSERT INTO trades (user_id, d, side, code, shares, price) VALUES (?,?,?,?,?,?)",
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
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
                (uid, code, "x", 1))
        self.conn.commit()
        _status, out = api.bootstrap(FakeCtx(self.conn, self.cfg, user))
        self.assertIn("0050", out["holdingsMeta"])
        self.assertNotIn("2330", out["holdingsMeta"])  # would crash DASH[code].series
        self.assertEqual(out["pendingCodes"], ["2330"])

    def test_bootstrap_carries_prev_stance_from_shared_meta(self):
        # _prevStance is a union-code map in the shared daily export, so a guest holding a
        # code the owner does not hold still gets yesterday's stance for the transition flag
        uid = self.mkuser("omar")
        user = auth.find_user(self.conn, "omar")
        with open(os.path.join(self.cfg["dataDir"], "quotes.json"), "w", encoding="utf-8") as fh:
            json.dump({"TAIEX": [], "0050": {"series": []}, "2330": {"series": []}}, fh)
        with open(os.path.join(self.cfg["dataDir"], "holdings-meta.json"), "w", encoding="utf-8") as fh:
            json.dump({"0050": {"name": "x"}, "_prevStance": {"0050": "hold", "2330": "defend"}}, fh)
        for code in ("0050", "2330"):
            self.conn.execute(
                "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
                (uid, code, "x", 1))
        self.conn.commit()
        _status, out = api.bootstrap(FakeCtx(self.conn, self.cfg, user))
        self.assertEqual(out["holdingsMeta"]["0050"]["prevStance"], "hold")
        self.assertEqual(out["holdingsMeta"]["2330"]["prevStance"], "defend")


def page_with_every_block(extra=""):
    """A stand-in index.html carrying every block the contract declares.

    build_shell/render_page fail closed on a marker that is not in the page, so a test template
    listing only the blocks it cares about no longer represents a page the server would accept.
    Generating from the contract also means a new block cannot be forgotten here.
    """
    parts = [
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
        "connect-src 'none'\">\n"
    ]
    for block_id in pagedata.block_ids():
        parts.append('<script id="%s">window.LEAK_%s=1;</script>\n' % (block_id, block_id))
    parts.append(extra)
    return "".join(parts)


def full_boot(**overrides):
    """A complete payload.bootstrap()-shaped dict. render_page now refuses a key it was told to
    render but was not given, so every BLOCK_SOURCES key has to be present (None is allowed and
    means 'this artifact is legitimately absent today')."""
    boot = {key: None for _block, key in server.BLOCK_SOURCES}
    boot["meta"] = {}
    boot["user"] = {}
    boot["pendingCodes"] = []
    boot.update(overrides)
    return boot


class TestShell(Base):
    def test_data_blocks_are_emptied_and_csp_relaxed(self):
        index = os.path.join(self.tmp, "index.html")
        with open(index, "w", encoding="utf-8") as fh:
            fh.write(page_with_every_block('<script id="app">console.log(1)</script>\n')
                     .replace('window.LEAK_dashdata=1;', 'window.DASH={"secret":1};')
                     .replace('window.LEAK_holdingsmeta=1;', 'window.HOLDINGS_META={"2330":{}};'))
        html = server.build_shell(index)
        self.assertNotIn("secret", html)          # never ship one portfolio to everyone
        self.assertNotIn("2330", html)
        self.assertIn("console.log(1)", html)     # app code untouched
        self.assertIn("connect-src 'self'", html)

    def test_render_injects_this_users_data_only(self):
        # META is a data block like every other one now, not a regex over the page's JS source
        # and a second regex over the 報告日期 markup - the page renders both strings from it.
        html = server.render_page(page_with_every_block(), full_boot(
            dash={"TAIEX": [1]},
            holdingsMeta={"2330": {"shares": 4000}},
            meta={"generated": "2026/07/23", "lastTrade": "2026-07-23"},
            user={"username": "nina", "tier": "guest"},
        ))
        self.assertIn('window.DASH={"TAIEX":[1]}', html)
        self.assertIn('"shares":4000', html)
        self.assertIn('"username":"nina"', html)
        self.assertIn('"lastTrade":"2026-07-23"', html)
        self.assertIn('"generated":"2026/07/23"', html)

    def test_shell_empties_every_block_the_contract_declares(self):
        # the old shell carried its own list of block ids; a block added to the pipeline but not
        # to that list would have shipped the static demo's copy to every logged-in user
        index = os.path.join(self.tmp, "index.html")
        with open(index, "w", encoding="utf-8") as fh:
            for block_id in pagedata.block_ids():
                fh.write('<script id="%s">window.LEAK_%s=1;</script>\n' % (block_id, block_id))
        html = server.build_shell(index)
        self.assertNotIn("LEAK_", html)

    def test_script_close_sequence_in_data_cannot_break_out(self):
        template = '<script id="holdingsmeta"></script>'
        html = pagedata.set_block(
            template, "holdingsmeta",
            {"2330": {"name": "</script><img src=x onerror=alert(1)>"}})
        # the only </script> in the output is the block's own closing tag
        self.assertEqual(html.count("</script>"), 1)
        self.assertIn("<\\/script>", html)

    def test_missing_artifacts_leave_blocks_empty_rather_than_crash(self):
        html = server.render_page(page_with_every_block(), full_boot(picks=None, eval=None))
        self.assertNotIn("window.PICKS_DATA", html)   # page's own fallbacks take over
        self.assertNotIn("window.EVAL", html)

    def test_a_block_the_payload_never_supplies_is_a_loud_error(self):
        # tokenusage shipped blank to every self-hosted user because render_page skipped a key
        # that was not there (6fc268a). Silence is the bug; a missing key must not render.
        boot = full_boot()
        del boot["tokenUsage"]
        with self.assertRaises(KeyError):
            server.render_page(page_with_every_block(), boot)

    def test_every_contract_block_is_wired_to_a_payload_key(self):
        covered = {b for b, _ in server.BLOCK_SOURCES} | set(server.SPECIAL_BLOCKS)
        self.assertEqual(covered, set(pagedata.block_ids()))

    def test_note_field_policy_comes_from_the_contract_not_a_copy(self):
        # payload.py used to hardcode these, so the contract governed what got published while
        # the live server shipped whatever this module said. tests.ps1 [9] asserts the same
        # lists on the PowerShell side; this is the Python half of that pair.
        self.assertEqual(pagedata.guest_note_fields(), ("sigFund", "tech", "chip", "fund"))
        self.assertEqual(pagedata.owner_only_fields(), ("rec", "news", "wind", "night"))
        self.assertEqual(pagedata.market_public_fields(),
                         ("windLead", "sox", "mood", "moodK"))
        # `night` is _market's second owner-only field: the overnight read is written as
        # 若X則Y against this portfolio's own levels, which is advice rather than a market fact.
        self.assertNotIn("night", pagedata.market_public_fields())
        # and no guest field may also be owner-only
        self.assertEqual(
            set(pagedata.guest_note_fields()) & set(pagedata.owner_only_fields()), set())

    def test_a_field_added_to_the_contract_reaches_notes_for(self):
        # the drift that had no detector: adding a field to noteFields.guest changed the demo
        # build and the publish gate, and did nothing on the live server
        notes = {"2330": {"tech": "t", "newField": "n"}}
        self.assertNotIn("newField", payload.notes_for("guest", ["2330"], notes, ("0050",)))
        original = pagedata.contract()["noteFields"]["guest"]
        try:
            pagedata.contract()["noteFields"]["guest"] = list(original) + ["newField"]
            got = payload.notes_for("guest", ["2330"], notes, ("0050",))
            self.assertEqual(got["2330"]["newField"], "n")
        finally:
            pagedata.contract()["noteFields"]["guest"] = original

    def test_splice_refuses_a_marker_the_page_does_not_have(self):
        # lib/pagedata.ps1 throws here; the Python port used to return the html unchanged, which
        # renders as a silently blank section instead of an error
        with self.assertRaises(ValueError):
            pagedata.splice("<p>no blocks here</p>", "dashdata", "window.DASH={};")
        with self.assertRaises(ValueError):
            pagedata.splice('<script id="dashdata">unclosed', "dashdata", "x")


class TestHttp(Base):
    """End-to-end over a real socket: cookies, headers, status codes."""

    def setUp(self):
        super().setUp()
        index = os.path.join(self.tmp, "index.html")
        with open(index, "w", encoding="utf-8") as fh:
            # every block, because build_shell now refuses a page the contract does not match
            fh.write(page_with_every_block("<p>頁面</p>")
                     .replace('window.LEAK_holdingsmeta=1;', 'window.HOLDINGS_META={"9999":{}};'))
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

    def test_icon_is_served_as_bytes_without_login(self):
        # every page <link>s it, including /login, so it has to work logged out - and it is
        # the only response here that is not text, which is what this actually guards
        icon = os.path.join(self.tmp, "apple-touch-icon.png")
        with open(icon, "wb") as fh:
            fh.write(b"\x89PNG\r\n\x1a\n" + b"fake")
        with urllib.request.urlopen(self.url("/apple-touch-icon.png")) as resp:
            blob = resp.read()
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.headers["Content-Type"], "image/png")
        self.assertTrue(blob.startswith(b"\x89PNG\r\n\x1a\n"))

    def test_icon_missing_is_404_not_500(self):
        status, body, _ = self.request("/apple-touch-icon.png")
        self.assertEqual(status, 404)
        self.assertFalse(body["ok"])

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
            "INSERT INTO holdings (user_id, code, name, shares) VALUES (?,?,?,?)",
            (uid, "0050", "元大台灣50", 3000))
        self.conn.commit()
        with open(os.path.join(self.cfg["dataDir"], "quotes.json"), "w", encoding="utf-8") as fh:
            json.dump({"TAIEX": [{"d": "7/1", "c": 1.0}], "0050": {"series": []}}, fh)
        cookie = self._login("quinn")
        req = urllib.request.Request(self.url("/"))
        req.add_header("Cookie", "sid=%s" % cookie)
        with urllib.request.urlopen(req) as resp:
            html = resp.read().decode()
        self.assertIn('window.HOLDINGS_META=', html)
        self.assertIn('"shares":3000', html)
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


class FakeCtx(server.Ctx):
    """server.Ctx without a socket: same authorisation code, injected state.

    This used to re-implement require_user/require_owner, so every "a guest cannot reach the
    admin routes" test was exercising the copy in this file - invert the real require_owner and
    they all still passed. Subclassing means the tests below now run the code the server runs;
    only session resolution and the cookie sink are replaced.
    """

    def __init__(self, conn, cfg, user=None, body=None, ip="127.0.0.1"):
        self.handler = None
        self.conn = conn
        self.cfg = cfg
        self.body = body if isinstance(body, dict) else {}
        self.ip = ip
        self.ua = "test"
        self.token = None
        self.cookie_set = None
        self._user = user
        self._resolved = True      # user is injected, never resolved from a session

    def set_session_cookie(self, token):
        self.cookie_set = token

    def clear_session_cookie(self):
        self.cookie_set = ""


if __name__ == "__main__":
    unittest.main()
