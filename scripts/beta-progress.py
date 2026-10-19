#!/usr/bin/env python3
"""beta-progress.py — the DELIVERY line for the orchestrator heartbeat.

The heartbeat's own classifier answers "is a lane wedged?" — and that answer is almost
always no, so 44% of its nudges carried no alert and it never once mentioned anything
that determines whether the beta ships (measured 2026-09-27: zero mentions of P0,
blocker, merge-ready, runner or rail in the entire log).

This adds the other half: is the BETA moving. It is deliberately CHEAP and SELF-CACHED
because the heartbeat runs every 2 minutes and the reads are expensive (the PR lists are
LIMIT 500/400, so one recompute is tens of API requests).

⛔ THE LINE CARRIES ITS OWN MEASUREMENT AGE. Measured 2026-09-28: the line reported "P0 21
open, 6 NONE" for ~50 minutes while the live truth was 19 open / 2 NONE, and the orchestrator
nearly dispatched on the stale figure. A metric with no timestamp is read as live — so the age
is printed, and it is printed even when the cache is fresh.

Coverage counts a P0/P1 as covered when a MERGED or OPEN PR names the issue in its
branch or title (boundary-exact). §48 lesson: a narrow probe reports "no work" while a
PR exists, so both channels are checked.

Output: ONE line on stdout. Exit 0 always — a metrics failure must never take the
heartbeat down with it.
"""
import json
import os
import re
import os
import subprocess
import sys
import time

REPO = "daniel-ospina/tortoise"
CACHE = os.path.expanduser("~/.pi/agent/state/beta-progress.json")
TTL = 1800  # was 3600; halved so the worst-case lag is 30m, at ~2x the API cost (still cheap)


# ── gh RESOLUTION AND FAILURE CONTRACT (fixed 2026-10-01) ────────────────────
# TWO DEFECTS, both measured, both turning a read failure into a FALSE ZERO:
#  (1) `json.loads(r.stdout or "[]")` -- when gh fails, stdout is EMPTY, so the
#      `or "[]"` made it a VALID EMPTY LIST and the function returned [] instead of
#      None. Every caller's `if x is None` check was therefore dead code, and the
#      fleet read "0 open PRs" while 100 were open. A filter's empty result must
#      never stand as evidence of absence.
#  (2) Bare "gh" depends on ambient PATH. The agent shim (~/.pi/agent/shims/gh)
#      resolves the REAL gh from PATH; in a minimal environment it refuses
#      ("cannot find the real gh"), so the loop's telemetry silently zeroed while
#      the same command worked in an interactive shell. These calls are READ-ONLY
#      telemetry, not merges, so pin the real binary and drop the PATH dependency.
# ⛔ NO ABSOLUTE HOME PATH: `~/bin/gh` is the binary #1872 pinned, and expanduser builds the same
# path without hard-coding another user's home in shipped code.
_GH_CANDIDATES = (os.path.expanduser("~/bin/gh"), "/opt/homebrew/bin/gh", "/usr/local/bin/gh")


# ⛔ ALSO PREFER THE HARNESS'S OWN gh LAYER (#1988) — derived from `$O`, never from PATH. These are
# the highest-volume READS on the shared GitHub bucket; going through the layer is what stops them
# bypassing its serialisation/backoff. ⛔ THE LAYER then resolves the real gh by WALKING PATH, so
# "#1872 cannot come back" is false: the pin is passed THROUGH the layer below
# (`GH_REST_REAL_GH`/`GH_LIMIT_REAL_GH`), so these readers keep calling the binary #1872 chose for
# them and still get the layer.
def _gh_bin():
    o = os.environ.get("O", "")
    if o:
        # ⛔ ORDER: `gh-rest` FIRST, matching every shell call site (`orch-loop.sh`: "adapter last so
        # `$O/gh-rest` wins where it exists"). The adapter is what serves a GraphQL refusal over REST
        # (#1959); preferring the non-translating wrapper here made these readers fail exactly as they
        # did before that fix while the same box's shell calls took the other transport.
        for c in (os.path.join(o, "gh-rest", "gh"), os.path.join(o, "gh-limit", "gh")):
            if os.path.isfile(c) and os.access(c, os.X_OK):
                return c
    # `isfile` + X_OK, never `exists`: a DIRECTORY at a candidate path would be selected and then
    # raise from `subprocess.run` (or, worse, answer as "gh not found" — the same trap the fail-open
    # walks had; found in review round 7).
    return next((p for p in _GH_CANDIDATES
                 if os.path.isfile(p) and os.access(p, os.X_OK)), "gh")


