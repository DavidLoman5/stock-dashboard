#!/usr/bin/env bash
# run-daily.sh - the full daily sequence, in the order that matters.
#
# Point the cron wrapper at this instead of calling the scripts individually, otherwise the
# exports below never run and update-holdings.ps1 works from a stale owner portfolio.
#
#   0 20 * * 1-5  /home/felix/stock-dashboard/run-daily.sh >> ~/stock-briefing-cron.log 2>&1
#
# The AI steps (holdings-notes.json / picks-notes.json / ai-tags.json) are NOT here: they are
# driven by ~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md, which should call this
# script's phases around its own Write steps. Run with --phase to do that:
#
#   run-daily.sh --phase fetch     exports + update-holdings + screen   (before the AI writes)
#   run-daily.sh --phase publish   demo rebuild + publish               (after the AI writes)
#   run-daily.sh --phase publish --no-push
#                                   same, but commits without pushing - only the cron wrapper's
#                                   token-usage handoff should ever pass this (see
#                                   lib/publish-gate.ps1 / finish-daily-push.ps1); it leaves a
#                                   local commit that MUST be pushed by something else
#   run-daily.sh                   everything, no AI steps
set -euo pipefail
cd "$(dirname "$0")"

PHASE=all
NOPUSH=""
if [ "${1:-}" = "--phase" ]; then
  PHASE="${2:?--phase needs a value: fetch|publish|all}"
  if [ "${3:-}" = "--no-push" ]; then NOPUSH="-NoPush"; fi
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--phase fetch|publish|all] [--no-push]" >&2; exit 2
fi

fetch() {
  # 1. who and what to fetch for - the union of every ACTIVE user's codes plus the demo
  #    portfolio, and the owner's own portfolio for the analysis step
  if [ -f data/app.db ]; then
    python3 -m server.admin export-codes
    python3 -m server.admin export-owner
    python3 -m server.admin export-guestplus-codes
  else
    echo "no data/app.db - single-user mode, using holdings.json"
  fi

  # 1b. yesterday's per-code advice, on its own, BEFORE anything overwrites holdings-notes.json.
  #     The AI step needs it to check whether yesterday's triggers fired; reading the whole
  #     ~10KB notes file to get at ~1KB of `rec` was most of that step's input budget.
  #
  #     `_market` rides along for the same reason picks-log exists: yesterday's market call has
  #     to be answerable today. On 2026-07-30 the run published moodK "bear" and the next session
  #     was +7.97%; nothing in the pipeline ever made the next day's run look at that.
  #     The market half comes from market-notes.json now that the market read is its own file.
  #     A missing file is normal (first run after the split, or the AI step skipped it); a file
  #     that exists but cannot be parsed is NOT, and used to vanish into `|| true` - the AI then
  #     silently lost yesterday's context with nothing in the log to say so.
  python3 - <<'PY' || true
import json, os, sys

def load(path):
    """(data, ok). ok=False only for a file that exists and is broken - that is worth shouting
    about; simply not being there is an ordinary state."""
    if not os.path.exists(path):
        return {}, True
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh), True
    except (OSError, ValueError) as exc:
        print("  WARN: %s unreadable (%s) - yesterday's context will be missing from today's "
              "analysis" % (path, exc), file=sys.stderr)
        return {}, False

notes, _ = load("holdings-notes.json")
mkt, _ = load("market-notes.json")
if not isinstance(notes, dict):
    notes = {}
if not isinstance(mkt, dict):
    mkt = {}
# one changeover day: before the split the market read lived here as a pseudo-code
if not mkt:
    mkt = notes.get("_market") or {}
recs = {c: n["rec"] for c, n in notes.items()
        if not c.startswith("_") and isinstance(n, dict) and n.get("rec")}
market = {k: mkt[k] for k in ("windLead", "mood", "moodK", "night") if mkt.get(k)}
if not recs and not market:
    raise SystemExit(0)
stamp = max((os.path.getmtime(p) for p in ("holdings-notes.json", "market-notes.json")
             if os.path.exists(p)), default=0)
out = {"writtenAt": stamp, "recs": recs, "market": market}
with open("prev-recs.json", "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=1)
print("  prev-recs.json: %d 檔昨日建議%s" % (len(recs), "＋昨日市場判斷" if market else ""))
PY

  # 2. quotes for that union -> data/quotes.json (shared) + holdings-context.json (owner only,
  #    and the ONLY thing the AI step ever reads)
  pwsh -File update-holdings.ps1

  # 3. market-wide screening -> data/picks.json (shared by every user)
  #    also refreshes data/names.json (whole-market code -> official Chinese name)
  pwsh -File screen.ps1

  # 3b. holdings someone added by code only get their official name from that table
  if [ -f data/app.db ]; then
    python3 -m server.admin backfill-names
  fi

  # 3c. per-code analysis for guests, written by Gemini (never Claude - guests must not cost
  #     Claude tokens). Best-effort by design: no key, no network or a bad reply all leave the
  #     previous guest-notes.json in place and the daily run carries on.
  python3 -m server.gnotes || true

  # 4. Friday attribution
  [ "$(date +%u)" = "5" ] && pwsh -File evaluate.ps1 || true

  # 5. the overnight drivers of TOMORROW's open - US futures, the TSMC ADR, the last SOX close.
  #    Deliberately last: nq/tsm/twd are live quotes, so the closer to the analysis step the
  #    better. Best-effort like gnotes above; the source is third-party and nothing may block on
  #    it. A total failure removes the file, and the AI step skips the section (see SKILL.md).
  pwsh -File overnight.ps1 || true
}

publish() {
  # 5. splice the AI notes, rebuild the PUBLIC page from the demo portfolio, then commit+push.
  #    build-demo.ps1 is deliberately NOT called here any more: publish.ps1 splices the owner's
  #    notes into index.html and so must run the demo rebuild itself, afterwards. Calling it
  #    here first (as this did until 2026-07-24) let the splice overwrite the filtered page and
  #    published the owner's real holdings + `rec` advice to GitHub.
  pwsh -File publish.ps1 $NOPUSH
}

case "$PHASE" in
  fetch)   fetch ;;
  publish) publish ;;
  all)     fetch; publish ;;
  *)       echo "unknown phase: $PHASE (use fetch|publish|all)"; exit 2 ;;
esac
