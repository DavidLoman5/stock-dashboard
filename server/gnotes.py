"""Per-code analysis for GUESTS, written by Gemini instead of Claude.

    python3 -m server.gnotes            write guest-notes.json from data/codes-context.json
    python3 -m server.gnotes --dry-run  build and print the prompt, call nothing

Why a second provider at all. The daily Claude run only ever analyses the owner's portfolio -
that is the rule that keeps this multi-user site affordable (CLAUDE.md: "token 只花在 owner
身上"). The consequence was that a guest holding something the owner does not hold saw
'（尚無分析，等待下次更新）' forever, and nobody but the owner ever saw a `rec`. Sending those
codes to Gemini's free tier fixes both without a guest ever costing a Claude token.

Two things this module must never do, both load-bearing:
  * feed it anything a user typed. Its whole input is data/codes-context.json, which
    update-holdings.ps1 builds from exchange numbers plus names from data/names.json. No
    user-supplied name or note is in there, so guest input cannot reach any AI prompt - which
    is also what keeps prompt injection away from the daily run's automatic `git push`.
  * disclose who holds what. The union code list says a code is held by *someone*; it never
    says by whom, and the owner's portfolio is not marked.

Model output is untrusted text. It is length-capped and stripped of control characters here,
and everything downstream escapes it (the page renders notes through esc(), server.py's _js()
escapes '</'), but the cleaning happens at the boundary rather than relying on that.
"""

import json
import os
import sys
import urllib.error
import urllib.request

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = "server"

from . import config, validate  # noqa: E402

OUT_NAME = "guest-notes.json"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
BATCH = 40                 # codes per request; the free tier's limit is requests/day, not size
TIMEOUT = 120
MAX_FIELD = 400            # characters; the page shows these in a card, not an essay
SIG_KINDS = ("bull", "neu", "bear")

SYSTEM = """你是台股分析助理。根據提供的每檔數值資料，為每一檔股票寫三面分析與一句操作觀點。

台股慣例：紅漲綠跌；法人買賣超與融資餘額單位為「張」；ETF 沒有 EPS 與本益比，基本面請以
成分題材與產業景氣替代。

欄位意義：price 收盤價、chg 漲跌、pct 漲跌%、ma20 月線、ma60 季線、ma20SlopeUp 月線是否上揚、
distFromHigh40 距 40 日高的百分比、foreignSum5d 外資近 5 日合計買賣超（張）、foreignLast2
外資最近兩日買賣超（張，後者為最新）、marginToday 融資餘額（張）、marginDelta 融資增減（張）、
divNote 近期除息日。

每一檔輸出這些欄位：
- sigFund: [方向, 12字內短語]，方向只能是 bull / neu / bear
- tech: 技術面 2-3 句。要引用 ma20 / ma60 的實際數字說明價格位置與月線斜率。
- chip: 籌碼面 2-3 句。外資連續買賣的方向與力道變化、融資是增是減，兩者合起來代表什麼。
- fund: 基本面 2-3 句。個股講產業與獲利結構；ETF 講成分題材與產業景氣。
- rec: 一句操作觀點，必須包含「若…則…」的條件句與至少一個取自 ma20/ma60 的具體價位。
  禁用「酌量」「視情況」「保持關注」這類沒有觸發條件的模糊詞。

硬性限制：
- 只根據提供的數字寫，不要引用你記憶中的新聞、財報或目標價，也不要編造。
- 每檔獨立描述，不要提到其他檔的代號，也不要說「投組」「持股組合」——你不知道誰持有什麼。
- 每個欄位不超過 200 字。用繁體中文。
"""

SCHEMA = {
    "type": "object",
    "properties": {
        "notes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "code": {"type": "string"},
                    "sigFund": {"type": "array", "items": {"type": "string"}},
                    "tech": {"type": "string"},
                    "chip": {"type": "string"},
                    "fund": {"type": "string"},
                    "rec": {"type": "string"},
                },
                "required": ["code", "sigFund", "tech", "chip", "fund", "rec"],
            },
        }
    },
    "required": ["notes"],
}


