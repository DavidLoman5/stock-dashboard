"""Assembles what a given user's page needs, out of shared daily artifacts plus their own
holdings.

The split that makes multi-user affordable:
  shared  - quotes/TAIEX (data/quotes.json), picks, eval, backtest, market mood. Fetched once
            per day for the union of everyone's codes; identical bytes for every user.
  personal- shares and trades (DB only). P/L, weights and concentration are derived client-side
            from shared quotes x personal shares, so nothing per-user is precomputed.

TOKEN ISOLATION (hard rule): nothing in this module can trigger an AI call. Guests read the
by-code analysis that the owner's daily run already produced as a by-product; a code nobody
has analysed simply has no note, and the page falls back to '（尚無分析，等待下次更新）'
while adviseHolding() still gives a stance from price/chip data alone.
"""

import json
import os

from . import config

# per-holding fields a guest may see: factual, code-level, portfolio-independent
GUEST_NOTE_FIELDS = ("sigFund", "tech", "chip", "fund")

# _market fields that are genuinely market-wide. `wind` is deliberately NOT here: the daily
# prompt writes it as commentary on the owner's portfolio ("投組今日明顯分化：00990A…"), so it
# names real holdings. buildWind() renders fine without it - it falls back to windLead alone.
# This is an allowlist, not a blocklist, so a new field added upstream stays private by default.
MARKET_PUBLIC_FIELDS = ("windLead", "sox", "mood", "moodK")


def _read_json(path, default=None):
    """Never let one bad/missing artifact blank the whole page - callers get the default."""
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def _root(*parts):
    return os.path.join(config.ROOT, *parts)


# data/names.json (whole market, written by screen.ps1) is read on nearly every holdings write,
# so keep it in memory and only re-read when the daily run replaces the file.
_NAMES_CACHE = {"mtime": None, "map": {}}


def official_names(cfg):
    """code -> official Chinese name. Exchange data, never user input, so it is safe both to
    display and to auto-fill with; a missing file just means 'no name known yet'."""
    path = os.path.join(cfg["dataDir"], "names.json")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return {}
    if _NAMES_CACHE["mtime"] != mtime:
        data = _read_json(path, {})
        _NAMES_CACHE["map"] = data if isinstance(data, dict) else {}
        _NAMES_CACHE["mtime"] = mtime
    return _NAMES_CACHE["map"]


def official_name(cfg, code, fallback=""):
    name = official_names(cfg).get(code)
    return name if isinstance(name, str) and name.strip() else fallback


def _display_name(user):
    """sqlite3.Row raises on an unknown key, and a row can predate the display_name
    migration, so ask the row what it has rather than assuming."""
    if "display_name" in user.keys():
        return user["display_name"] or user["username"]
    return user["username"]


def user_holdings(conn, user_id):
    return conn.execute(
        "SELECT code, name, shares, type, theme, tech_like, color FROM holdings "
        "WHERE user_id = ? ORDER BY code",
        (user_id,),
    ).fetchall()


def user_trades(conn, user_id):
    return conn.execute(
        "SELECT d, side, code, shares, price FROM trades WHERE user_id = ? ORDER BY d, id",
        (user_id,),
    ).fetchall()


def holdings_meta(conn, user_id, div_notes=None, prev_stance=None):
    """Same shape as window.HOLDINGS_META that update-holdings.ps1 splices into the static page,
    so the front-end needs no branch for where it came from."""
    div_notes = div_notes or {}
    prev_stance = prev_stance or {}
    meta = {"_trades": [dict(t) for t in user_trades(conn, user_id)]}
    for h in user_holdings(conn, user_id):
        meta[h["code"]] = {
            "name": h["name"],
            "type": h["type"],
            "theme": h["theme"],
            "shares": h["shares"],
            "color": h["color"],
            "techLike": bool(h["tech_like"]),
            "divNote": div_notes.get(h["code"]),
            # yesterday's rule-engine stance (code-level, from the shared daily export);
            # the page flags today-vs-yesterday transitions
            "prevStance": prev_stance.get(h["code"]),
        }
    return meta


def owner_codes(conn):
    rows = conn.execute(
        "SELECT h.code FROM holdings h JOIN users u ON u.id = h.user_id WHERE u.tier = 'owner'"
    ).fetchall()
    return {r["code"] for r in rows}


def _mentions_other_holding(text, own_code, private_codes):
    """True if free text names one of the owner's OTHER holdings.

    The daily notes are written with the whole portfolio in view, so a per-code note can say
    things like '成分股與0050/00947/00981A高度重疊' - factual about the ETF, but it discloses
    what the owner holds. Matching against the actual owner code list (rather than a generic
    'looks like a stock code' regex) means no false positives on prices or index levels.
    """
    text = str(text or "")
    return any(c != own_code and c in text for c in private_codes)


