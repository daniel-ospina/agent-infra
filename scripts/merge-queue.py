#!/usr/bin/env python3
"""merge-queue.py — the DRAIN line for the orchestrator heartbeat.

WHAT IS MISSING, AND WHY THIS FILE EXISTS
The heartbeat gives the orchestrator two things, and neither one mentions the merge
queue:

  1. lane-status.py   -> "is a lane wedged?"   (almost always no)
  2. beta-progress.py -> "P0 24 open ... 173 open PRs, 8 merged today"

So the number 173 arrives every five minutes as a BARE STATISTIC. Nothing turns it
into a verdict, nothing says it is the constraint, and nothing says who is on it or
how many lanes it needs. The log has never once mentioned merge capacity.

Three defects are measured, not assumed:

  A. NO VERDICT. `open_prs=173` with `merged_today=8` is ~21 days to drain at that
     rate, and the message carrying it reads as a status line, not an alarm.

  B. A STUCK MERGE LANE READS AS NOTHING AT ALL. Measured 2026-09-28 01:07:
     `Merigng PR = WAITING-CHILD child=27m` — past lane-status.py's own OVERDUE_S
     (25 min). WAITING-CHILD is in NEITHER the `alert` NOR the `known` bucket in
     orchestrator-heartbeat.sh; it is only counted in N_WAIT. So the one lane doing
     the fleet's most important job can be overdue and appear literally nowhere in
     the message the orchestrator reads.

  C. MERGE DUTY IS UNCOUNTABLE BY SUBSTRING. The lane's title is MISSPELLED
     ("Merigng PR"), which the registry documents. Re-measured 2026-09-28: a
     `grep -i merg` over lane-registry.tsv returns ZERO rows. Any attempt to count
     merge lanes by the obvious substring silently finds none and reports "no merge
     lane exists" while one is running. This file therefore counts lanes by an
     EXPLICIT marker list, never by substring.

OUTPUT: ONE line on stdout. Exit 0 always — a metrics failure must never take the
heartbeat down with it (same contract as beta-progress.py).

    QUEUE: open=173 merged_24h=23 drain_days=7.5 have=1 need=3 VERDICT=BOTTLENECK

COST: re-uses beta-progress.py's cached queue depth (no extra API call), plus at
most ONE `gh pr list` per TTL for the 24h merge rate. Self-cached.
"""
import json
import math
import os
import os
import subprocess
import sys
import time

REPO = "daniel-ospina/tortoise"
STATE = os.path.expanduser("~/.pi/agent/state")
PROGRESS = os.path.join(STATE, "beta-progress.json")
CACHE = os.path.join(STATE, "merge-queue.json")
REGISTRY = os.path.join(STATE, "lane-registry.tsv")
TTL = 3600

# ⛔ NEVER a substring match. "Merigng PR" does not contain "merg", and a lane the
# orchestrator spawns tonight to help will be named here deliberately.
MERGE_LANE_LABELS = (
    # The rail panes were RETITLED to "PR 1"/"PR 2"/"PR 3" on 2026-09-28, so the old
    # spellings ("Merigng PR", "π - tortoise 2") match NO pane and this constant
    # silently inflated the detached fallback to have=9 while only 8 are real.
    # "PR 1" is deliberately absent: it shares session 01a0ca2e with "PR 2" — two
    # panes, one agent — so counting it would report a lane that does not exist.
    "PR 2",
    "PR 3",
)

TARGET_DAYS = 3.0      # the owner's horizon: "2-3 lanes working together tonight"
MIN_QUEUE = 40         # below this the queue is not a crisis; do not nag
# ⛔ PER-LANE THROUGHPUT IS A STATED ASSUMPTION, NOT `rate / have`.
# Deriving it from the live lane count is CIRCULAR and pathological: more lanes
# would lower the per-lane estimate, which RAISES the demand, so satisfying the
# demand raises it again (measured 2026-09-28: have=2 -> need=5, have=3 -> need=8
# on the SAME queue). A demand that grows when you meet it can never be met.
# Measured rate: 24 merged/24h across 2-3 panes ~= 8-12 per lane per day. Use the
# conservative end and keep it FIXED, so `need` is stable and the reader can
# disagree with the assumption openly rather than with a moving target.
PER_LANE_DAY = 8.0


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


