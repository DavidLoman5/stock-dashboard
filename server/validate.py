"""Input validation. Everything a user can type passes through here before it reaches the
DB or a template.

Two separate concerns:
  * structural validity (a stock code must look like a stock code)
  * keeping user text out of places it does not belong - specifically, holding names end up
    in the page via innerHTML (escaped by esc() client-side) and must never end up in an AI
    prompt, so we strip control characters and cap length here as defence in depth.
"""

import re

USERNAME_RE = re.compile(r"^[A-Za-z0-9_-]{3,24}$")
# TWSE/TPEx: 4-digit stocks (2330), 4-6 digit ETFs (0050, 00935), active ETFs suffixed A (00990A)
CODE_RE = re.compile(r"^[0-9]{4,6}[A-Za-z]?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

MIN_PASSWORD = 10
MAX_PASSWORD = 128
MAX_NAME = 30
MAX_NOTE = 200
MAX_LOTS = 100000
MAX_PRICE = 1000000.0


class Invalid(ValueError):
    """Raised with a user-facing (Chinese) message; the API turns it into a 400."""


def username(value):
    value = (value or "").strip()
    if not USERNAME_RE.match(value):
        raise Invalid("帳號需為 3-24 個英數字、底線或連字號")
    return value


def display_name(value):
    """Free text (spaces and CJK allowed) - it is only ever shown, never looked up.
    Empty is legal and means "just use the username"."""
    return text(value, MAX_NAME, "顯示名稱")


def password(value):
    value = value or ""
    if not (MIN_PASSWORD <= len(value) <= MAX_PASSWORD):
        raise Invalid("密碼長度需介於 %d-%d 字元" % (MIN_PASSWORD, MAX_PASSWORD))
    return value


def code(value):
    value = (value or "").strip().upper()
    if not CODE_RE.match(value):
        raise Invalid("股票代號格式不正確（例：2330、0050、00990A）")
    return value


def text(value, limit, field="欄位"):
    value = CONTROL_RE.sub("", str(value or "")).strip()
    if len(value) > limit:
        raise Invalid("%s 長度不可超過 %d 字元" % (field, limit))
    return value


def lots(value, allow_zero=False):
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise Invalid("張數需為整數")
    low = 0 if allow_zero else 1
    if not (low <= n <= MAX_LOTS):
        raise Invalid("張數需介於 %d-%d" % (low, MAX_LOTS))
    return n


def price(value):
    try:
        p = float(value)
    except (TypeError, ValueError):
        raise Invalid("成交價需為數字")
    if not (0 < p <= MAX_PRICE):
        raise Invalid("成交價超出合理範圍")
    return round(p, 4)


def date(value):
    value = (value or "").strip()
    if not DATE_RE.match(value):
        raise Invalid("日期格式需為 YYYY-MM-DD")
    return value


def side(value):
    value = (value or "").strip().lower()
    if value not in ("buy", "sell"):
        raise Invalid("交易別需為 buy 或 sell")
    return value
