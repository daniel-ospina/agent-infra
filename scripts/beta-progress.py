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
import subprocess
import sys
import time
import urllib.request

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


# ⛔ THE LAYER MUST NOT SLEEP INSIDE THIS PROCESS (#1988). This refresh runs inside a heartbeat
# tick that is killed at a fixed bound, while the layer's first documented backoff is 60 s: an
# in-call wait outlives the caller, and the caller is killed before the layer can say why — a
# rate-limited box then reports UNKNOWN/STALL instead of the RATE-LIMITED verdict it can prove.
# NO_WAIT makes the layer record the limit and return at once, so this process's own deferral
# takes over. Children only.
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


# ── REST SECOND SOURCE FOR THE PR LISTS (fixed 2026-10-19) ─────────────────
# `gh pr list --json` is GRAPHQL, and under fleet concurrency GitHub refuses it on the
# SECONDARY limit while the primary budget is nearly UNTOUCHED -- measured 2026-10-19:
# core 1599/5000, graphql 4612/5000, and one REST call answering in 0.43 s with 17
# concurrent gh clients on the same box. The beat then printed
# `DELIVERY: unavailable (metrics read failed)`, i.e. the fleet lost its OWN progress
# measurement -- the number the owner reads -- while a readable source existed.
# The two limits are SEPARATE BUCKETS, so REST is a second SOURCE, not a retry of the
# same refusal. It is read DIRECTLY (urllib + the token) rather than through $O's gh
# layer: the layer's own GraphQL path is what was refused, so routing the fallback
# through it would re-enter the queue that is refusing this read.
REST_PER_PAGE = 100   # GitHub's ceiling for /pulls -- the honest bound on ONE request
# ⛔ THIS READ IS BOUNDED BY ITS CALLER (#1988's rule, applied here). The heartbeat runs this
# refresh inside a tick that is itself killed at a fixed bound, so a paging loop with no budget
# could outlive it and be KILLED -- reporting nothing, instead of the `unavailable` line it can
# prove. Exceeding the budget REFUSES the read (None), exactly like an unreadable page: a
# truncated window would under-count `merged_today`, which is the error this fallback must not add.
REST_TIMEOUT_S = 15   # per request
# ⛔ PER READ, and `compute()` makes TWO of them (open + merged): 90 s worst case for the REST
# phase. Do not read this as one shared budget -- a single deadline threaded through both reads
# is a different design, and these numbers would move with it.
REST_BUDGET_S = 45


def _token():
    """The token to read with: the fleet's env first, then gh's own hosts.yml. Never logged."""
    for var in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(var):
            return os.environ[var]
    try:
        with open(os.path.expanduser("~/.config/gh/hosts.yml"), "r") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("oauth_token:"):
                    return s.split(":", 1)[1].strip().strip("'\"")
    except Exception:
        return ""
    return ""


def _rest_get_json(url, tok, timeout=REST_TIMEOUT_S):
    """One REST GET. Parsed JSON, or None on ANY failure -- None means UNKNOWN, never empty."""
    req = urllib.request.Request(url, headers={
        "Authorization": "bearer %s" % tok,
        "Accept": "application/vnd.github+json",
        "User-Agent": "beta-progress",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None


def _rest_prs(state, limit=100):
    """The PR list over REST -- the fallback when `gh pr list` (GraphQL) is refused.

    Returned in the `gh pr list --json` shape this file consumes: `number`, `title`,
    `headRefName` (<- head.ref), `mergedAt` (<- merged_at). REST `closed` ALSO carries
    PRs closed WITHOUT merging, so the merged list keeps only rows with a non-null
    `merged_at`; counting the others would inflate `merged_today` with PRs that were
    abandoned, which `gh pr list --state merged` never returned.

    PAGING, stated honestly: REST caps `per_page` at 100, while the callers ask for 500
    (open) and 400 (merged) -- so those windows are ceil(limit/100) REQUESTS, not one.
    This pages until the caller's window is filled or the collection ends. It does NOT
    return the first page as if it were the window: a silently short list would
    under-count `merged_today`, which is the one error this fallback must not add. A page
    that cannot be read -- or a read that spends its own budget -- returns None for the WHOLE
    read; a partial list is indistinguishable from a complete one at the call site.

    `sort=updated&direction=desc` is what makes the window SOUND for `merged_today`, and the
    bound is worth stating exactly: the window is the 400 most-recently-UPDATED **closed** PRs,
    and rows closed without merging are dropped AFTER the window is read. So it is today's
    updated closed PRs (merges plus the abandoned ones updated alongside them), not today's
    merges alone, that must fit in 400 for `merged_today` to be exact. That is a bound, not a
    promise for an arbitrarily large day -- state it rather than assume it.
    """
    tok = _token()
    if not tok:
        return None
    path = "open" if state == "open" else "closed"
    out, seen, page = [], 0, 1
    deadline = time.time() + REST_BUDGET_S
    while seen < limit:
        remaining = deadline - time.time()
        if remaining <= 0:
            return None           # budget spent -- refuse, never return a short window
        want = min(REST_PER_PAGE, limit - seen)
        url = ("https://api.github.com/repos/%s/pulls?state=%s&sort=updated&direction=desc"
               "&per_page=%d&page=%d" % (REPO, path, want, page))
        raw = _rest_get_json(url, tok, min(REST_TIMEOUT_S, remaining))
        if not isinstance(raw, list):
            return None
        for p in raw:
            if not isinstance(p, dict):
                continue
            if state != "open" and not p.get("merged_at"):
                continue      # closed-without-merge is not a merged PR
            out.append({
                "number": p.get("number"),
                "title": p.get("title") or "",
                "headRefName": (p.get("head") or {}).get("ref") or "",
                "mergedAt": p.get("merged_at") or "",
            })
        seen += len(raw)
        if len(raw) < want:
            break             # last page of the collection
        page += 1
    return out


def compute():
    openpr = gh("pr", "list", "--repo", REPO, "--state", "open", "--limit", "500",
                "--json", "number,title,headRefName")
    merged = gh("pr", "list", "--repo", REPO, "--state", "merged", "--limit", "400",
                "--json", "number,title,headRefName,mergedAt")
    # GRAPHQL REFUSED -> TRY REST BEFORE DECLARING THE METRICS UNAVAILABLE. If EITHER read
    # failed, BOTH lists are re-read over REST: a REST open-count beside a GraphQL
    # merged-count would compare two DIFFERENTLY-WRONG reads, and `merged_today` is a
    # comparison against the open window. Same source or no metric.
    if openpr is None or merged is None:
        ro, rm = _rest_prs("open", limit=500), _rest_prs("merged", limit=400)
        if ro is not None and rm is not None:
            openpr, merged = ro, rm
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