GH = _gh_bin()
# Hand the layer the binary #1872 pinned (empty when we are not going through a layer).
_PIN = next((p for p in _GH_CANDIDATES
             if os.path.isfile(p) and os.access(p, os.X_OK)), None)   # a DIRECTORY is not a pin
GH_LAYER_ENV = ({"GH_REST_REAL_GH": _PIN, "GH_LIMIT_REAL_GH": _PIN}
                if _PIN and GH.endswith(("/gh-rest/gh", "/gh-limit/gh")) else {})


# ⛔ THE LAYER MUST NOT SLEEP INSIDE THIS PROCESS (#1988). The heartbeat bounds this refresh (90/120 s)
# while the layer's first documented backoff is 60 s: an in-call wait outlives the caller, and the
# caller is killed before the layer can say why — a rate-limited box then reports UNKNOWN/STALL
# instead of the RATE-LIMITED verdict it can prove. NO_WAIT makes the layer record the limit and
# return at once, so this process's own deferral takes over. Children only.
os.environ.setdefault("GH_LIMIT_NO_WAIT", "1")


def gh(*args):
    """Return parsed JSON, or None on ANY failure. None means UNKNOWN, never empty."""
    try:
        r = subprocess.run([GH, *args], capture_output=True, text=True, timeout=120,
                           env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    out = (r.stdout or "").strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None


def compute():
    openpr = gh("pr", "list", "--repo", REPO, "--state", "open", "--limit", "500",
                "--json", "number,title,headRefName")
    merged = gh("pr", "list", "--repo", REPO, "--state", "merged", "--limit", "400",
                "--json", "number,title,headRefName,mergedAt")
    if openpr is None or merged is None:
        return None

    today = time.strftime("%Y-%m-%dT00:00:00Z", time.gmtime())
    merged_today = sum(1 for p in merged if (p.get("mergedAt") or "") >= today)

    def covered(n):
        pat = re.compile(r"(?<![\d])%d(?![\d])" % n)
        for p in openpr + merged:
            if pat.search(p.get("headRefName") or "") or pat.search(p.get("title") or ""):
                return True
        return False

    out = {"ts": int(time.time()), "open_prs": len(openpr), "merged_today": merged_today}
    for tier, label in (("p0", "P0-blocker"), ("p1", "P1-severe")):
        rows = gh("issue", "list", "--repo", REPO, "--label", label, "--state", "open",
                  "--limit", "300", "--json", "number")
        if rows is None:
            return None
        have = sum(1 for r in rows if covered(r["number"]))
        out[tier] = {"open": len(rows), "with_pr": have, "without": len(rows) - have}
    return out


def main():
    data = None
    try:
        with open(CACHE) as fh:
            cached = json.load(fh)
        if time.time() - cached.get("ts", 0) < TTL:
            data = cached
    except Exception:
        pass
    if data is None:
        data = compute()
        if data is None:
            print("DELIVERY: unavailable (metrics read failed)")
            return 0
        try:
            with open(CACHE, "w") as fh:
                json.dump(data, fh)
        except Exception:
            pass
    p0, p1 = data["p0"], data["p1"]
    ts = data.get("ts", 0)
    age_m = int((time.time() - ts) / 60)
    stamp = time.strftime("%H:%M", time.localtime(ts)) if ts else "unknown"
    # ⛔ Print the age ALWAYS. Omit it and a 50-minute-old figure reads as live.
    print("DELIVERY [as of %s, %dm ago]: P0 %d open (%d with PR, %d NONE) | P1 %d open (%d with PR, %d NONE)"
          " | %d open PRs, %d merged today"
          % (stamp, age_m,
             p0["open"], p0["with_pr"], p0["without"],
             p1["open"], p1["with_pr"], p1["without"],
             data["open_prs"], data["merged_today"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