# The MERGE-RATE READ'S OWN BUDGET, AND WHY IT IS 100 s (#2227). `gh` calls are serialised PER BOX
# (#2005, deliberate: one shared account, and GitHub's secondary limit is triggered by concurrency).
# MEASURED 2026-10-20 on three cloud cells: one `gh pr view` cost **63.0 s at 13 lanes** and 0.676 s
# at 3, while a raw `curl` to api.github.com answered in 0.091 s -- the network and the account are
# fine, the time is OUR queue. The old 120 s child timeout was above that number, so this read was
# not the one manufacturing false absences; the missing half was HONESTY, not a bound:
# `merged_24h=?` + `VERDICT=UNKNOWN (merge-rate read failed)` named no wait and no age, so a read
# that sat 110 s in the box's own queue was indistinguishable from an instant 403. Kept as a named
# constant with the measurement above it rather than a literal at the call site.
MERGE_RATE_TIMEOUT_S = 100
# Anything above this is reported as SLOW beside the ANSWERED value (same 5 s rationale as
# objective.py's `SLOW_READ_S`: 0.676 s measured on a quiet box, ~7x that is still ordinary jitter).
SLOW_READ_S = 5.0
# Books set by the LAST `merged_24h()` call, so a refusal can name itself. Never a value, never a
# count -- an AGE and a DURATION only (see the #1869 note in `merged_24h`).
LAST_RATE_READ = {}


def gh(*args):
    """Return parsed JSON, or None on ANY failure. None means UNKNOWN, never empty."""
    try:
        r = subprocess.run([GH, *args], capture_output=True, text=True,
                           timeout=MERGE_RATE_TIMEOUT_S,
                           env={**os.environ, **GH_LAYER_ENV} if GH_LAYER_ENV else None)
    except subprocess.TimeoutExpired:
        LAST_RATE_READ["cause"] = f"TimeoutExpired after {MERGE_RATE_TIMEOUT_S}s"
        return None
    except Exception as e:
        LAST_RATE_READ["cause"] = f"{type(e).__name__}: {str(e)[:80]}"
        return None
    if r.returncode != 0:
        LAST_RATE_READ["cause"] = ("rc=%d: %s" % (r.returncode,
                                                   ((r.stderr or "").strip() or "no stderr")[:120]))
        return None
    out = (r.stdout or "").strip()
    if not out:
        LAST_RATE_READ["cause"] = "rc=0 with an empty body"
        return None
    try:
        return json.loads(out)
    except Exception as e:
        LAST_RATE_READ["cause"] = f"unparseable body: {type(e).__name__}"
        return None


def merge_lane_labels():
    """Explicit markers, plus any lane the orchestrator has declared.

    A spawned helper lane is counted by adding its exact label to
    ~/.pi/agent/state/merge-lanes.txt (one label per line). Explicit, checkable, and
    immune to the spelling trap above.
    """
    labels = list(MERGE_LANE_LABELS)
    extra = os.path.join(STATE, "merge-lanes.txt")
    try:
        with open(extra) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and line not in labels:
                    labels.append(line)
    except Exception:
        pass
    return labels