def _clean(value):
    """Untrusted model output -> something safe to store and show, or None."""
    if not isinstance(value, str):
        return None
    text = validate.CONTROL_RE.sub("", value).strip()
    if not text:
        return None
    return text[:MAX_FIELD]


def parse_response(text, wanted_codes):
    """Turn one model reply into {code: note}. Anything malformed is dropped, not guessed at:
    a missing note renders as '（尚無分析，等待下次更新）', which is the honest outcome."""
    try:
        data = json.loads(text)
    except ValueError:
        return {}
    notes = data.get("notes") if isinstance(data, dict) else None
    if not isinstance(notes, list):
        return {}
    wanted = set(wanted_codes)
    out = {}
    for item in notes:
        if not isinstance(item, dict):
            continue
        code = str(item.get("code") or "").strip().upper()
        if code not in wanted:
            continue          # never accept a code we did not ask about
        note = {}
        for field in ("tech", "chip", "fund", "rec"):
            cleaned = _clean(item.get(field))
            if cleaned:
                note[field] = cleaned
        sig = item.get("sigFund")
        if isinstance(sig, list) and len(sig) >= 2:
            kind = str(sig[0]).strip().lower()
            label = _clean(sig[1])
            if kind in SIG_KINDS and label:
                note["sigFund"] = [kind, label[:20]]
        if note:
            out[code] = note
    return out


def build_prompt(rows):
    return "%s\n分析下列 %d 檔：\n%s" % (
        SYSTEM, len(rows), json.dumps(rows, ensure_ascii=False, indent=1))


def call_gemini(api_key, model, prompt):
    body = json.dumps({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.4,
            "responseMimeType": "application/json",
            "responseSchema": SCHEMA,
        },
    }).encode("utf-8")
    req = urllib.request.Request(
        ENDPOINT % model, data=body,
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        payload = json.load(resp)
    candidates = payload.get("candidates") or []
    if not candidates:
        raise ValueError("Gemini 沒有回傳 candidates: %s" % json.dumps(payload)[:300])
    parts = candidates[0].get("content", {}).get("parts") or []
    return "".join(p.get("text", "") for p in parts)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    dry_run = "--dry-run" in argv
    cfg = config.load()
    api_key = (cfg.get("geminiApiKey") or os.environ.get("GEMINI_API_KEY") or "").strip()

    ctx_path = os.path.join(cfg["dataDir"], "codes-context.json")
    try:
        with open(ctx_path, "r", encoding="utf-8-sig") as fh:
            rows = json.load(fh)
    except (OSError, ValueError) as exc:
        print("跳過 guest notes：讀不到 %s（%s）" % (ctx_path, exc))
        return 0
    rows = [r for r in rows if isinstance(r, dict) and r.get("code")]
    if not rows:
        print("跳過 guest notes：codes-context.json 沒有可用資料")
        return 0

    if dry_run:
        print(build_prompt(rows[:BATCH]))
        return 0

    if not api_key:
        # Fail open, always: this runs inside the daily pipeline and a missing key is a
        # configuration state, not an error. Guests just keep seeing the owner's shared notes.
        print("跳過 guest notes：config.json 沒有 geminiApiKey（也沒有 GEMINI_API_KEY）")
        return 0

    model = cfg.get("geminiModel") or "gemini-3.6-flash"
    notes = {}
    for start in range(0, len(rows), BATCH):
        chunk = rows[start:start + BATCH]
        codes = [r["code"] for r in chunk]
        try:
            text = call_gemini(api_key, model, build_prompt(chunk))
        except (urllib.error.URLError, OSError, ValueError) as exc:
            print("  批次 %d 失敗（%s）——保留既有 %s" % (start // BATCH + 1, exc, OUT_NAME))
            continue
        got = parse_response(text, codes)
        print("  批次 %d：送 %d 檔，收到 %d 檔" % (start // BATCH + 1, len(chunk), len(got)))
        notes.update(got)

    if not notes:
        print("沒有任何可用結果——不覆寫 %s（舊的分析比空的好）" % OUT_NAME)
        return 0

    out_path = os.path.join(config.ROOT, OUT_NAME)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(notes, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, out_path)
    print("寫入 %s（%d 檔）" % (OUT_NAME, len(notes)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