def notes_for(tier, codes, all_notes, private_codes=(), guest_notes=None):
    """Owner sees their own full daily analysis, untouched.

    A guest's page is assembled from two sources:
      * the owner's Claude notes, code-level factual fields only, and only where the text does
        not name another owner holding (that check is fail-closed - the field is dropped)
      * Gemini's per-code notes (guest-notes.json), which cover every code anyone holds

    Claude's fields win where both exist: they are the better analysis and were paid for anyway.
    Gemini fills the gaps - which is the whole point, since a code the owner does not hold has
    no Claude note at all and used to render as '（尚無分析）'.

    `rec` is the exception and always comes from Gemini: the owner's rec is advice written
    against the owner's portfolio, so it neither transfers nor may be disclosed.
    """
    all_notes = all_notes or {}
    guest_notes = guest_notes or {}
    out = {}
    market = all_notes.get("_market")
    if isinstance(market, dict):
        if tier == "owner":
            out["_market"] = market
        else:
            slim = {k: market[k] for k in MARKET_PUBLIC_FIELDS if k in market}
            if slim:
                out["_market"] = slim
    for code in codes:
        note = all_notes.get(code)
        if tier == "owner":
            if isinstance(note, dict):
                out[code] = note
            continue
        merged = {}
        gnote = guest_notes.get(code)
        if isinstance(gnote, dict):
            merged.update({k: gnote[k] for k in GUEST_NOTE_FIELDS if k in gnote})
            if gnote.get("rec"):
                merged["rec"] = gnote["rec"]
        if isinstance(note, dict):
            merged.update({
                k: note[k] for k in GUEST_NOTE_FIELDS
                if k in note and not _mentions_other_holding(note[k], code, private_codes)
            })
        if merged:
            out[code] = merged
    return out


def bootstrap(conn, cfg, user):
    """Everything index.html needs, in one response."""
    data_dir = cfg["dataDir"]
    quotes = _read_json(os.path.join(data_dir, "quotes.json"), {}) or {}
    meta = _read_json(os.path.join(data_dir, "meta.json"), {}) or {}
    picks = _read_json(os.path.join(data_dir, "picks.json"), None)
    picks_kline = _read_json(os.path.join(data_dir, "picks-kline.json"), None)
    picks_notes = _read_json(_root("picks-notes.json"), {}) or {}
    all_notes = _read_json(_root("holdings-notes.json"), {}) or {}
    # Gemini's per-code analysis (server/gnotes.py). Only guests read it; missing file just means
    # the step has not run yet, and notes_for() then behaves exactly as it did before.
    guest_notes = {} if user["tier"] == "owner" else (_read_json(_root("guest-notes.json"), {}) or {})
    eval_report = _read_json(_root("eval-report.json"), None)
    # backtest-card.json is the page-card shape ({rows:[...]}) that backtest.ps1 splices into the
    # static page. backtest-result.json is the raw research output (grid/current/bestOOS) and has
    # no `rows`, so buildBacktest() silently rendered nothing from it - hence the fallback order.
    backtest = _read_json(_root("backtest-card.json"), None)
    if not isinstance(backtest, dict) or not backtest.get("rows"):
        backtest = None

    # divNote lives in the daily meta export; reuse the owner run's values (they are per-code
    # ex-dividend facts, not personal)
    shared_meta = _read_json(os.path.join(data_dir, "holdings-meta.json"), {}) or {}
    div_notes = {
        c: v.get("divNote")
        for c, v in shared_meta.items()
        if isinstance(v, dict) and v.get("divNote")
    }
    # _prevStance is a union-code map (all users' codes), so guests get transition flags
    # for codes the owner does not hold
    prev_stance = shared_meta.get("_prevStance") or {}
    if not isinstance(prev_stance, dict):
        prev_stance = {}

    codes = [h["code"] for h in user_holdings(conn, user["id"])]
    dash = {"TAIEX": quotes.get("TAIEX", [])}
    missing = []
    for code in codes:
        if code in quotes:
            dash[code] = quotes[code]
        else:
            # newly added code: quotes arrive after the next daily run. The page would throw
            # on DASH[code].series, so drop it from meta rather than ship a broken payload.
            missing.append(code)

    hmeta = holdings_meta(conn, user["id"], div_notes, prev_stance)
    for code in missing:
        hmeta.pop(code, None)

    return {
        "user": {
            "username": user["username"],
            "displayName": _display_name(user),
            "tier": user["tier"],
            "status": user["status"],
        },
        "meta": meta,
        "pendingCodes": missing,
        "dash": dash,
        "holdingsMeta": hmeta,
        "holdingsNotes": notes_for(
            user["tier"], codes, all_notes,
            () if user["tier"] == "owner" else owner_codes(conn),
            guest_notes,
        ),
        "picks": picks,
        "picksKline": picks_kline,
        "picksNotes": picks_notes,
        "eval": eval_report,
        "backtest": backtest,
    }


# ------------------------------------------------------------------ exports for the daily run

def active_codes(conn, cfg):
    """Union of every non-suspended user's codes, plus the demo portfolio, so one fetch serves
    everyone. Capped so a flood of accounts cannot make the daily job unbounded."""
    rows = conn.execute(
        "SELECT DISTINCT h.code FROM holdings h JOIN users u ON u.id = h.user_id "
        "WHERE u.status = 'active' ORDER BY h.code"
    ).fetchall()
    codes = [r["code"] for r in rows]
    demo = _read_json(_root("holdings.json"), {}) or {}
    for h in demo.get("holdings", []):
        if h.get("code") and h["code"] not in codes:
            codes.append(h["code"])
    return codes[: cfg["maxDistinctCodes"]]


def owner_portfolio(conn):
    """The owner's holdings in holdings.json's exact shape, so update-holdings.ps1 can consume
    it with -HoldingsFile and the AI step keeps seeing only the owner's portfolio."""
    owner = conn.execute(
        "SELECT id FROM users WHERE tier = 'owner' ORDER BY id LIMIT 1"
    ).fetchone()
    if owner is None:
        return None
    return {
        "note": "Exported from the app DB by admin.py export-owner. Do not commit.",
        "holdings": [
            {
                "code": h["code"],
                "name": h["name"],
                "shares": h["shares"],
                "type": h["type"],
                "theme": h["theme"],
                "techLike": bool(h["tech_like"]),
            }
            for h in user_holdings(conn, owner["id"])
        ],
        "trades": [dict(t) for t in user_trades(conn, owner["id"])],
    }
