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
_GH_CANDIDATES = ("/Users/danielospina/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh")
GH = next((p for p in _GH_CANDIDATES if os.path.exists(p)), "gh")


def gh(*args):
    """Return parsed JSON, or None on ANY failure. None means UNKNOWN, never empty."""
    try:
        r = subprocess.run([GH, *args], capture_output=True, text=True, timeout=120)
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
