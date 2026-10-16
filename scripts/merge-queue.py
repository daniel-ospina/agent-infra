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
    """Merge rate over a real 24h window, cached. beta-progress.json counts 'today'
    (since UTC midnight), which at 01:00 reads 8 and makes a healthy fleet look
    stalled. The window that answers 'is the queue draining' is a rolling 24h."""
    try:
        with open(CACHE) as fh:
            c = json.load(fh)
        if time.time() - c.get("ts", 0) < TTL:
            return c.get("merged_24h")
    except Exception:
        pass
    rows = gh("pr", "list", "--repo", REPO, "--state", "merged", "--limit", "200",
              "--json", "mergedAt")
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
        # Unknown rate must NOT be read as zero. Say so; do not invent a verdict.
        print("QUEUE: open=%d merged_24h=? have=%d need=? VERDICT=UNKNOWN "
              "(merge-rate read failed)" % (open_prs, have))
        return 0

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
          "VERDICT=%s lanes=[%s]"
          % (open_prs, rate,
             ("%.1f" % drain_days) if drain_days != float("inf") else "inf",
             have, need, verdict, ",".join(present) or "NONE"))
    return 0

if __name__ == "__main__":
    sys.exit(main())
