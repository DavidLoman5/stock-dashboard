#!/usr/bin/env bash
# funnel-watchdog.sh - re-register the Tailscale node when Funnel has silently stopped routing.
#
#   systemd --user timer, every 5 minutes (see SETUP.md "Funnel 突然連不上"):
#     ExecStart=/home/felix/stock-dashboard/tools/funnel-watchdog.sh
#
# Why this exists: this host is WiFi-only and re-associates 5-8 times a day. Most of those are
# harmless, but some leave tailscaled's `Hostinfo.IngressEnabled` unacknowledged by the control
# plane - Funnel then accepts the TCP connection, reads the SNI, finds no node, and closes.
# Externally that looks like a TLS handshake failure; `tailscale funnel status` still reports
# "Funnel on", so nothing local reveals the fault. Only `tailscale down && up` clears it.
#
# Three things this script gets right, each of which took a wrong turn first (2026-07-31):
#
#   1. It probes through the PUBLIC ingress, not the hostname. Resolving the hostname on this
#      machine returns the node's own tailnet IP, a path that works even while Funnel is dead -
#      probing it would report healthy through every outage.
#   2. It requires two consecutive failures. A WiFi re-association breaks Funnel for tens of
#      seconds and then heals itself; repairing those would restart the tunnel several times a
#      day for nothing.
#   3. It waits out the cooldown even when unhealthy. If Tailscale's own ingress is down, no
#      amount of re-registering helps, and a down/up every 5 minutes would turn their outage
#      into a local one as well.
set -uo pipefail

COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-1800}   # 30 min between repairs
PROBE_TIMEOUT=${PROBE_TIMEOUT:-10}
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/stock-dashboard"
STAMP="$STATE_DIR/funnel-watchdog.last-repair"

log(){ printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

for cmd in tailscale curl dig; do
  command -v "$cmd" >/dev/null 2>&1 || { log "FATAL: $cmd not found, cannot probe"; exit 1; }
done

# The node's own name, never hardcoded: a literal <machine>.<tailnet>.ts.net in a tracked file
# is exactly what lib/publish-gate.ps1 refuses to publish.
HOST=$(tailscale status --json 2>/dev/null \
       | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null)
if [ -z "$HOST" ]; then
  log "tailscaled not answering (node down?), nothing this script can fix"
  exit 0
fi

# Public DNS on purpose - the system resolver would hand back the tailnet address.
INGRESS=$(dig +short @1.1.1.1 "$HOST" A 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)
if [ -z "$INGRESS" ]; then
  log "no public A record for the node - Funnel may be switched off entirely; not repairing"
  exit 0
fi

# Any HTTP status means the ingress reached us and TLS completed; 000 is curl's "no response".
# A 302 to /login is the healthy answer, but 200/401/503 would equally prove the path works.
probe(){
  curl -sS -o /dev/null -w '%{http_code}' --max-time "$PROBE_TIMEOUT" \
       --resolve "$HOST:443:$INGRESS" "https://$HOST/" 2>/dev/null
}

first=$(probe)
[ "$first" != "000" ] && exit 0
sleep 15
second=$(probe)
[ "$second" != "000" ] && { log "single failed probe ($first), recovered on retry - not repairing"; exit 0; }

now=$(date +%s)
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$COOLDOWN_SECONDS" ]; then
    log "Funnel still unreachable, but last repair was $((now - last))s ago (<${COOLDOWN_SECONDS}s) - leaving it alone"
    exit 0
  fi
fi

log "Funnel unreachable via $INGRESS on two consecutive probes - re-registering node"
mkdir -p "$STATE_DIR"
printf '%s\n' "$now" > "$STAMP"

tailscale down || log "WARN: 'tailscale down' returned non-zero, continuing"
if ! tailscale up; then
  log "FATAL: 'tailscale up' failed - the node is now DOWN and needs a human"
  exit 1
fi

# Control-plane propagation is not instant; measured at roughly 50s on 2026-07-31.
for i in $(seq 1 12); do
  sleep 10
  code=$(probe)
  if [ "$code" != "000" ]; then
    log "recovered after $((i * 10))s (http $code)"
    exit 0
  fi
done

log "WARN: still unreachable 120s after re-registering - cause is probably not this node"
exit 1
