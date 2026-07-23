"""Configuration loading. Stdlib only, no external deps.

config.json is per-deployment and gitignored; config.example.json is the committed template
so a fresh clone can copy it and run. Every key has a safe default here, so a missing
config.json means "single machine, localhost, registration open" rather than a crash.
"""

import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULTS = {
    "host": "127.0.0.1",          # never bind 0.0.0.0: the tunnel is the only way in
    "port": 8787,
    # Origins allowed to make state-changing requests. Empty list = same-origin only, which
    # is enforced by comparing against the request's Host header.
    "allowedOrigins": [],
    "sessionDays": 14,
    "idleDays": 3,
    "registrationOpen": True,
    "requireInvite": False,
    "inviteDays": 7,
    "maxCodesPerUser": 30,
    "maxDistinctCodes": 200,
    "maxRegistrationsPerIpPerDay": 3,
    "maxLoginFailures": 10,
    "lockoutMinutes": 15,
    "pendingExpiryDays": 30,
    "secureCookie": True,         # set False only for plain-http local testing
    # Behind Cloudflare Tunnel the peer address is always 127.0.0.1, so the real client IP
    # has to come from a header. Safe here ONLY because we bind to loopback and cloudflared
    # is the sole client. Set False if anything else can reach the port.
    "trustProxyHeader": True,
    "proxyHeader": "CF-Connecting-IP",
    "dbPath": "data/app.db",
    "dataDir": "data",
}


def load(path=None):
    cfg = dict(DEFAULTS)
    path = path or os.path.join(ROOT, "config.json")
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            user_cfg = json.load(fh)
        # keys starting with _ are comments (config.example.json documents itself that way);
        # anything else unrecognised is a typo, and silently ignoring it would be worse
        user_cfg = {k: v for k, v in user_cfg.items() if not k.startswith("_")}
        unknown = set(user_cfg) - set(DEFAULTS)
        if unknown:
            raise ValueError("unknown config keys: %s" % ", ".join(sorted(unknown)))
        cfg.update(user_cfg)
    cfg["dbPath"] = os.path.join(ROOT, cfg["dbPath"])
    cfg["dataDir"] = os.path.join(ROOT, cfg["dataDir"])
    return cfg
