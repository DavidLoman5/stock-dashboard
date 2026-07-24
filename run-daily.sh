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
#   run-daily.sh                   everything, no AI steps
set -euo pipefail
cd "$(dirname "$0")"

PHASE=all
if [ "${1:-}" = "--phase" ]; then
  PHASE="${2:?--phase needs a value: fetch|publish|all}"
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--phase fetch|publish|all]" >&2; exit 2
fi

fetch() {
  # 1. who and what to fetch for - the union of every ACTIVE user's codes plus the demo
  #    portfolio, and the owner's own portfolio for the analysis step
  if [ -f data/app.db ]; then
    python3 -m server.admin export-codes
    python3 -m server.admin export-owner
  else
    echo "no data/app.db - single-user mode, using holdings.json"
  fi

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

  # 4. Friday attribution
  [ "$(date +%u)" = "5" ] && pwsh -File evaluate.ps1 || true
}

publish() {
  # 5. splice the AI notes, rebuild the PUBLIC page from the demo portfolio, then commit+push.
  #    build-demo.ps1 is deliberately NOT called here any more: publish.ps1 splices the owner's
  #    notes into index.html and so must run the demo rebuild itself, afterwards. Calling it
  #    here first (as this did until 2026-07-24) let the splice overwrite the filtered page and
  #    published the owner's real holdings + `rec` advice to GitHub.
  pwsh -File publish.ps1
}

case "$PHASE" in
  fetch)   fetch ;;
  publish) publish ;;
  all)     fetch; publish ;;
  *)       echo "unknown phase: $PHASE (use fetch|publish|all)"; exit 2 ;;
esac