def count_merge_lanes():
    """How many merge-duty PANES are live right now.

    ⛔ COUNT PANES, NOT REGISTRY ROWS. Two independent undercounts were measured
    on 2026-09-28, and both made the queue look better staffed than it was:
      (a) the registry lists only ONE `Merigng PR` row (597F6D5A) while TWO panes
          are open (597F6D5A and 16030BDA) — the second is simply not registered;
      (b) even if it were, a lane may own several panes, so deduping by label
          would still answer 1.
    Capacity to drain is concurrency, so the question is "how many panes are on
    merge duty", and cmux is the authority on what panes exist. The registry is
    consulted only as a fallback when cmux cannot be read.

    Returns (have, labels_present).
    """
    want = merge_lane_labels()
    present = []
    try:
        r = subprocess.run(["cmux", "list-workspaces", "--json"],
                           capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, CMUX_QUIET="1"))
        data = json.loads(r.stdout or "[]")
        ws = data if isinstance(data, list) else data.get("workspaces", [])
        for w in ws:
            # ⛔ `title` is NOT the field cmux returns. `cmux list-workspaces --json`
            # emits `custom_title` (verified 2026-09-28); `title` is absent, so this
            # comparison matched nothing and the function silently fell through to
            # the registry fallback, which undercounts by design. Measured the same
            # day: merge-lanes.txt listed 8 lanes while this reported have=3, so the
            # heartbeat kept declaring a MERGE-QUEUE BOTTLENECK and kept telling the
            # orchestrator to add merge-duty lanes that had ALREADY been added. A
            # capacity metric that cannot see capacity manufactures the crisis it
            # reports. Read both spellings, prefer the one cmux actually sends.
            title = (w.get("custom_title") or w.get("title") or "").strip()
            if title in want:
                present.append(title)
        if present:
            return len(present), sorted(set(present))
    except Exception:
        pass
    # fallback: cmux is unreachable, so fall back to the DECLARATION.
    #
    # ⛔ Measured 2026-09-28: the heartbeat runs DETACHED (ppid 1) and cmux refuses
    # it -- "Access denied - only processes started inside cmux can connect" -- so
    # THIS fallback is what the metric actually uses in production, not the cmux
    # branch above. Matching the registry by label cannot work: the registry's
    # column 1 uses lane names ("1 Capture") while merge-lanes.txt uses pane titles
    # ("2a Projection keys") -- two vocabularies that never intersect. It answered 3
    # while the file declared 8, so the heartbeat ordered the orchestrator to raise
    # merge-duty lanes that had ALREADY been raised, every ~6 minutes.
    #
    # merge-lanes.txt IS the declaration -- it is the file the alert itself tells you
    # to edit -- so it is the floor. A declared label with no live pane is a stale
    # entry: a tidiness problem for the file's owner, and NOT a reason to under-report
    # capacity and manufacture a bottleneck.
    return len(want), sorted(set(want))


def merged_24h():
    """Merge rate over a real 24h window, or `(value, read)`. See `main()` for the two facts.

    beta-progress.json counts 'today' (since UTC midnight), which at 01:00 reads 8 and makes a
    healthy fleet look stalled. The window that answers 'is the queue draining' is a rolling 24h.

    ⛔ A REFUSAL MUST BE ABLE TO DESCRIBE ITSELF (#2227). This used to return a bare `None`, which
    discarded the one thing that separates the two causes of a failed read: a LATE answer (the box
    serialises `gh`, measured 63.0 s at 13 lanes -- #2005) and an ABSENT one (a refusal) demand
    opposite responses, and the beat printed `merged_24h=?` for both. So the duration, the cause and
    the AGE of the last good cached value are recorded in `LAST_RATE_READ` on every path.

    ⛔ AND THE CACHE'S AGE IS NOT THE CACHE'S VALUE (#1869). `LAST_RATE_READ["cache"]` carries the
    last good rate ONLY so `main()` can print it as `last_good_rate=` WITH its age -- it is never
    returned as the answer and never reaches `drain_days` or the verdict. A stale number standing
    where an unread one belongs is the exact fail-open #1869 closed, and this function must not
    reopen it.
    """
    LAST_RATE_READ.clear()
    try:
        with open(CACHE) as fh:
            c = json.load(fh)
        LAST_RATE_READ["cache"] = c.get("merged_24h")
        LAST_RATE_READ["cache_age"] = int(max(0, time.time() - float(c.get("ts") or 0)))
        if time.time() - c.get("ts", 0) < TTL:
            return c.get("merged_24h")
    except Exception:
        pass
    _t0 = time.monotonic()
    rows = gh("pr", "list", "--repo", REPO, "--state", "merged", "--limit", "200",
              "--json", "mergedAt")
    LAST_RATE_READ["waited_s"] = round(time.monotonic() - _t0, 1)
    if rows is None:
        return None
    cutoff = time.time() - 86400
    def epoch(s):
        try:
            return time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
        except Exception:
            return 0
    n = sum(1 for r in rows if epoch(r.get("mergedAt") or "") > cutoff)
    try:
        with open(CACHE, "w") as fh:
            json.dump({"ts": int(time.time()), "merged_24h": n}, fh)
    except Exception:
        pass
    return n


def main():
    try:
        with open(PROGRESS) as fh:
            prog = json.load(fh)
        open_prs = int(prog.get("open_prs") or 0)
    except Exception:
        print("QUEUE: unavailable (no beta-progress.json)")
        return 0

    rate = merged_24h()
    have, present = count_merge_lanes()

    if rate is None:
        # Unknown rate must NOT be read as zero, and must not be read as a refusal either.
        # ⛔ SAY WHAT WAS TRIED, HOW LONG IT WAITED, AND HOW OLD THE LAST GOOD SAMPLE IS (#2227).
        # `merged_24h=?` + "(merge-rate read failed)" is the same sentence for a 100 s serialisation
        # delay and for an instant 403 -- and the fleet's response should be opposite ones. The wait
        # is the discriminator, so it is printed, and `last_good_rate=` gives the reader the last
        # known rate WITH ITS AGE. It is deliberately a SEPARATE token from `merged_24h=`, and the
        # verdict below is still UNKNOWN: a stale rate may be shown, never adopted (#1869).
        _w = LAST_RATE_READ.get("waited_s")
        _wait = f"waited={_w:.1f}s" if isinstance(_w, (int, float)) else "waited=?"
        _cause = str(LAST_RATE_READ.get("cause") or "no cause recorded")[:110]
        _age = LAST_RATE_READ.get("cache_age")
        _stale = "last_good=none"
        if _age is not None:
            _cached = LAST_RATE_READ.get("cache")
            # ⛔ THE TOKEN MUST NOT CONTAIN `merged_24h=`, AND THAT IS NOT COSMETIC (#2227).
            # Every consumer of this line parses `merged_24h=(\d+)`, and a substring match does not
            # care about the prefix -- a token spelled `stale_merged_24h=23` IS a match for that
            # pattern, so a six-hour-old rate would be read back as the CURRENT one by the very
            # readers this label exists to protect. Name it `last_good_rate=` instead.
            _stale = (f"last_good={_age}s last_good_rate={_cached}(aged {_age}s, NOT current)"
                      if _cached is not None else f"last_good={_age}s")
        print("QUEUE: open=%d merged_24h=? have=%d need=? VERDICT=UNKNOWN "
              "(merge-rate read failed: %s, %s, tried gh pr list --state merged; %s)"
              % (open_prs, have, _wait, _stale, _cause))
        return 0

    # ⛔ A READ THAT ANSWERED LATE IS REPORTED AS DATA, WITH ITS LATENCY (#2227). The rate is real
    # -- it is the ANSWER -- and calling it a failure because it took 40 s would be the same
    # false-absence this file just stopped printing, one step further along.
    _w = LAST_RATE_READ.get("waited_s")
    _slow = (" read=SLOW(waited=%.1fs) -- the merge rate is DATA, read late" % _w
             if isinstance(_w, (int, float)) and _w >= SLOW_READ_S else "")

    per_lane = PER_LANE_DAY          # fixed assumption — NOT rate/have (see note above)
    need = max(1, int(math.ceil(open_prs / (per_lane * TARGET_DAYS))))
    drain_days = (open_prs / rate) if rate > 0 else float("inf")

    if rate == 0:
        verdict = "STALLED"          # nothing is draining at all
    elif open_prs < MIN_QUEUE:
        verdict = "OK"
    elif have < need:
        verdict = "BOTTLENECK"       # the queue is the constraint: add lanes
    else:
        verdict = "OK"

    print("QUEUE: open=%d merged_24h=%d drain_days=%s have=%d need=%d "
          "VERDICT=%s lanes=[%s]%s"
          % (open_prs, rate,
             ("%.1f" % drain_days) if drain_days != float("inf") else "inf",
             have, need, verdict, ",".join(present) or "NONE", _slow))
    return 0

if __name__ == "__main__":
    sys.exit(main())
